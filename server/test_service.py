import base64
import os
import sqlite3
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

import service


def pub(key):
    return base64.b64encode(key.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()


def sample_bundle(identity=None):
    identity = identity or os.urandom(33)
    encode = lambda data: base64.b64encode(data).decode()
    return {"registration_id": 17, "device_number": 1,
            "identity_key": encode(identity), "signed_prekey_id": 10,
            "signed_prekey": encode(os.urandom(33)),
            "signed_prekey_signature": encode(os.urandom(64)),
            "one_time_prekey_id": 11, "one_time_prekey": encode(os.urandom(33)),
            "kyber_prekey_id": 12, "kyber_prekey": encode(os.urandom(1568)),
            "kyber_prekey_signature": encode(os.urandom(64))}


class RelayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        os.environ["FL_METADATA_KEY"] = base64.b64encode(os.urandom(32)).decode()
        self.db = service.connect(os.path.join(self.temp.name, "db.sqlite"))
        service.init_challenges(self.db)
        self.owner_key = Ed25519PrivateKey.generate()
        self.owner = service.bootstrap(self.db, "Owner", "owner", pub(self.owner_key))
        self.owner_session = service.issue_session(self.db, self.owner["device_id"])
        self.db.commit()
        self.actor = service.active_session(self.db, self.owner_session)

    def tearDown(self):
        self.db.close()
        self.temp.cleanup()

    def test_invitation_single_use_expiry_and_approval(self):
        code = service.create_invitation(self.db, self.actor["device_id"])
        friend_key = Ed25519PrivateKey.generate()
        admission = service.redeem_invitation(self.db, code, "Friend", "friend", pub(friend_key))
        with self.assertRaises(service.Error):
            service.redeem_invitation(self.db, code, "Other", "other", pub(friend_key))
        service.approve_admission(self.db, self.actor, admission["admission_id"])
        self.assertEqual(self.db.execute("SELECT state FROM devices WHERE id=?", (admission["device_id"],)).fetchone()[0], "active")
        expired = service.create_invitation(self.db, self.actor["device_id"])
        self.db.execute("UPDATE invitations SET expires_at=? WHERE code_hash=?", (int(time.time()) - 1, service.digest(expired)))
        self.db.commit()
        with self.assertRaises(service.Error):
            service.redeem_invitation(self.db, expired, "Late", "late", pub(friend_key))

    def test_invitation_and_approval_are_single_winner_under_concurrency(self):
        path = os.path.join(self.temp.name, "db.sqlite")
        code = service.create_invitation(self.db, self.actor["device_id"])
        key = pub(Ed25519PrivateKey.generate())

        def redeem(username):
            connection = service.connect(path)
            try:
                return service.redeem_invitation(connection, code, username, username, key)
            except service.Error:
                return None
            finally:
                connection.close()

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(redeem, ["friendone", "friendtwo"]))
        admitted = [result for result in results if result is not None]
        self.assertEqual(len(admitted), 1)

        def approve(_):
            connection = service.connect(path)
            try:
                service.approve_admission(connection, self.actor, admitted[0]["admission_id"])
                return True
            except service.Error:
                return False
            finally:
                connection.close()

        with ThreadPoolExecutor(max_workers=2) as pool:
            approved = list(pool.map(approve, [1, 2]))
        self.assertEqual(approved.count(True), 1)

    def test_challenge_signature_one_time(self):
        challenge = "test-challenge"
        self.db.execute("INSERT INTO challenges VALUES(?,?,?)", (service.digest(challenge), self.owner["device_id"], int(time.time()) + 120))
        self.db.commit()
        message = ("fuckin-locked-login-v1:" + self.owner["device_id"] + ":" + challenge).encode()
        signature = base64.b64encode(self.owner_key.sign(message)).decode()
        token = service.verify_login(self.db, self.owner["device_id"], challenge, signature)
        self.assertEqual(service.active_session(self.db, token)["device_id"], self.owner["device_id"])
        with self.assertRaises(service.Error):
            service.verify_login(self.db, self.owner["device_id"], challenge, signature)

    def test_pending_device_cannot_authenticate(self):
        code = service.create_invitation(self.db, self.actor["device_id"])
        friend = service.redeem_invitation(self.db, code, "Friend", "friend", pub(Ed25519PrivateKey.generate()))
        with self.assertRaises(service.Error):
            service.active_session(self.db, service.issue_session(self.db, friend["device_id"]))
        with self.assertRaises(service.Error):
            service.verify_login(self.db, friend["device_id"], "anything", "AA==")

    def test_bootstrap_cannot_repeat(self):
        with self.assertRaises(service.Error):
            service.bootstrap(self.db, "Other", "other", pub(Ed25519PrivateKey.generate()))

    def test_revoke_blocks_sessions_new_envelopes_and_clears_pending(self):
        code = service.create_invitation(self.db, self.actor["device_id"])
        friend = service.redeem_invitation(self.db, code, "Friend", "friend", pub(Ed25519PrivateKey.generate()))
        service.approve_admission(self.db, self.actor, friend["admission_id"])
        room = service.create_room(self.db, self.actor, [friend["user_id"]])
        payload = base64.b64encode(os.urandom(64)).decode()
        service.send_envelope(self.db, self.actor, room, friend["device_id"], "message", payload)
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM envelopes").fetchone()[0], 1)
        service.revoke_device(self.db, self.db.execute("SELECT id device_id,user_id FROM devices WHERE id=?", (friend["device_id"],)).fetchone(), friend["device_id"])
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM envelopes").fetchone()[0], 0)
        with self.assertRaises(service.Error):
            service.send_envelope(self.db, self.actor, room, friend["device_id"], "message", payload)
        self.assertEqual(service.pending_envelopes(self.db, {"device_id": friend["device_id"]}), [])

    def test_relay_only_stores_opaque_ciphertext(self):
        code = service.create_invitation(self.db, self.actor["device_id"])
        friend = service.redeem_invitation(self.db, code, "Friend", "friend", pub(Ed25519PrivateKey.generate()))
        service.approve_admission(self.db, self.actor, friend["admission_id"])
        room = service.create_room(self.db, self.actor, [friend["user_id"]])
        ciphertext = os.urandom(96)
        service.send_envelope(self.db, self.actor, room, friend["device_id"], "attachment", base64.b64encode(ciphertext).decode())
        self.assertEqual(self.db.execute("SELECT ciphertext FROM envelopes").fetchone()[0], ciphertext)
        columns = [row[1] for row in self.db.execute("PRAGMA table_info(envelopes)")]
        self.assertNotIn("plaintext", columns)
        self.assertNotIn("decryption_key", columns)

    def test_prekey_bundle_is_single_use_and_identity_immutable(self):
        code = service.create_invitation(self.db, self.actor["device_id"])
        friend = service.redeem_invitation(self.db, code, "Friend", "friend", pub(Ed25519PrivateKey.generate()))
        service.approve_admission(self.db, self.actor, friend["admission_id"])
        room = service.create_room(self.db, self.actor, [friend["user_id"]])
        friend_actor = service.active_session(self.db, service.issue_session(self.db, friend["device_id"]))
        self.db.commit()
        bundle = sample_bundle()
        service.publish_prekeys(self.db, friend_actor, room, bundle)
        fetched = service.take_prekeys(self.db, self.actor, room, friend["device_id"])
        self.assertEqual(fetched["identity_key"], bundle["identity_key"])
        with self.assertRaises(service.Error):
            service.take_prekeys(self.db, self.actor, room, friend["device_id"])
        with self.assertRaises(service.Error):
            service.publish_prekeys(self.db, friend_actor, room, sample_bundle())
        service.publish_prekeys(self.db, friend_actor, room, sample_bundle(base64.b64decode(bundle["identity_key"])))
        service.revoke_device(self.db, friend_actor, friend["device_id"])
        with self.assertRaises(service.Error):
            service.take_prekeys(self.db, self.actor, room, friend["device_id"])

    def test_member_names_are_encrypted_at_rest(self):
        row = self.db.execute("SELECT name,username,username_hash FROM users WHERE id=?",
                              (self.owner["user_id"],)).fetchone()
        self.assertNotIn(b"Owner", row["name"])
        self.assertNotIn(b"owner", row["username"])
        self.assertEqual(service.reveal(row["name"], "name"), "Owner")
        self.assertEqual(service.reveal(row["username"], "username"), "owner")
        self.assertNotEqual(row["username_hash"], service.digest("owner"))

    def test_session_termination_on_revocation(self):
        outstanding = service.create_invitation(self.db, self.actor["device_id"])
        service.revoke_device(self.db, self.actor, self.owner["device_id"])
        with self.assertRaises(service.Error):
            service.active_session(self.db, self.owner_session)
        with self.assertRaises(service.Error):
            service.redeem_invitation(self.db, outstanding, "Late", "late", pub(Ed25519PrivateKey.generate()))

    def test_device_approval_is_single_winner_and_revoked_approver_cannot_act(self):
        path = os.path.join(self.temp.name, "db.sqlite")
        pending = service.request_device(self.db, self.actor, pub(Ed25519PrivateKey.generate()))

        def approve(_):
            connection = service.connect(path)
            try:
                service.approve_device(connection, self.actor, pending)
                return True
            except service.Error:
                return False
            finally:
                connection.close()

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(approve, (1, 2)))
        self.assertEqual(results.count(True), 1)
        service.revoke_device(self.db, self.actor, self.owner["device_id"])
        with self.assertRaises(service.Error):
            service.request_device(self.db, self.actor, pub(Ed25519PrivateKey.generate()))

    def test_delivery_ack_requires_active_recipient_and_is_single_use(self):
        code = service.create_invitation(self.db, self.actor["device_id"])
        friend = service.redeem_invitation(self.db, code, "Friend", "friend", pub(Ed25519PrivateKey.generate()))
        service.approve_admission(self.db, self.actor, friend["admission_id"])
        room = service.create_room(self.db, self.actor, [friend["user_id"]])
        friend_actor = service.active_session(self.db, service.issue_session(self.db, friend["device_id"]))
        self.db.commit()
        envelope = service.send_envelope(self.db, self.actor, room, friend["device_id"], "message",
                                         base64.b64encode(os.urandom(64)).decode())
        with self.assertRaises(service.Error):
            service.acknowledge_envelope(self.db, self.actor, envelope)
        service.acknowledge_envelope(self.db, friend_actor, envelope)
        with self.assertRaises(service.Error):
            service.acknowledge_envelope(self.db, friend_actor, envelope)
        service.revoke_device(self.db, friend_actor, friend["device_id"])
        with self.assertRaises(service.Error):
            service.acknowledge_envelope(self.db, friend_actor, envelope)

    def test_envelopes_are_recipient_scoped_and_room_authorized(self):
        admitted = []
        for username in ("friendone", "friendtwo"):
            code = service.create_invitation(self.db, self.actor["device_id"])
            friend = service.redeem_invitation(self.db, code, username, username,
                                                pub(Ed25519PrivateKey.generate()))
            service.approve_admission(self.db, self.actor, friend["admission_id"])
            admitted.append(friend)
        first, second = admitted
        room = service.create_room(self.db, self.actor, [first["user_id"]])
        ciphertext = os.urandom(72)
        envelope = service.send_envelope(self.db, self.actor, room, first["device_id"], "message",
                                         base64.b64encode(ciphertext).decode())
        first_actor = service.active_session(self.db, service.issue_session(self.db, first["device_id"]))
        second_actor = service.active_session(self.db, service.issue_session(self.db, second["device_id"]))
        self.db.commit()
        self.assertEqual([item["id"] for item in service.pending_envelopes(self.db, first_actor)], [envelope])
        self.assertEqual(service.pending_envelopes(self.db, second_actor), [])
        with self.assertRaises(service.Error):
            service.acknowledge_envelope(self.db, second_actor, envelope)
        with self.assertRaises(service.Error):
            service.send_envelope(self.db, second_actor, room, first["device_id"], "message",
                                  base64.b64encode(ciphertext).decode())
        with self.assertRaises(service.Error):
            service.take_prekeys(self.db, second_actor, room, first["device_id"])


if __name__ == "__main__":
    unittest.main()
