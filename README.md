# fuckin locked — private beta in development

Native SwiftUI iPhone messenger and an opaque-ciphertext Python relay. This is an implementation under test, not a production-ready or independently reviewed messenger. Read [the verification report](docs/verification.md) before relying on a feature.

See [Foreground beta 0.3.0](docs/foreground-beta.md) for installation, private
first-device setup, Appetize downloads and the two-phone foreground test.

The current one-to-one path implements libsignal text, reactions, bounded still-image messages, original starter stickers, and an encrypted audio-call path. App and chat passwords protect the underlying local keys. Local draft chats are explicitly labeled and never presented as delivered conversations. Calls use WebRTC DTLS-SRTP with relay-only TURN-over-TLS media; offer/answer/ICE signaling remains inside the existing libsignal message channel. Calls are intentionally not exposed as a navigation destination until two-device media verification is complete.

## Project layout

- `ios/`: XcodeGen project, SwiftUI app, password vault, libsignal stores, networking, unit/integration/UI tests.
- `server/`: Python relay, membership authority, device authentication, public prekeys and recipient-scoped opaque envelopes.
- `deploy/`: HTTPS gateway, systemd, and deployment examples.
- `docs/`: threat model, protocol/licensing notes, verification, sticker format, and device checks.

## iOS setup

Use macOS with Xcode 26+, XcodeGen, and CocoaPods:

```sh
cd ios
xcodegen generate
pod install
open FuckinLocked.xcworkspace
```

The app requires iOS 18+. `Config.xcconfig` targets `https://freedomhub.at/fuckin-locked/`. Set your signing team and a bundle identifier matching your provisioning profile. Push builds produce an unsigned IPA after tests; manually dispatch with `sign_ipa` enabled to use protected repository secrets for Ad Hoc signing. An unsigned IPA needs valid signing before installation. Simulator tests use ad-hoc simulator signing and a simulator-only entitlement file to exercise the real Keychain without Apple signing credentials.

All application service requests use the configured HTTPS gateway, with normal certificate validation and redirects refused. There is no direct fallback. Rotate TLS certificates by installing a CA-valid certificate for the same hostname, reloading the gateway, and verifying a signed-device connection. New hostnames/paths require an app configuration update. Never embed a server TLS private key in the app.

This revision requires its matching relay capabilities. An old relay fails closed. A successful source push or CI build does not deploy a relay or install an app.

## Development relay

```sh
cd server
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
export FL_DB="$PWD/data/relay.sqlite3"
export FL_BOOTSTRAP_TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
export FL_METADATA_KEY="$(python3 -c 'import os,base64; print(base64.b64encode(os.urandom(32)).decode())')"
python3 service.py
```

The listener binds to `127.0.0.1:8787`. Use `deploy/freedomhub-path.nginx.example` or `deploy/nginx.conf.example` to expose it through your HTTPS gateway. Keep the database on an encrypted volume, restrict service credentials, and encrypt any server backups. The metadata key stays outside the database; losing it loses the encrypted member names. Do not replace production credentials with the CI fixture values.

The deployed service and the local working source are separate. Apply service updates only after validation and an encrypted/restricted backup. Preserve the metadata key and existing database; do not reinitialize an existing account database.

## Two iPhones

1. Set separate app passwords. On the first iPhone use **You → First device setup**, entering the deployment's one-time setup secret. Bootstrap succeeds only while no user exists. Remove the bootstrap secret from the service environment after first setup.
2. Create an invitation under **People**. Your friend uses **You → Use invitation**, then an existing active member explicitly approves the admission under **People**. Invitations expire and have a single atomic redemption.
3. One phone composes a **New** one-to-one conversation. The other selects **Continue** for the same room. Select the intended remote device when there is more than one. Set different local chat passwords on each phone.
4. Open each chat. Compare **Your fingerprint** on one phone against the peer fingerprint on the other phone in both directions through a trusted channel. Explicitly approve the match. The server's first key assertion alone is not identity verification.
5. Text, image, reaction and sticker content use libsignal ciphertext. Incoming messages poll only while the chat is unlocked. This discloses connection timing; there are no presence/typing indicators.
6. **Sent** means relay acceptance. **Delivered** means the recipient durably stored and acknowledged the message, not that someone read it. A persisted outbox retries the same ciphertext and stable message ID, including after reopening. Prekey claims also have persisted request IDs so a lost response does not strand setup.

For an additional phone on an existing account, open **Link to my existing account** on the new phone and **Authorized devices → Add device** on the existing phone. Transfer and compare the whole public pairing key over a trusted channel. Create and explicitly approve the request, then enter its device ID on the new phone. Approval expires after ten minutes. The new phone proves private-key possession during login and gets its profile from the authenticated service. No message history or chat decryption keys transfer. Each conversation remains bound to one explicitly verified remote device; automatic fan-out/history restoration is not implemented.

Revocation terminates that device's authenticated sessions and prevents new authorized deliveries/prekey retrieval, including retries. It cannot retract data or keys already received. Losing passwords or keys can make history permanently inaccessible. There is no administrator decryption key or history-decrypting reset.

## Local privacy and media

The app password uses PBKDF2-HMAC-SHA256, 600,000 iterations and a random 128-bit salt to wrap a random 256-bit app key with AES-GCM. The app key encrypts the index, including profile/chat names and bindings. Each chat has its own random 256-bit content key wrapped by its separate password, fresh salt and the same KDF. Messages, image bytes, protocol identities/sessions, pending ciphertext, and Recent/Favorites live inside that chat's ciphertext, itself inside the encrypted index.

Password changes rewrap keys. Vault replacement uses atomic, complete-protection writes. Failure delays are persistent and escalating for both app and chat passwords, including password-change authentication. A missing/corrupt delay ledger fails closed. There is no automatic deletion after failed attempts, biometric bypass, or passcode alternative.

The app requests complete file protection and excludes the private directory/files from normal backups. Backup exclusion is a platform hint and still requires physical-device backup checks. The device authentication signing key is in a WhenUnlockedThisDeviceOnly Keychain item; it is distinct from the chat-protected libsignal decryption identities.

A native opaque scene window covers inactive content synchronously at the UIKit notification; SwiftUI also replaces the UI and invalidates app/chat state. Capture state is read inside the scene's view hierarchy. Screenshots cause chat relock after iOS notifies the app, which happens after capture. There is no screenshot-blocking or screenshot-deletion claim. Protocol operations finish in synchronous scopes so private stores are not retained across network awaits; Swift/OS buffers cannot be guaranteed erased.

Image import uses the system Photos picker, resizes a still image to at most 1024 pixels, re-encodes without EXIF/GPS metadata, and limits transmitted images to 256 KB. No app-owned plaintext image or thumbnail file is written. The system picker may fetch an original from iCloud over Apple's own system connections, outside the app gateway. Received images have an internal viewer and no Photos/Files saving controls. Video, generic files, GIF services and animated media are unfinished.

The drawer has functional **Stickers** and **Emoji** tabs, local search, pack shortcuts, Recent/Favorites and close/drag controls. Three original stickers are rendered by `StarterStickers.swift`; no user screenshot assets were imported. Preferences and imported static packs are chat-encrypted. See [the supported import format](docs/sticker-format.md), limits and attribution.

No chat copying, sharing, forwarding, external opening or attachment saving is provided. The native composer allows paste but blocks export edit actions, dragging/dropping and Writing Tools; third-party keyboard extensions are disallowed. Public device-pairing identifiers can be selected; this does not expose messages. There are no analytics or third-party crash SDKs. The relay never logs request URLs, headers or bodies; CI fixture diagnostics contain method/status codes only. An authorized recipient can still transcribe or photograph a screen. A compromised OS, modified client, jailbroken device or malicious recipient is outside the official client's guarantees.

No push integration exists yet. Future APNs payloads must be generic **New message** notices with no identity/content and no revealing actions. An ordinary app cannot route Apple's system APNs connections through this gateway.

## Tests

```sh
cd server
python3 -m unittest -v
```

The local suite tests real HTTP routing/auth, invitation/approval races, session revocation, recipient access control, prekey claims, duplicate-upload conflicts and delivery status. It cannot prove client E2E encryption.

The Xcode `FuckinLocked` scheme runs local vault/protocol tests. The CI `FuckinLockedRelayTests` scheme explicitly enables two-client HTTPS fixture tests and lifecycle UI tests. The fixture must run on localhost port 8787 using the setup in `.github/workflows/ios.yml`. Its self-signed trust delegate is confined to test code. Test results are uploaded as an `.xcresult`. The suite exercises real libsignal operations and relay requests; a passing build with a skipped integration test is not a verified messaging flow.

Physical iPhones are still required to verify ordinary screenshot timing, screen recording/mirroring, app-switcher snapshots, backup exclusion, file protection, VoiceOver/accessibility and independently installed devices through the live gateway. See [device checks](docs/device-checks.md).

## Dependencies and licensing

Apple SwiftUI/UIKit/PhotosUI/ImageIO/CryptoKit/CommonCrypto/Security supply platform functionality. Python `cryptography==50.0.2` is Apache-2.0 OR BSD-3-Clause. `LibSignalClient` is pinned to v0.105.0 and a prebuilt FFI checksum using the documented CocoaPods integration. Its upstream license is AGPL-3.0-only, third-party support is explicitly unsupported, and APIs can change. Keep matching source/dependency notices available to recipients and review distribution obligations before release. [Protocol notes and primary sources](docs/protocol-integration.md) explain the maintenance/deployment assumptions.

Remaining work includes two-device call verification on physical iPhones, generic push/background-delivery design, animated/general attachments, QR pairing, broader accessibility/preferences, signed-device checks and independent security review. Background notifications are excluded from this foreground beta. Calls are not represented as a navigation tab; the relay only enables them when its authenticated TURN-over-TLS configuration is present. This is not production-ready until the call path and the complete security design receive independent review.
