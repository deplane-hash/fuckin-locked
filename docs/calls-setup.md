# Voice call server setup

These are prepared deployment instructions; no live server was changed.

1. Install a maintained coturn release on the same server as `freedomhub.at`.
   Use `deploy/coturn.conf.example`, replacing the interface IP and certificate
   paths. Its TLS certificate must validate for `freedomhub.at`. If the host is
   behind NAT, configure coturn's external/public address mapping as documented
   by coturn. DNS must reach the TURN host directly; an HTTP reverse proxy does
   not carry TURN. Keep the existing HTTPS gateway on port 443.
2. Generate a random shared secret, for example `openssl rand -hex 32`. Put it
   in the service's protected environment as `FL_TURN_SHARED_SECRET` and in
   coturn's protected `static-auth-secret`. Do not put it in the iOS build,
   GitHub source, commands retained in shell history, or logs. Restrict both
   files to their service accounts. Do not reuse device or app passwords.
3. Set `FL_TURN_URL=turns:freedomhub.at:5349?transport=tcp`. Allow inbound
   TCP 5349 and coturn's UDP relay range 49160–49200. Only TLS client listeners
   are enabled. Review host firewall and coturn peer restrictions before use.
4. With an approved authenticated device, `/v1/calls/turn` should issue a fresh
   username and password. The username expires after five minutes; the relay
   implements coturn's documented REST HMAC credential format using Python's
   standard library. The shared secret is never returned or persisted in the
   message database. Revoked sessions cannot fetch new credentials. Credential
   expiry alone does not terminate existing TURN allocations: the official app
   stops calls on vault lock and on authenticated gateway polling failure.
5. Test two signed iPhones using verified, unlocked one-to-one conversations.
   Both must stay active in the chat. The receiver must tap Accept. An initial
   microphone permission prompt may make the app inactive and lock it; unlock
   and retry after granting permission. Check audio in both directions and
   confirm the selected ICE pair is relay/relay. Remove TURN reachability and
   confirm failure with no direct fallback. Test screenshot, recording,
   backgrounding, identity change, and device revocation during a call.

Renew the CA certificate before expiry and reload coturn using its supported
service procedure. Verify the new certificate hostname and chain on two real
devices. Rotate the shared secret in both services together during a maintenance
window and retest new calls; existing credentials can fail across rotation.
Clients have no certificate-validation bypass or direct fallback.

TURN sees client IPs, relay allocations, timing and bandwidth. It cannot decrypt
DTLS-SRTP media; call SDP/fingerprints travel through the existing libsignal
session. Service traffic and media go through this server. iOS/Apple system
connections such as APNs are outside the app's routing control.

Reference: [coturn TURN REST API and server configuration](https://github.com/coturn/coturn/blob/master/README.turnserver).
