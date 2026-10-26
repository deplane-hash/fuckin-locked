"""Ciphertext relay and invitation/device authority. No message decryption keys live here."""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import time
import threading
import re
import push
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

DB_PATH = os.environ.get("FL_DB", "./data/fuckin-locked.sqlite3")
MAX_BODY = 2_000_000


def digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def b64(data: str) -> bytes:
    return base64.b64decode(data, validate=True)


def metadata_key() -> bytes:
    encoded = os.environ.get("FL_METADATA_KEY", "")
    try:
        key = b64(encoded)
    except (ValueError, base64.binascii.Error):
        raise RuntimeError("FL_METADATA_KEY must be base64 of 32 random bytes") from None
    if len(key) != 32:
        raise RuntimeError("FL_METADATA_KEY must be base64 of 32 random bytes")
    return key


def turn_configuration() -> dict[str, str]:
    """Return a complete TURN-over-TLS config or fail closed.

    Uses coturn's documented TURN REST credentials. The shared secret remains
    server-side; each authenticated fetch gets a five-minute credential.
    """
    url = os.environ.get("FL_TURN_URL", "")
    shared = os.environ.get("FL_TURN_SHARED_SECRET", "")
    # TURN URIs use the `turns:host:port` form, which Python's URL parser
    # treats as an opaque path unless an authority prefix is supplied.
    try:
        parsed = urlparse("https://" + url[6:])
        valid = (url.lower().startswith("turns:") and parsed.hostname and
                 parsed.username is None and parsed.password is None and
                 not parsed.path and not parsed.fragment and parsed.query == "transport=tcp" and
                 (parsed.port is None or 0 < parsed.port <= 65535))
    except ValueError:
        valid = False
    require(valid and len(shared.encode()) >= 32 and not shared.startswith("REPLACE_"),
            503, "Calls unavailable")
    username = f"{int(time.time()) + 300}:{secrets.token_urlsafe(18)}"
    credential = base64.b64encode(hmac.new(shared.encode(), username.encode(), hashlib.sha1).digest()).decode()
    return {"url": url, "username": username, "credential": credential}


def protect(value: str, field: str) -> bytes:
    nonce = os.urandom(12)
    return nonce + AESGCM(metadata_key()).encrypt(nonce, value.encode(), field.encode())


def reveal(value: bytes, field: str) -> str:
    return AESGCM(metadata_key()).decrypt(value[:12], value[12:], field.encode()).decode()


def username_hash(username: str) -> str:
    return hmac.new(metadata_key(), username.lower().encode(), hashlib.sha256).hexdigest()


def connect(path: str = DB_PATH) -> sqlite3.Connection:
    metadata_key()  # No unencrypted metadata mode.
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path, timeout=10)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys=ON")
    db.executescript("""
    CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY, name BLOB NOT NULL,
      username BLOB NOT NULL, username_hash TEXT UNIQUE NOT NULL);
    CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id),
      public_key BLOB NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','active','revoked')),
      created_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS invitations(code_hash TEXT PRIMARY KEY, created_by TEXT NOT NULL,
      expires_at INTEGER NOT NULL, used_at INTEGER);
    CREATE TABLE IF NOT EXISTS admissions(id TEXT PRIMARY KEY, code_hash TEXT NOT NULL,
      user_id TEXT NOT NULL REFERENCES users(id), device_id TEXT NOT NULL REFERENCES devices(id),
      created_at INTEGER NOT NULL, decided_at INTEGER);
    CREATE TABLE IF NOT EXISTS sessions(token_hash TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES devices(id),
      expires_at INTEGER NOT NULL, revoked_at INTEGER);
    CREATE TABLE IF NOT EXISTS rooms(id TEXT PRIMARY KEY, created_by TEXT NOT NULL, created_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS members(room_id TEXT NOT NULL REFERENCES rooms(id), user_id TEXT NOT NULL REFERENCES users(id),
      PRIMARY KEY(room_id,user_id));
    CREATE TABLE IF NOT EXISTS envelopes(id TEXT PRIMARY KEY, room_id TEXT NOT NULL REFERENCES rooms(id),
      sender_device TEXT NOT NULL REFERENCES devices(id), recipient_device TEXT NOT NULL REFERENCES devices(id),
      kind TEXT NOT NULL CHECK(kind IN ('message','attachment','key_update')),
      ciphertext BLOB NOT NULL, created_at INTEGER NOT NULL, delivered_at INTEGER);
    CREATE TABLE IF NOT EXISTS prekey_bundles(
      room_id TEXT NOT NULL REFERENCES rooms(id), device_id TEXT NOT NULL REFERENCES devices(id),
      registration_id INTEGER NOT NULL, device_number INTEGER NOT NULL,
      identity_key BLOB NOT NULL, signed_prekey_id INTEGER NOT NULL,
      signed_prekey BLOB NOT NULL, signed_prekey_signature BLOB NOT NULL,
      one_time_prekey_id INTEGER NOT NULL, one_time_prekey BLOB NOT NULL,
      kyber_prekey_id INTEGER NOT NULL, kyber_prekey BLOB NOT NULL,
      kyber_prekey_signature BLOB NOT NULL, consumed_at INTEGER,
      PRIMARY KEY(room_id,device_id));
    CREATE TABLE IF NOT EXISTS prekey_claims(
      room_id TEXT NOT NULL, target_device TEXT NOT NULL, requester_device TEXT NOT NULL,
      request_id TEXT NOT NULL, bundle TEXT NOT NULL,
      PRIMARY KEY(room_id,target_device,requester_device,request_id));
    CREATE TABLE IF NOT EXISTS private_groups(
      room_id TEXT PRIMARY KEY REFERENCES rooms(id), owner_user_id TEXT NOT NULL,
      roster TEXT NOT NULL, blocked INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS group_links(
      room_id TEXT PRIMARY KEY REFERENCES rooms(id), group_id TEXT NOT NULL REFERENCES private_groups(room_id),
      left_device TEXT NOT NULL, right_device TEXT NOT NULL,
      UNIQUE(group_id,left_device,right_device));
    CREATE TABLE IF NOT EXISTS push_tokens(
      device_id TEXT PRIMARY KEY REFERENCES devices(id), token BLOB NOT NULL);
    CREATE TABLE IF NOT EXISTS push_queue(
      device_id TEXT PRIMARY KEY REFERENCES devices(id), generation INTEGER NOT NULL,
      next_attempt INTEGER NOT NULL, attempts INTEGER NOT NULL, expires_at INTEGER NOT NULL);
    """)
    db.commit()
    return db


class Error(Exception):
    def __init__(self, status: int, message: str):
        self.status, self.message = status, message


def require(condition: bool, status: int = 400, message: str = "Invalid request") -> None:
    if not condition:
        raise Error(status, message)


def active_session(db: sqlite3.Connection, token: str) -> sqlite3.Row:
    row = db.execute("""SELECT d.id device_id,d.user_id,d.public_key FROM sessions s
        JOIN devices d ON d.id=s.device_id WHERE s.token_hash=? AND s.expires_at>?
        AND s.revoked_at IS NULL AND d.state='active'""", (digest(token), int(time.time()))).fetchone()
    require(row is not None, 401, "Authentication required")
    return row


def register_push(db: sqlite3.Connection, actor: sqlite3.Row, token: str) -> dict:
    require(push.Configuration.load() is not None, 503, "Notifications unavailable")
    require(isinstance(token, str) and re.fullmatch(r"[0-9a-f]{64,200}", token) is not None)
    db.execute("BEGIN IMMEDIATE")
    try:
        require(db.execute("SELECT 1 FROM devices WHERE id=? AND state='active'",
                           (actor["device_id"],)).fetchone() is not None, 401, "Authentication required")
        db.execute("INSERT OR REPLACE INTO push_tokens VALUES(?,?)",
                   (actor["device_id"], protect(token, "push-token:" + actor["device_id"])))
        db.commit()
    except Exception:
        db.rollback()
        raise
    return {"state": "registered"}


def update_profile(db: sqlite3.Connection, actor: sqlite3.Row, name: str, username: str) -> dict:
    require(isinstance(name, str) and 1 <= len(name.strip()) <= 80 and all(ord(c) >= 32 for c in name))
    require(isinstance(username, str) and re.fullmatch(r"[A-Za-z0-9_]{3,32}", username) is not None)
    db.execute("BEGIN IMMEDIATE")
    try:
        require(db.execute("SELECT 1 FROM devices WHERE id=? AND state='active'",
                           (actor["device_id"],)).fetchone() is not None, 401, "Authentication required")
        db.execute("UPDATE users SET name=?,username=?,username_hash=? WHERE id=?",
                   (protect(name.strip(), "name"), protect(username, "username"), username_hash(username), actor["user_id"]))
        db.commit()
    except Exception:
        db.rollback(); raise
    return {"user_id": actor["user_id"], "device_id": actor["device_id"], "name": name.strip(), "username": username}


def issue_session(db: sqlite3.Connection, device_id: str) -> str:
    token = secrets.token_urlsafe(32)
    db.execute("INSERT INTO sessions VALUES(?,?,?,NULL)", (digest(token), device_id, int(time.time()) + 30 * 86400))
    return token


def create_invitation(db: sqlite3.Connection, creator: str, ttl: int = 86400) -> str:
    require(60 <= ttl <= 7 * 86400)
    code = secrets.token_urlsafe(24)
    db.execute("BEGIN IMMEDIATE")
    try:
        require(db.execute("SELECT 1 FROM devices WHERE id=? AND state='active'",
                           (creator,)).fetchone() is not None, 401, "Authentication required")
        db.execute("INSERT INTO invitations VALUES(?,?,?,NULL)", (digest(code), creator, int(time.time()) + ttl))
        db.commit()
    except Exception:
        db.rollback()
        raise
    return code


def redeem_invitation(db: sqlite3.Connection, code: str, name: str, username: str, public_key_b64: str) -> dict:
    now = int(time.time())
    require(1 <= len(name) <= 80 and 3 <= len(username) <= 32)
    require(username.isascii() and all(c.isalnum() or c == '_' for c in username))
    key = b64(public_key_b64)
    require(len(key) == 32, message="Invalid device key")
    user_id, device_id, admission_id = (secrets.token_urlsafe(16) for _ in range(3))
    with db:
        changed = db.execute("UPDATE invitations SET used_at=? WHERE code_hash=? AND used_at IS NULL AND expires_at>?",
                             (now, digest(code), now)).rowcount
        require(changed == 1, 403, "Invitation expired or already used")
        db.execute("INSERT INTO users VALUES(?,?,?,?)",
                   (user_id, protect(name, "name"), protect(username, "username"), username_hash(username)))
        db.execute("INSERT INTO devices VALUES(?,?,?,?,?)", (device_id, user_id, key, 'pending', now))
        db.execute("INSERT INTO admissions VALUES(?,?,?,?,?,NULL)", (admission_id, digest(code), user_id, device_id, now))
    return {"admission_id": admission_id, "user_id": user_id, "device_id": device_id, "state": "pending"}


def approve_admission(db: sqlite3.Connection, approver: sqlite3.Row, admission_id: str) -> None:
    db.execute("BEGIN IMMEDIATE")
    try:
        require(db.execute("SELECT 1 FROM devices WHERE id=? AND state='active'",
                           (approver["device_id"],)).fetchone() is not None, 401, "Authentication required")
        row = db.execute("SELECT device_id FROM admissions WHERE id=? AND decided_at IS NULL",
                         (admission_id,)).fetchone()
        require(row is not None, 404, "Pending request not found")
        changed = db.execute("UPDATE admissions SET decided_at=? WHERE id=? AND decided_at IS NULL",
                             (int(time.time()), admission_id)).rowcount
        require(changed == 1, 404, "Pending request not found")
        changed = db.execute("UPDATE devices SET state='active' WHERE id=? AND state='pending'",
                             (row["device_id"],)).rowcount
        require(changed == 1, 404, "Pending device not found")
        db.commit()
    except Exception:
        db.rollback()
        raise


def approve_device(db: sqlite3.Connection, approver: sqlite3.Row, device_id: str) -> None:
    db.execute("BEGIN IMMEDIATE")
    try:
        require(db.execute("SELECT 1 FROM devices WHERE id=? AND state='active'",
                           (approver["device_id"],)).fetchone() is not None, 401, "Authentication required")
        changed = db.execute("""UPDATE devices SET state='active' WHERE id=? AND user_id=?
            AND state='pending' AND created_at>=?""",
            (device_id, approver["user_id"], int(time.time()) - 600)).rowcount
        require(changed == 1, 404, "Pending device not found")
        db.commit()
    except Exception:
        db.rollback()
        raise


def request_device(db: sqlite3.Connection, actor: sqlite3.Row, public_key_b64: str) -> str:
    key = b64(public_key_b64)
    require(len(key) == 32, message="Invalid device key")
    device_id = secrets.token_urlsafe(16)
    db.execute("BEGIN IMMEDIATE")
    try:
        require(db.execute("SELECT 1 FROM devices WHERE id=? AND user_id=? AND state='active'",
                           (actor["device_id"], actor["user_id"])).fetchone() is not None,
                401, "Authentication required")
        db.execute("INSERT INTO devices VALUES(?,?,?,?,?)",
                   (device_id, actor["user_id"], key, "pending", int(time.time())))
        db.commit()
    except Exception:
        db.rollback()
        raise
    return device_id


def revoke_device(db: sqlite3.Connection, actor: sqlite3.Row, device_id: str) -> None:
    db.execute("BEGIN IMMEDIATE")
    try:
        require(db.execute("SELECT 1 FROM devices WHERE id=? AND state='active'",
                           (actor["device_id"],)).fetchone() is not None, 401, "Authentication required")
        row = db.execute("SELECT user_id,state FROM devices WHERE id=?", (device_id,)).fetchone()
        require(row is not None and row["user_id"] == actor["user_id"] and row["state"] == "active", 404,
                "Active device not found")
        db.execute("UPDATE devices SET state='revoked' WHERE id=?", (device_id,))
        db.execute("UPDATE sessions SET revoked_at=? WHERE device_id=? AND revoked_at IS NULL",
                   (int(time.time()), device_id))
        db.execute("UPDATE invitations SET used_at=? WHERE created_by=? AND used_at IS NULL",
                   (int(time.time()), device_id))
        db.execute("DELETE FROM envelopes WHERE recipient_device=? AND delivered_at IS NULL", (device_id,))
        db.execute("DELETE FROM push_tokens WHERE device_id=?", (device_id,))
        db.execute("DELETE FROM push_queue WHERE device_id=?", (device_id,))
        db.execute("DELETE FROM prekey_bundles WHERE device_id=?", (device_id,))
        db.execute("DELETE FROM prekey_claims WHERE target_device=? OR requester_device=?", (device_id, device_id))
        for group in db.execute("SELECT room_id,roster FROM private_groups").fetchall():
            if device_id in json.loads(group["roster"]):
                db.execute("UPDATE private_groups SET blocked=1 WHERE room_id=?", (group["room_id"],))
        db.commit()
    except Exception:
        db.rollback()
        raise


def create_room(db: sqlite3.Connection, actor: sqlite3.Row, user_ids: list[str]) -> str:
    members = set(user_ids) | {actor["user_id"]}
    require(2 <= len(members) <= 50)
    room_id = secrets.token_urlsafe(16)
    db.execute("BEGIN IMMEDIATE")
    try:
        require(db.execute("SELECT 1 FROM devices WHERE id=? AND state='active'",
                           (actor["device_id"],)).fetchone() is not None, 401, "Authentication required")
        require(all(db.execute("SELECT 1 FROM devices WHERE user_id=? AND state='active'", (uid,)).fetchone()
                    for uid in members), 403, "Member unavailable")
        db.execute("INSERT INTO rooms VALUES(?,?,?)", (room_id, actor["user_id"], int(time.time())))
        db.executemany("INSERT INTO members VALUES(?,?)", ((room_id, uid) for uid in members))
        db.commit()
    except Exception:
        db.rollback()
        raise
    return room_id


def list_rooms(db: sqlite3.Connection, actor: sqlite3.Row) -> list[dict]:
    """Return only rooms for the current active user, with active members."""
    require(db.execute("SELECT 1 FROM devices WHERE id=? AND user_id=? AND state='active'",
                       (actor["device_id"], actor["user_id"])).fetchone() is not None,
            401, "Authentication required")
    rows = db.execute("""SELECT r.id FROM rooms r JOIN members m ON m.room_id=r.id
        WHERE m.user_id=? AND NOT EXISTS(SELECT 1 FROM group_links l WHERE l.room_id=r.id)
        ORDER BY r.created_at,r.id""", (actor["user_id"],)).fetchall()
    rooms = []
    for room in rows:
        group = db.execute("SELECT roster FROM private_groups WHERE room_id=?", (room["id"],)).fetchone()
        if group and actor["device_id"] not in json.loads(group["roster"]):
            continue
        members = db.execute("""SELECT u.id,u.name,u.username FROM users u
            JOIN members m ON m.user_id=u.id
            WHERE m.room_id=? AND EXISTS (SELECT 1 FROM devices d
              WHERE d.user_id=u.id AND d.state='active') ORDER BY u.id""",
            (room["id"],)).fetchall()
        rooms.append({"id": room["id"], "is_group": group is not None, "members": [{
            "id": member["id"], "name": reveal(member["name"], "name"),
            "username": reveal(member["username"], "username")
        } for member in members]})
    return rooms


def create_group(db: sqlite3.Connection, actor: sqlite3.Row, peer_devices: list[str]) -> str:
    require(isinstance(peer_devices, list) and 2 <= len(peer_devices) <= 7)
    require(all(isinstance(value, str) for value in peer_devices))
    roster = sorted(set(peer_devices + [actor["device_id"]]))
    require(len(roster) == len(peer_devices) + 1, message="Select distinct devices")
    group_id = secrets.token_urlsafe(16)
    db.execute("BEGIN IMMEDIATE")
    try:
        users = []
        for device in roster:
            row = db.execute("SELECT user_id FROM devices WHERE id=? AND state='active'", (device,)).fetchone()
            require(row is not None, 403, "Device unavailable")
            users.append(row["user_id"])
        require(len(set(users)) == len(users), message="Select one device per member")
        require(actor["user_id"] in users, 403, "Not authorized")
        db.execute("INSERT INTO rooms VALUES(?,?,?)", (group_id, actor["device_id"], int(time.time())))
        db.executemany("INSERT INTO members VALUES(?,?)", ((group_id, uid) for uid in users))
        db.execute("INSERT INTO private_groups VALUES(?,?,?,0)",
                   (group_id, actor["user_id"], json.dumps(roster)))
        db.commit()
        return group_id
    except Exception:
        db.rollback()
        raise


def group_info(db: sqlite3.Connection, actor: sqlite3.Row, group_id: str) -> dict:
    group = db.execute("SELECT * FROM private_groups WHERE room_id=?", (group_id,)).fetchone()
    require(group is not None and actor["device_id"] in json.loads(group["roster"]), 403, "Not authorized")
    require(db.execute("SELECT 1 FROM devices WHERE id=? AND user_id=? AND state='active'",
                       (actor["device_id"], actor["user_id"])).fetchone(),
            401, "Authentication required")
    peers = []
    for device in json.loads(group["roster"]):
        row = db.execute("""SELECT d.user_id,d.state,u.name FROM devices d JOIN users u ON u.id=d.user_id
            WHERE d.id=?""", (device,)).fetchone()
        peers.append({"device_id": device, "user_id": row["user_id"], "state": row["state"],
                      "name": reveal(row["name"], "name")})
    return {"room_id": group_id, "owner_user_id": group["owner_user_id"],
            "blocked": bool(group["blocked"]), "devices": peers}


def group_link(db: sqlite3.Connection, actor: sqlite3.Row, group_id: str, peer: str) -> dict:
    db.execute("BEGIN IMMEDIATE")
    try:
        require(db.execute("SELECT 1 FROM private_groups WHERE room_id=?", (group_id,)).fetchone() is not None,
                404, "Group not found")
        require(_room_device_authorized(db, group_id, actor["device_id"]) and
                _room_device_authorized(db, group_id, peer), 403, "Group unavailable")
        require(actor["device_id"] != peer)
        left, right = sorted([actor["device_id"], peer])
        row = db.execute("SELECT room_id FROM group_links WHERE group_id=? AND left_device=? AND right_device=?",
                         (group_id, left, right)).fetchone()
        if row is None:
            room = secrets.token_urlsafe(16)
            db.execute("INSERT INTO rooms VALUES(?,?,?)", (room, actor["device_id"], int(time.time())))
            users = [db.execute("SELECT user_id FROM devices WHERE id=?", (device,)).fetchone()[0]
                     for device in (left, right)]
            db.executemany("INSERT INTO members VALUES(?,?)", ((room, user) for user in users))
            db.execute("INSERT INTO group_links VALUES(?,?,?,?)", (room, group_id, left, right))
        else:
            room = row["room_id"]
        db.commit()
        return {"room_id": room}
    except Exception:
        db.rollback()
        raise


def remove_group_member(db: sqlite3.Connection, actor: sqlite3.Row, group_id: str, user_id: str) -> None:
    db.execute("BEGIN IMMEDIATE")
    try:
        group = db.execute("SELECT owner_user_id FROM private_groups WHERE room_id=?", (group_id,)).fetchone()
        require(group is not None and group["owner_user_id"] == actor["user_id"] and
                _room_device_authorized(db, group_id, actor["device_id"]), 403, "Not authorized")
        changed = db.execute("DELETE FROM members WHERE room_id=? AND user_id=?", (group_id, user_id)).rowcount
        require(changed == 1, 404, "Member not found")
        # Fixed-roster groups close on change. No old sender state is reused to
        # distribute keys to a replacement member or device. Create a new group.
        db.execute("UPDATE private_groups SET blocked=1 WHERE room_id=?", (group_id,))
        db.commit()
    except Exception:
        db.rollback()
        raise


def send_envelope(db: sqlite3.Connection, actor: sqlite3.Row, room_id: str, recipient: str,
                  kind: str, ciphertext_b64: str, message_id: str | None = None) -> str:
    require(kind in ("message", "attachment", "key_update"))
    ciphertext = b64(ciphertext_b64)
    require(16 <= len(ciphertext) <= MAX_BODY, message="Invalid ciphertext")
    if message_id is not None:
        require(isinstance(message_id, str) and 1 <= len(message_id) <= 128 and
                all(c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for c in message_id))
    # A device-scoped stable ID lets a sender safely repeat an upload after a
    # lost response, without encrypting again or creating duplicate deliveries.
    envelope_id = digest(":".join((actor["device_id"], room_id, recipient, message_id))) if message_id else secrets.token_urlsafe(16)
    db.execute("BEGIN IMMEDIATE")
    try:
        sender = db.execute("SELECT 1 FROM devices WHERE id=? AND user_id=? AND state='active'",
                            (actor["device_id"], actor["user_id"])).fetchone()
        member = db.execute("SELECT 1 FROM members WHERE room_id=? AND user_id=?",
                            (room_id, actor["user_id"])).fetchone()
        target = db.execute("""SELECT d.id FROM devices d JOIN members m ON m.user_id=d.user_id
            WHERE m.room_id=? AND d.id=? AND d.state='active'""", (room_id, recipient)).fetchone()
        require(sender is not None and member is not None and target is not None, 403, "Not authorized")
        require(db.execute("SELECT 1 FROM private_groups WHERE room_id=?", (room_id,)).fetchone() is None,
                403, "Approved transport required")
        require(_room_device_authorized(db, room_id, actor["device_id"]) and
                _room_device_authorized(db, room_id, recipient), 403, "Not authorized")
        existing = db.execute("SELECT * FROM envelopes WHERE id=?", (envelope_id,)).fetchone()
        if existing is not None:
            require(existing["sender_device"] == actor["device_id"] and
                    existing["room_id"] == room_id and existing["recipient_device"] == recipient and
                    existing["kind"] == kind and existing["ciphertext"] == ciphertext,
                    409, "Message identifier conflict")
            db.commit()
            return envelope_id
        db.execute("INSERT INTO envelopes VALUES(?,?,?,?,?,?,?,NULL)",
                   (envelope_id, room_id, actor["device_id"], recipient, kind, ciphertext, int(time.time())))
        db.execute("""INSERT INTO push_queue VALUES(?,1,0,0,?) ON CONFLICT(device_id)
            DO UPDATE SET generation=generation+1,next_attempt=0,attempts=0,expires_at=excluded.expires_at""",
            (recipient, int(time.time()) + 300))
        db.commit()
    except Exception:
        db.rollback()
        raise
    return envelope_id


def inbox_activity(db: sqlite3.Connection, actor: sqlite3.Row) -> dict:
    require(db.execute("SELECT 1 FROM devices WHERE id=? AND state='active'",
                       (actor["device_id"],)).fetchone() is not None, 401, "Authentication required")
    rows = db.execute("""SELECT DISTINCT e.room_id,COALESCE(l.group_id,e.room_id) display_room
        FROM envelopes e LEFT JOIN group_links l ON l.room_id=e.room_id
        WHERE e.recipient_device=? AND e.delivered_at IS NULL""", (actor["device_id"],)).fetchall()
    return {"rooms": sorted({row["display_room"] for row in rows
                            if _room_device_authorized(db, row["room_id"], actor["device_id"])})}


def envelope_status(db: sqlite3.Connection, actor: sqlite3.Row, envelope_id: str) -> dict:
    row = db.execute("""SELECT e.delivered_at FROM envelopes e
        JOIN devices d ON d.id=e.sender_device JOIN members m ON m.room_id=e.room_id AND m.user_id=d.user_id
        WHERE e.id=? AND e.sender_device=? AND d.state='active'""",
        (envelope_id, actor["device_id"])).fetchone()
    require(row is not None, 404, "Envelope not found")
    return {"state": "delivered" if row["delivered_at"] is not None else "accepted"}


def pending_envelopes(db: sqlite3.Connection, actor: sqlite3.Row, room_id: str | None = None) -> list[dict]:
    rows = db.execute("""SELECT e.id,e.room_id,e.sender_device,sd.user_id sender_user_id,
        e.kind,e.ciphertext,e.created_at
        FROM envelopes e JOIN devices d ON d.id=e.recipient_device
        JOIN devices sd ON sd.id=e.sender_device
        JOIN members m ON m.room_id=e.room_id AND m.user_id=d.user_id
        WHERE e.recipient_device=? AND d.state='active' AND e.delivered_at IS NULL
        AND (? IS NULL OR e.room_id=?)
        AND NOT EXISTS(SELECT 1 FROM group_links l JOIN private_groups g ON g.room_id=l.group_id
          WHERE l.room_id=e.room_id AND g.blocked=1)
        ORDER BY e.created_at,e.id LIMIT 100""", (actor["device_id"], room_id, room_id)).fetchall()
    return [{**{key: row[key] for key in ("id", "room_id", "sender_device", "sender_user_id", "kind", "created_at")},
             "ciphertext": base64.b64encode(row["ciphertext"]).decode()} for row in rows]


def acknowledge_envelope(db: sqlite3.Connection, actor: sqlite3.Row, envelope_id: str) -> None:
    db.execute("BEGIN IMMEDIATE")
    try:
        require(db.execute("SELECT 1 FROM devices WHERE id=? AND state='active'",
                           (actor["device_id"],)).fetchone() is not None, 401, "Authentication required")
        changed = db.execute("""UPDATE envelopes SET delivered_at=? WHERE id=? AND recipient_device=?
            AND delivered_at IS NULL AND EXISTS (SELECT 1 FROM devices d JOIN members m ON m.user_id=d.user_id
              WHERE d.id=envelopes.recipient_device AND d.state='active' AND m.room_id=envelopes.room_id)""",
            (int(time.time()), envelope_id, actor["device_id"])).rowcount
        require(changed == 1, 404, "Envelope not found")
        db.commit()
    except Exception:
        db.rollback()
        raise


PREKEY_FIELDS = (
    "identity_key", "signed_prekey", "signed_prekey_signature", "one_time_prekey",
    "kyber_prekey", "kyber_prekey_signature",
)


def _room_device_authorized(db: sqlite3.Connection, room_id: str, device_id: str) -> bool:
    group = db.execute("SELECT roster,blocked FROM private_groups WHERE room_id=?", (room_id,)).fetchone()
    if group is not None and (group["blocked"] or device_id not in json.loads(group["roster"])):
        return False
    link = db.execute("SELECT * FROM group_links WHERE room_id=?", (room_id,)).fetchone()
    if link is not None:
        if device_id not in (link["left_device"], link["right_device"]):
            return False
        return _room_device_authorized(db, link["group_id"], device_id)
    return db.execute("""SELECT 1 FROM devices d JOIN members m ON m.user_id=d.user_id
        WHERE d.id=? AND d.state='active' AND m.room_id=?""", (device_id, room_id)).fetchone() is not None


def publish_prekeys(db: sqlite3.Connection, actor: sqlite3.Row, room_id: str, payload: dict) -> None:
    # Public protocol keys and signatures only. The relay never accepts private keys.
    registration_id = int(payload["registration_id"])
    device_number = int(payload["device_number"])
    ids = tuple(int(payload[name]) for name in ("signed_prekey_id", "one_time_prekey_id", "kyber_prekey_id"))
    require(1 <= registration_id <= 16380 and 1 <= device_number <= 127)
    require(all(1 <= value <= 2**31 - 1 for value in ids))
    fields = tuple(b64(payload[name]) for name in PREKEY_FIELDS)
    require(32 <= len(fields[0]) <= 128 and 32 <= len(fields[1]) <= 128 and
            32 <= len(fields[3]) <= 128 and 1000 <= len(fields[4]) <= 4096 and
            len(fields[2]) == 64 and len(fields[5]) == 64, message="Invalid prekey bundle")
    db.execute("BEGIN IMMEDIATE")
    try:
        require(_room_device_authorized(db, room_id, actor["device_id"]), 403, "Not authorized")
        require(db.execute("SELECT 1 FROM private_groups WHERE room_id=?", (room_id,)).fetchone() is None,
                403, "Approved transport required")
        count = db.execute("SELECT COUNT(*) FROM members WHERE room_id=?", (room_id,)).fetchone()[0]
        require(count == 2, 403, "One-to-one room required")
        old = db.execute("""SELECT identity_key,registration_id,device_number,
            one_time_prekey_id,one_time_prekey FROM prekey_bundles
            WHERE room_id=? AND device_id=?""",
                         (room_id, actor["device_id"])).fetchone()
        if old is not None:
            require(old["identity_key"] == fields[0] and old["registration_id"] == registration_id and
                    old["device_number"] == device_number, 409, "Identity changed")
            if old["one_time_prekey_id"] == ids[1]:
                require(old["one_time_prekey"] == fields[3], 409, "One-time prekey changed")
        db.execute("""INSERT INTO prekey_bundles VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)
            ON CONFLICT(room_id,device_id) DO UPDATE SET
            signed_prekey_id=excluded.signed_prekey_id, signed_prekey=excluded.signed_prekey,
            signed_prekey_signature=excluded.signed_prekey_signature,
            one_time_prekey_id=excluded.one_time_prekey_id, one_time_prekey=excluded.one_time_prekey,
            kyber_prekey_id=excluded.kyber_prekey_id, kyber_prekey=excluded.kyber_prekey,
            kyber_prekey_signature=excluded.kyber_prekey_signature,
            consumed_at=CASE WHEN prekey_bundles.one_time_prekey_id=excluded.one_time_prekey_id
                THEN prekey_bundles.consumed_at ELSE NULL END""",
            (room_id, actor["device_id"], registration_id, device_number, fields[0], ids[0], fields[1],
             fields[2], ids[1], fields[3], ids[2], fields[4], fields[5]))
        db.commit()
    except Exception:
        db.rollback()
        raise


def take_prekeys(db: sqlite3.Connection, actor: sqlite3.Row, room_id: str, target_device: str,
                 request_id: str | None = None) -> dict:
    if request_id is not None:
        require(isinstance(request_id, str) and 1 <= len(request_id) <= 128 and
                all(c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for c in request_id))
    db.execute("BEGIN IMMEDIATE")
    try:
        require(_room_device_authorized(db, room_id, actor["device_id"]) and
                _room_device_authorized(db, room_id, target_device), 403, "Not authorized")
        require(actor["device_id"] != target_device, 403, "Not authorized")
        if request_id is not None:
            claim = db.execute("""SELECT bundle FROM prekey_claims WHERE room_id=? AND target_device=?
                AND requester_device=? AND request_id=?""",
                (room_id, target_device, actor["device_id"], request_id)).fetchone()
            if claim is not None:
                db.commit()
                return json.loads(claim["bundle"])
        row = db.execute("SELECT * FROM prekey_bundles WHERE room_id=? AND device_id=? AND consumed_at IS NULL",
                         (room_id, target_device)).fetchone()
        require(row is not None, 404, "Prekey bundle unavailable")
        changed = db.execute("UPDATE prekey_bundles SET consumed_at=? WHERE room_id=? AND device_id=? AND consumed_at IS NULL",
                             (int(time.time()), room_id, target_device)).rowcount
        require(changed == 1, 404, "Prekey bundle unavailable")
        result = {name: row[name] for name in ("registration_id", "device_number", "signed_prekey_id",
                                                "one_time_prekey_id", "kyber_prekey_id")}
        result.update({name: base64.b64encode(row[name]).decode() for name in PREKEY_FIELDS})
        result["device_id"] = target_device
        if request_id is not None:
            db.execute("INSERT INTO prekey_claims VALUES(?,?,?,?,?)",
                (room_id, target_device, actor["device_id"], request_id, json.dumps(result)))
        db.commit()
        return result
    except Exception:
        db.rollback()
        raise


def verify_login(db: sqlite3.Connection, device_id: str, challenge: str, signature_b64: str) -> str:
    row = db.execute("SELECT public_key,state FROM devices WHERE id=?", (device_id,)).fetchone()
    require(row is not None and row["state"] == "active", 401, "Device unavailable")
    record = db.execute("SELECT expires_at FROM challenges WHERE value_hash=? AND device_id=?",
                        (digest(challenge), device_id)).fetchone()
    require(record is not None and record["expires_at"] > int(time.time()), 401, "Challenge expired")
    try:
        Ed25519PublicKey.from_public_bytes(row["public_key"]).verify(b64(signature_b64),
            ("fuckin-locked-login-v1:" + device_id + ":" + challenge).encode())
    except (InvalidSignature, ValueError):
        raise Error(401, "Invalid signature") from None
    with db:
        consumed = db.execute("DELETE FROM challenges WHERE value_hash=? AND device_id=? AND expires_at>?",
                              (digest(challenge), device_id, int(time.time()))).rowcount
        require(consumed == 1, 401, "Challenge expired")
        return issue_session(db, device_id)


def init_challenges(db: sqlite3.Connection) -> None:
    db.execute("CREATE TABLE IF NOT EXISTS challenges(value_hash TEXT PRIMARY KEY,device_id TEXT NOT NULL,expires_at INTEGER NOT NULL)")
    db.commit()


def bootstrap(db: sqlite3.Connection, name: str, username: str, public_key_b64: str) -> dict:
    require(1 <= len(name) <= 80 and 3 <= len(username) <= 32)
    require(username.isascii() and all(c.isalnum() or c == '_' for c in username))
    key = b64(public_key_b64)
    require(len(key) == 32)
    uid, did = secrets.token_urlsafe(16), secrets.token_urlsafe(16)
    db.execute("BEGIN IMMEDIATE")
    try:
        require(db.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0, 403, "Bootstrap already complete")
        db.execute("INSERT INTO users VALUES(?,?,?,?)",
                   (uid, protect(name, "name"), protect(username, "username"), username_hash(username)))
        db.execute("INSERT INTO devices VALUES(?,?,?,?,?)", (did, uid, key, "active", int(time.time())))
        db.commit()
    except Exception:
        db.rollback()
        raise
    return {"user_id": uid, "device_id": did}


class Handler(BaseHTTPRequestHandler):
    db_path = DB_PATH

    def log_message(self, format, *args):
        # Deliberately no URLs, bodies, authorization headers, or client-supplied text.
        pass

    def respond(self, status: int, payload: dict | list):
        data = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def dispatch(self):
        path = urlparse(self.path).path
        parts = path.strip("/").split("/")
        length = int(self.headers.get("Content-Length", "0"))
        require(0 <= length <= MAX_BODY * 2, 413, "Request too large")
        data = json.loads(self.rfile.read(length)) if length else {}
        require(isinstance(data, dict))
        db = connect(self.db_path)
        init_challenges(db)
        try:
            if self.command == "GET" and path == "/health":
                return {"status": "ok"}
            if self.command == "POST" and path == "/v1/bootstrap":
                expected = os.environ.get("FL_BOOTSTRAP_TOKEN", "")
                require(expected and hmac.compare_digest(self.headers.get("X-Bootstrap-Token", ""), expected),
                        403, "Bootstrap unavailable")
                return bootstrap(db, data["name"], data["username"], data["public_key"])
            if self.command == "POST" and path == "/v1/admissions":
                return redeem_invitation(db, data["code"], data["name"], data["username"], data["public_key"])
            if self.command == "POST" and path == "/v1/devices/pending":
                # Existing account authentication is required via an active session.
                actor = active_session(db, self.headers.get("Authorization", "").removeprefix("Bearer "))
                return {"device_id": request_device(db, actor, data["public_key"]), "state": "pending"}
            if self.command == "POST" and path == "/v1/auth/challenge":
                did = data["device_id"]
                row = db.execute("SELECT 1 FROM devices WHERE id=? AND state='active'", (did,)).fetchone()
                require(row is not None, 401, "Device unavailable")
                challenge = secrets.token_urlsafe(32)
                with db:
                    db.execute("INSERT INTO challenges VALUES(?,?,?)", (digest(challenge), did, int(time.time()) + 120))
                return {"challenge": challenge}
            if self.command == "POST" and path == "/v1/auth/session":
                return {"token": verify_login(db, data["device_id"], data["challenge"], data["signature"])}
            actor = active_session(db, self.headers.get("Authorization", "").removeprefix("Bearer "))
            if self.command == "GET" and path == "/v1/capabilities":
                capabilities = ["idempotent_envelopes_v1", "delivery_status_v1", "room_inbox_v1", "idempotent_prekeys_v1", "fixed_groups_v1"]
                try:
                    turn_configuration()
                except Error:
                    pass
                else:
                    capabilities.append("encrypted_calls_v1")
                if push.Configuration.load() is not None:
                    capabilities.append("generic_push_v1")
                return {"capabilities": capabilities}
            if self.command == "POST" and path == "/v1/notifications/register":
                return register_push(db, actor, data["token"])
            if self.command == "GET" and path == "/v1/inbox/activity":
                return inbox_activity(db, actor)
            if self.command == "GET" and path == "/v1/calls/turn":
                return turn_configuration()
            if self.command == "POST" and path == "/v1/groups":
                return {"room_id": create_group(db, actor, data["peer_devices"])}
            if self.command == "GET" and len(parts) == 3 and parts[:2] == ["v1", "groups"]:
                return group_info(db, actor, parts[2])
            if self.command == "POST" and len(parts) == 5 and parts[:2] == ["v1", "groups"] and parts[3] == "links":
                return group_link(db, actor, parts[2], parts[4])
            if self.command == "POST" and len(parts) == 6 and parts[:2] == ["v1", "groups"] and parts[3] == "members" and parts[5] == "remove":
                remove_group_member(db, actor, parts[2], parts[4])
                return {"state": "closed"}
            if self.command == "GET" and path == "/v1/me":
                row = db.execute("SELECT name,username FROM users WHERE id=?", (actor["user_id"],)).fetchone()
                return {"user_id": actor["user_id"], "device_id": actor["device_id"],
                        "name": reveal(row["name"], "name"), "username": reveal(row["username"], "username")}
            if self.command == "POST" and path == "/v1/me":
                return update_profile(db, actor, data["name"], data["username"])
            if self.command == "POST" and path == "/v1/invitations":
                return {"code": create_invitation(db, actor["device_id"], int(data.get("ttl", 86400)))}
            if self.command == "GET" and path == "/v1/admissions":
                rows = db.execute("""SELECT a.id,u.name,u.username,a.created_at FROM admissions a
                    JOIN users u ON u.id=a.user_id WHERE a.decided_at IS NULL""").fetchall()
                return {"pending": [{"id": row["id"], "name": reveal(row["name"], "name"),
                    "username": reveal(row["username"], "username"), "created_at": row["created_at"]}
                    for row in rows]}
            if self.command == "POST" and path.startswith("/v1/admissions/") and path.endswith("/approve"):
                approve_admission(db, actor, path.split("/")[3]); return {"state": "active"}
            if self.command == "POST" and path.startswith("/v1/devices/") and path.endswith("/approve"):
                approve_device(db, actor, path.split("/")[3]); return {"state": "active"}
            if self.command == "POST" and path.startswith("/v1/devices/") and path.endswith("/revoke"):
                revoke_device(db, actor, path.split("/")[3]); return {"state": "revoked"}
            if self.command == "GET" and path == "/v1/devices":
                rows = db.execute("SELECT id,state,created_at FROM devices WHERE user_id=?", (actor["user_id"],)).fetchall()
                return {"devices": [dict(row) for row in rows]}
            if self.command == "GET" and path == "/v1/people":
                rows = db.execute("""SELECT DISTINCT u.id,u.name,u.username FROM users u
                    JOIN devices d ON d.user_id=u.id WHERE d.state='active'""").fetchall()
                return {"people": [{"id": row["id"], "name": reveal(row["name"], "name"),
                    "username": reveal(row["username"], "username")} for row in rows]}
            if self.command == "GET" and len(parts) == 4 and parts[:2] == ["v1", "people"] and parts[3] == "devices":
                rows = db.execute("SELECT id,user_id FROM devices WHERE user_id=? AND state='active' ORDER BY created_at,id",
                                  (parts[2],)).fetchall()
                return {"devices": [dict(row) for row in rows]}
            if self.command == "POST" and path == "/v1/rooms":
                return {"room_id": create_room(db, actor, data["user_ids"])}
            if self.command == "GET" and path == "/v1/rooms":
                return {"rooms": list_rooms(db, actor)}
            if len(parts) == 4 and parts[:2] == ["v1", "rooms"] and parts[3] == "devices" and self.command == "GET":
                room_id = parts[2]
                require(_room_device_authorized(db, room_id, actor["device_id"]), 403, "Not authorized")
                rows = db.execute("""SELECT d.id,d.user_id FROM devices d JOIN members m ON m.user_id=d.user_id
                    WHERE m.room_id=? AND d.state='active' ORDER BY d.user_id,d.id""", (room_id,)).fetchall()
                return {"devices": [dict(row) for row in rows]}
            if len(parts) == 4 and parts[:2] == ["v1", "rooms"] and parts[3] == "prekeys" and self.command == "POST":
                publish_prekeys(db, actor, parts[2], data)
                return {"state": "published"}
            if len(parts) == 5 and parts[:2] == ["v1", "rooms"] and parts[3] == "prekeys" and self.command == "GET":
                return take_prekeys(db, actor, parts[2], parts[4])
            if len(parts) == 6 and parts[:2] == ["v1", "rooms"] and parts[3] == "prekeys" and self.command == "GET":
                return take_prekeys(db, actor, parts[2], parts[4], parts[5])
            if self.command == "POST" and path == "/v1/envelopes":
                return {"id": send_envelope(db, actor, data["room_id"], data["recipient_device"],
                                            data["kind"], data["ciphertext"], data.get("message_id"))}
            if self.command == "GET" and path == "/v1/envelopes":
                return {"envelopes": pending_envelopes(db, actor)}
            if self.command == "GET" and len(parts) == 5 and parts[:2] == ["v1", "rooms"] and parts[3:] == ["envelopes", "pending"]:
                return {"envelopes": pending_envelopes(db, actor, parts[2])}
            if self.command == "GET" and len(parts) == 4 and parts[:2] == ["v1", "envelopes"] and parts[3] == "status":
                return envelope_status(db, actor, parts[2])
            if self.command == "POST" and path.startswith("/v1/envelopes/") and path.endswith("/ack"):
                acknowledge_envelope(db, actor, path.split("/")[3])
                return {"state": "delivered"}
            raise Error(404, "Not found")
        finally:
            db.close()

    def do_GET(self): self.handle_request()
    def do_POST(self): self.handle_request()

    def handle_request(self):
        try:
            self.respond(200, self.dispatch())
        except Error as exc:
            self.respond(exc.status, {"error": exc.message})
        except (KeyError, TypeError, ValueError, sqlite3.IntegrityError, json.JSONDecodeError):
            self.respond(400, {"error": "Invalid request"})
        except Exception:
            # Never send a traceback, database detail, or request data back to a
            # client. The process manager can restart the service after logging
            # is configured out of band; this handler intentionally stays quiet.
            self.respond(500, {"error": "Service unavailable"})


if __name__ == "__main__":
    connect().close()
    threading.Thread(target=push.run, args=(connect, reveal), daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", int(os.environ.get("FL_PORT", "8787"))), Handler).serve_forever()
