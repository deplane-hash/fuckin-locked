"""Generic APNs notifications only. Never accepts a message/identity payload."""
from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import stat
import time

import httpx
import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec


PAYLOAD = b'{"aps":{"alert":"New message","sound":"default"}}'


@dataclass(frozen=True)
class Configuration:
    team: str
    key_id: str
    topic: str
    environment: str
    key: ec.EllipticCurvePrivateKey

    @classmethod
    def load(cls):
        try:
            team, kid, topic, environment, path = [os.environ.get(k, "") for k in (
                "FL_APNS_TEAM_ID", "FL_APNS_KEY_ID", "FL_APNS_TOPIC", "FL_APNS_ENVIRONMENT", "FL_APNS_KEY_PATH")]
            if not (re.fullmatch(r"[A-Z0-9]{10}", team) and re.fullmatch(r"[A-Z0-9]{10}", kid)
                    and re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", topic)
                    and len(topic) <= 255 and environment in ("production", "development")):
                return None
            file = Path(path)
            info = file.lstat()
            if not file.is_absolute() or not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_size > 16_384:
                return None
            key = serialization.load_pem_private_key(file.read_bytes(), password=None)
            if not isinstance(key, ec.EllipticCurvePrivateKey) or not isinstance(key.curve, ec.SECP256R1):
                return None
            return cls(team, kid, topic, environment, key)
        except (OSError, ValueError, TypeError):
            return None


class Sender:
    def __init__(self, config: Configuration, transport=None):
        self.config = config
        # No redirect, trust bypass, environment proxy, URL logging or fallback.
        self.client = httpx.Client(http2=True, follow_redirects=False, timeout=5,
                                   trust_env=False, transport=transport)
        self.authorization = ""
        self.issued = 0

    def close(self):
        self.client.close()

    def send(self, token: str) -> int:
        if not re.fullmatch(r"[0-9a-f]{64,200}", token):
            return 400
        now = int(time.time())
        if not self.authorization or now - self.issued >= 1200 or now < self.issued:
            self.authorization = jwt.encode({"iss": self.config.team, "iat": now}, self.config.key,
                                            algorithm="ES256", headers={"kid": self.config.key_id})
            self.issued = now
        host = "api.push.apple.com" if self.config.environment == "production" else "api.sandbox.push.apple.com"
        response = self.client.post("https://" + host + "/3/device/" + token, content=PAYLOAD, headers={
            "authorization": "bearer " + self.authorization,
            "apns-topic": self.config.topic, "apns-push-type": "alert", "apns-priority": "10",
            "apns-expiration": str(now + 300), "apns-collapse-id": "new-message",
            "content-type": "application/json",
        })
        # Never expose APNs response bodies, URLs, device tokens or JWTs in errors.
        return response.status_code


def deliver_batch(db, reveal, sender: Sender, now=None):
    now = int(time.time()) if now is None else now
    rows = db.execute("""SELECT q.*,t.token FROM push_queue q
        JOIN push_tokens t ON t.device_id=q.device_id JOIN devices d ON d.id=q.device_id
        WHERE d.state='active' AND q.next_attempt<=? LIMIT 20""", (now,)).fetchall()
    for row in rows:
        pending = db.execute("SELECT 1 FROM envelopes WHERE recipient_device=? AND delivered_at IS NULL LIMIT 1",
                             (row["device_id"],)).fetchone()
        if not pending or row["expires_at"] <= now:
            with db:
                db.execute("DELETE FROM push_queue WHERE device_id=? AND generation=?",
                           (row["device_id"], row["generation"]))
            continue
        try:
            result = sender.send(reveal(row["token"], "push-token:" + row["device_id"]))
        except Exception:
            result = 503  # No exception printing: httpx errors can contain tokens.
        with db:
            if result == 200:
                db.execute("DELETE FROM push_queue WHERE device_id=? AND generation=?",
                           (row["device_id"], row["generation"]))
            elif result in (400, 410):
                # Match the exact token; don't remove a concurrent replacement.
                db.execute("DELETE FROM push_tokens WHERE device_id=? AND token=?",
                           (row["device_id"], row["token"]))
                db.execute("DELETE FROM push_queue WHERE device_id=? AND generation=?",
                           (row["device_id"], row["generation"]))
            else:
                db.execute("UPDATE push_queue SET attempts=attempts+1,next_attempt=? WHERE device_id=? AND generation=?",
                           (now + min(300, 5 * 2 ** min(row["attempts"], 6)), row["device_id"], row["generation"]))


def run(connect, reveal):
    config = Configuration.load()
    if config is None:
        return
    sender = Sender(config)
    try:
        while True:
            db = None
            try:
                db = connect()
                deliver_batch(db, reveal, sender)
            except Exception:
                pass  # Never write payloads/credentials into process logs.
            finally:
                if db is not None:
                    db.close()
            time.sleep(2)
    finally:
        sender.close()
