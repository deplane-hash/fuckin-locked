import base64
import os
import sqlite3
import tempfile
import time
import unittest
import json
import http.client
import threading
from unittest.mock import patch
from http.server import ThreadingHTTPServer
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
    def group_fixture(self):
        friends = []
        for username in ("groupbob", "groupcharlie"):
            invitation = service.create_invitation(self.db, self.actor["device_id"])
            member = service.redeem_invitation(self.db, invitation, username, username, pub(Ed25519PrivateKey.generate()))
            service.approve_admission(self.db, self.actor, member["admission_id"])
            actor = service.active_session(self.db, service.issue_session(self.db, member["device_id"]))
            self.db.commit()
            friends.append((member, actor))
        group = service.create_group(self.db, self.actor, [friend[0]["device_id"] for friend in friends])
        return group, friends

    def test_group_transports_are_private_selected_device_scoped_and_idempotent(self):
        group, ((bob, bob_actor), (charlie, charlie_actor)) = self.group_fixture()
        link = service.group_link(self.db, self.actor, group, bob["device_id"])["room_id"]
        self.assertEqual(service.group_link(self.db, bob_actor, group, self.actor["device_id"])["room_id"], link)
        self.assertNotIn(link, [room["id"] for room in service.list_rooms(self.db, self.actor)])
        self.assertTrue(next(room for room in service.list_rooms(self.db, self.actor) if room["id"] == group)["is_group"])
        service.publish_prekeys(self.db, bob_actor, link, sample_bundle())
        with self.assertRaises(service.Error):
            service.take_prekeys(self.db, charlie_actor, link, bob["device_id"], "forbidden")
        with self.assertRaises(service.Error):
            service.send_envelope(self.db, self.actor, group, bob["device_id"], "message", base64.b64encode(os.urandom(96)).decode())
        extra = service.request_device(self.db, bob_actor, pub(Ed25519PrivateKey.generate()))
        service.approve_device(self.db, bob_actor, extra)
        extra_actor = service.active_session(self.db, service.issue_session(self.db, extra))
        self.db.commit()
        with self.assertRaises(service.Error):
            service.group_info(self.db, extra_actor, group)
        self.assertNotIn(group, [room["id"] for room in service.list_rooms(self.db, extra_actor)])

    def test_group_revocation_stops_all_old_group_links_and_prekey_claims(self):
        group, ((bob, bob_actor), (charlie, charlie_actor)) = self.group_fixture()
        ab = service.group_link(self.db, self.actor, group, bob["device_id"])["room_id"]
        ac = service.group_link(self.db, self.actor, group, charlie["device_id"])["room_id"]
        service.publish_prekeys(self.db, bob_actor, ab, sample_bundle())
        service.take_prekeys(self.db, self.actor, ab, bob["device_id"], "original-claim")
        service.revoke_device(self.db, bob_actor, bob["device_id"])
        self.assertTrue(service.group_info(self.db, self.actor, group)["blocked"])
        for room, target in ((ab, bob["device_id"]), (ac, charlie["device_id"])):
            with self.assertRaises(service.Error):
                service.send_envelope(self.db, self.actor, room, target, "message", base64.b64encode(os.urandom(96)).decode())
        with self.assertRaises(service.Error):
            service.take_prekeys(self.db, self.actor, ab, bob["device_id"], "original-claim")

    def test_only_owner_can_remove_member_and_old_keys_are_not_reused(self):
        group, ((bob, bob_actor), (charlie, charlie_actor)) = self.group_fixture()
        with self.assertRaises(service.Error):
            service.remove_group_member(self.db, bob_actor, group, charlie["user_id"])
        service.remove_group_member(self.db, self.actor, group, charlie["user_id"])
        self.assertTrue(service.group_info(self.db, self.actor, group)["blocked"])
        with self.assertRaises(service.Error):
            service.group_link(self.db, self.actor, group, bob["device_id"])

    def test_http_routes_enforce_auth_and_reach_messaging_handlers(self):
        code = service.create_invitation(self.db, self.actor["device_id"])
        friend = service.redeem_invitation(self.db, code, "Friend", "friend", pub(Ed25519PrivateKey.generate()))
        service.approve_admission(self.db, self.actor, friend["admission_id"])
        room = service.create_room(self.db, self.actor, [friend["user_id"]])
        recipient = service.active_session(self.db, service.issue_session(self.db, friend["device_id"]))
        self.db.commit()
        service.publish_prekeys(self.db, recipient, room, sample_bundle())
        handler = type("FixtureHandler", (service.Handler,), {"db_path": os.path.join(self.temp.name, "db.sqlite")})
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()

        def request(path, method="GET", body=None, authenticated=True):
            connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
            headers = {"Content-Type": "application/json"}
            if authenticated:
                headers["Authorization"] = "Bearer " + self.owner_session
            try:
                connection.request(method, path, json.dumps(body) if body is not None else None, headers)
                response = connection.getresponse()
                return response.status, json.loads(response.read())
            finally:
                connection.close()

        try:
            for path in ["/v1/capabilities", "/v1/me", "/v1/rooms",
                         f"/v1/people/{friend['user_id']}/devices", f"/v1/rooms/{room}/devices",
                         f"/v1/rooms/{room}/envelopes/pending"]:
                self.assertEqual(request(path)[0], 200, path)
                self.assertEqual(request(path, authenticated=False)[0], 401, path)
            with patch.dict(os.environ, {"FL_TURN_URL": "", "FL_TURN_USERNAME": "", "FL_TURN_CREDENTIAL": ""}):
                self.assertNotIn("encrypted_calls_v1", request("/v1/capabilities")[1]["capabilities"])
                self.assertEqual(request("/v1/calls/turn")[0], 503)
                self.assertEqual(request("/v1/calls/turn", authenticated=False)[0], 401)
            self.assertEqual(request(f"/v1/rooms/{room}/prekeys/{friend['device_id']}/request-one")[0], 200)
            status, result = request("/v1/envelopes", "POST", {
                "room_id": room, "recipient_device": friend["device_id"], "kind": "message",
                "ciphertext": base64.b64encode(os.urandom(96)).decode(), "message_id": "http-one"})
            self.assertEqual(status, 200)
            self.assertEqual(request(f"/v1/envelopes/{result['id']}/status"), (200, {"state": "accepted"}))
        finally:
            server.shutdown()
            server.server_close()
            worker.join()

    def test_retry_is_idempotent_and_delivery_status_is_sender_only(self):
        code = service.create_invitation(self.db, self.actor["device_id"])
        friend = service.redeem_invitation(self.db, code, "Friend", "friend", pub(Ed25519PrivateKey.generate()))
        service.approve_admission(self.db, self.actor, friend["admission_id"])
        room = service.create_room(self.db, self.actor, [friend["user_id"]])
        recipient = service.active_session(self.db, service.issue_session(self.db, friend["device_id"]))
        self.db.commit()
        ciphertext = base64.b64encode(os.urandom(96)).decode()
        envelope = service.send_envelope(self.db, self.actor, room, friend["device_id"], "message", ciphertext, "stable-id")
        self.assertEqual(service.send_envelope(self.db, self.actor, room, friend["device_id"], "message", ciphertext, "stable-id"), envelope)
        self.assertEqual(len(service.pending_envelopes(self.db, recipient, room)), 1)
        self.assertEqual(service.pending_envelopes(self.db, recipient, "another-room"), [])
        self.assertEqual(service.envelope_status(self.db, self.actor, envelope), {"state": "accepted"})
        with self.assertRaises(service.Error):
            service.envelope_status(self.db, recipient, envelope)
        with self.assertRaises(service.Error):
            service.send_envelope(self.db, self.actor, room, friend["device_id"], "message",
                                  base64.b64encode(os.urandom(96)).decode(), "stable-id")
        service.acknowledge_envelope(self.db, recipient, envelope)
        self.assertEqual(service.envelope_status(self.db, self.actor, envelope), {"state": "delivered"})
        self.assertEqual(service.send_envelope(self.db, self.actor, room, friend["device_id"], "message", ciphertext, "stable-id"), envelope)
        self.assertEqual(service.pending_envelopes(self.db, recipient, room), [])
        service.revoke_device(self.db, recipient, friend["device_id"])
        with self.assertRaises(service.Error):
            service.send_envelope(self.db, self.actor, room, friend["device_id"], "message", ciphertext, "stable-id")

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
        service.publish_prekeys(self.db, friend_actor, room, bundle)
        with self.assertRaises(service.Error):
            service.take_prekeys(self.db, self.actor, room, friend["device_id"])
        changed_same_id = dict(bundle)
        changed_same_id["one_time_prekey"] = base64.b64encode(os.urandom(33)).decode()
        with self.assertRaises(service.Error):
            service.publish_prekeys(self.db, friend_actor, room, changed_same_id)
        with self.assertRaises(service.Error):
            service.publish_prekeys(self.db, friend_actor, room, sample_bundle())
        replacement = sample_bundle(base64.b64decode(bundle["identity_key"]))
        replacement.update({"signed_prekey_id": 13, "one_time_prekey_id": 14, "kyber_prekey_id": 15})
        service.publish_prekeys(self.db, friend_actor, room, replacement)
        service.revoke_device(self.db, friend_actor, friend["device_id"])
        with self.assertRaises(service.Error):
            service.take_prekeys(self.db, self.actor, room, friend["device_id"])

    def test_prekey_claim_retries_return_only_the_original_requesters_bundle(self):
        code = service.create_invitation(self.db, self.actor["device_id"])
        friend = service.redeem_invitation(self.db, code, "Friend", "friend", pub(Ed25519PrivateKey.generate()))
        service.approve_admission(self.db, self.actor, friend["admission_id"])
        room = service.create_room(self.db, self.actor, [friend["user_id"]])
        recipient = service.active_session(self.db, service.issue_session(self.db, friend["device_id"]))
        self.db.commit()
        service.publish_prekeys(self.db, recipient, room, sample_bundle())
        first = service.take_prekeys(self.db, self.actor, room, friend["device_id"], "request-one")
        self.assertEqual(service.take_prekeys(self.db, self.actor, room, friend["device_id"], "request-one"), first)
        with self.assertRaises(service.Error):
            service.take_prekeys(self.db, self.actor, room, friend["device_id"], "request-two")
        second_device = service.request_device(self.db, self.actor, pub(Ed25519PrivateKey.generate()))
        service.approve_device(self.db, self.actor, second_device)
        second_actor = service.active_session(self.db, service.issue_session(self.db, second_device))
        self.db.commit()
        with self.assertRaises(service.Error):
            service.take_prekeys(self.db, second_actor, room, friend["device_id"], "request-one")
        service.revoke_device(self.db, recipient, friend["device_id"])
        with self.assertRaises(service.Error):
            service.take_prekeys(self.db, self.actor, room, friend["device_id"], "request-one")

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

    def test_device_approval_expires_and_pending_device_cannot_authenticate(self):
        pending = service.request_device(self.db, self.actor, pub(Ed25519PrivateKey.generate()))
        with self.assertRaises(service.Error):
            service.active_session(self.db, service.issue_session(self.db, pending))
        self.db.execute("UPDATE devices SET created_at=? WHERE id=?", (int(time.time()) - 601, pending))
        self.db.commit()
        with self.assertRaises(service.Error):
            service.approve_device(self.db, self.actor, pending)

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

    def test_room_listing_includes_only_rooms_for_authenticated_member(self):
        code = service.create_invitation(self.db, self.actor["device_id"])
        friend = service.redeem_invitation(self.db, code, "Friend", "friend", pub(Ed25519PrivateKey.generate()))
        service.approve_admission(self.db, self.actor, friend["admission_id"])
        room = service.create_room(self.db, self.actor, [friend["user_id"]])
        listed = service.list_rooms(self.db, self.actor)
        self.assertEqual([item["id"] for item in listed], [room])
        self.assertEqual({member["username"] for member in listed[0]["members"]}, {"owner", "friend"})
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM members WHERE room_id=?", (room,)).fetchone()[0], 2)

        outsider_code = service.create_invitation(self.db, self.actor["device_id"])
        outsider = service.redeem_invitation(self.db, outsider_code, "Outsider", "outsider",
                                             pub(Ed25519PrivateKey.generate()))
        service.approve_admission(self.db, self.actor, outsider["admission_id"])
        outsider_actor = service.active_session(self.db, service.issue_session(self.db, outsider["device_id"]))
        self.assertEqual(service.list_rooms(self.db, outsider_actor), [])


if __name__ == "__main__":
    unittest.main()
