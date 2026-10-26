import base64
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

import httpx
import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519
import push
import service


class PushTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {"FL_METADATA_KEY": base64.b64encode(os.urandom(32)).decode()})
        self.env.start()
        self.db = service.connect(self.temp.name + "/db.sqlite3")
        def public():
            return base64.b64encode(ed25519.Ed25519PrivateKey.generate().public_key().public_bytes(
                serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()
        owner = service.bootstrap(self.db, "Owner", "owner", public())
        session = service.issue_session(self.db, owner["device_id"]); self.db.commit()
        self.actor = service.active_session(self.db, session)
        invitation = service.create_invitation(self.db, self.actor["device_id"])
        self.friend = service.redeem_invitation(self.db, invitation, "Friend", "friend", public())
        service.approve_admission(self.db, self.actor, self.friend["admission_id"])
        friend_session = service.issue_session(self.db, self.friend["device_id"]); self.db.commit()
        self.peer = service.active_session(self.db, friend_session)
        self.room = service.create_room(self.db, self.actor, [self.friend["user_id"]])
        self.config = push.Configuration("ABCDEFGHIJ", "0123456789", "org.example.fuckinlocked", "production",
                                         ec.generate_private_key(ec.SECP256R1()))
        self.token = "ab" * 32

    def tearDown(self):
        self.db.close(); self.env.stop(); self.temp.cleanup()

    def enqueue(self):
        return service.send_envelope(self.db, self.actor, self.room, self.peer["device_id"],
                                     "message", base64.b64encode(os.urandom(64)).decode())

    def register(self):
        with patch.object(push.Configuration, "load", return_value=self.config):
            service.register_push(self.db, self.peer, self.token)

    def test_payload_is_fixed_generic_and_jwt_uses_es256(self):
        requests = []
        def transport(request):
            requests.append(request)
            return httpx.Response(200)
        sender = push.Sender(self.config, httpx.MockTransport(transport))
        try:
            self.assertEqual(sender.send(self.token), 200)
            request = requests[0]
            self.assertEqual(request.content, push.PAYLOAD)
            self.assertEqual(request.content, b'{"aps":{"alert":"New message","sound":"default"}}')
            self.assertEqual(request.headers["apns-push-type"], "alert")
            encoded = request.headers["authorization"].removeprefix("bearer ")
            claims = jwt.decode(encoded, self.config.key.public_key(), algorithms=["ES256"],
                                options={"verify_aud": False})
            self.assertEqual(claims["iss"], self.config.team)
            self.assertNotIn("token", claims)
        finally: sender.close()

    def test_token_is_encrypted_and_registration_requires_active_device(self):
        self.register()
        raw = self.db.execute("SELECT token FROM push_tokens").fetchone()[0]
        self.assertNotIn(self.token.encode(), raw)
        self.assertEqual(service.reveal(raw, "push-token:" + self.peer["device_id"]), self.token)
        service.revoke_device(self.db, self.peer, self.peer["device_id"])
        with patch.object(push.Configuration, "load", return_value=self.config):
            with self.assertRaises(service.Error): service.register_push(self.db, self.peer, self.token)
        self.assertEqual(self.db.execute("SELECT count(*) FROM push_tokens").fetchone()[0], 0)

    def test_missing_configuration_and_bad_tokens_fail_closed(self):
        with patch.object(push.Configuration, "load", return_value=None):
            with self.assertRaises(service.Error): service.register_push(self.db, self.peer, self.token)
        with patch.object(push.Configuration, "load", return_value=self.config):
            for bad in ["secret message", "aa/../../", "", self.token.upper()]:
                with self.assertRaises(service.Error): service.register_push(self.db, self.peer, bad)

    def test_queue_survives_restart_coalesces_and_revocation_removes_it(self):
        self.register(); self.enqueue(); self.enqueue()
        self.assertEqual(self.db.execute("SELECT generation FROM push_queue").fetchone()[0], 2)
        replacement = service.connect(self.temp.name + "/db.sqlite3")
        try: self.assertEqual(replacement.execute("SELECT count(*) FROM push_queue").fetchone()[0], 1)
        finally: replacement.close()
        service.revoke_device(self.db, self.peer, self.peer["device_id"])
        called = []
        sender = type("Sender", (), {"send": lambda _, token: called.append(token) or 200})()
        push.deliver_batch(self.db, service.reveal, sender)
        self.assertEqual(called, [])
        self.assertEqual(self.db.execute("SELECT count(*) FROM push_queue").fetchone()[0], 0)

    def test_delivery_ack_suppresses_notice_and_transient_failure_retries(self):
        self.register(); envelope = self.enqueue()
        called = []
        sender = type("Sender", (), {"send": lambda _, token: called.append(token) or 503})()
        push.deliver_batch(self.db, service.reveal, sender)
        self.assertEqual(called, [self.token])
        self.assertEqual(self.db.execute("SELECT attempts FROM push_queue").fetchone()[0], 1)
        service.acknowledge_envelope(self.db, self.peer, envelope)
        push.deliver_batch(self.db, service.reveal, sender, now=int(time.time()) + 10)
        self.assertEqual(len(called), 1)
        self.assertEqual(self.db.execute("SELECT count(*) FROM push_queue").fetchone()[0], 0)

    def test_configuration_requires_protected_p256_key(self):
        key = Path(self.temp.name) / "auth.p8"
        key.write_bytes(self.config.key.private_bytes(serialization.Encoding.PEM,
                        serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        with patch.dict(os.environ, {"FL_APNS_TEAM_ID": self.config.team, "FL_APNS_KEY_ID": self.config.key_id,
            "FL_APNS_TOPIC": self.config.topic, "FL_APNS_ENVIRONMENT": "production", "FL_APNS_KEY_PATH": str(key)}):
            key.chmod(0o644); self.assertIsNone(push.Configuration.load())
            key.chmod(0o600); self.assertIsNotNone(push.Configuration.load())
            key.write_bytes(b"not an APNs private key"); self.assertIsNone(push.Configuration.load())

    def test_profile_updates_are_encrypted_unique_and_revocation_checked(self):
        result = service.update_profile(self.db, self.actor, "Changed name", "changed_name")
        self.assertEqual(result["name"], "Changed name")
        stored = self.db.execute("SELECT name,username FROM users WHERE id=?", (self.actor["user_id"],)).fetchone()
        self.assertNotIn(b"Changed name", stored["name"])
        with self.assertRaises(Exception): service.update_profile(self.db, self.peer, "Duplicate", "changed_name")
        service.revoke_device(self.db, self.peer, self.peer["device_id"])
        with self.assertRaises(service.Error): service.update_profile(self.db, self.peer, "Revoked", "revoked_name")

    def test_new_message_during_push_is_not_lost_by_old_queue_deletion(self):
        self.register(); self.enqueue()
        calls = []
        def send(token):
            calls.append(token); self.enqueue(); return 200
        sender = type("Sender", (), {"send": lambda _, token: send(token)})()
        push.deliver_batch(self.db, service.reveal, sender)
        self.assertEqual(self.db.execute("SELECT generation FROM push_queue").fetchone()[0], 2)

    def test_activity_metadata_is_recipient_scoped_without_content_or_read_receipts(self):
        envelope = self.enqueue()
        self.assertEqual(service.inbox_activity(self.db, self.actor), {"rooms": []})
        self.assertEqual(service.inbox_activity(self.db, self.peer), {"rooms": [self.room]})
        service.acknowledge_envelope(self.db, self.peer, envelope)
        self.assertEqual(service.inbox_activity(self.db, self.peer), {"rooms": []})
        service.revoke_device(self.db, self.peer, self.peer["device_id"])
        with self.assertRaises(service.Error): service.inbox_activity(self.db, self.peer)
