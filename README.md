# fuckin locked — implementation preview

This repository contains a native iPhone app source project and a runnable ciphertext relay. **It is not a working secure messenger yet.** The app deliberately disables message sending, attachments, and calls until an independently reviewed end-to-end protocol integration is implemented and tested. The local password vault and the service's invitation/device controls are implemented; their iOS behavior has not been device-tested in this environment.

## What runs

- `ios/`: SwiftUI iPhone app for iOS 18+, generated with XcodeGen. App password, per-chat passwords, encrypted local draft vault, immediate relock hooks, read-only privacy page, invitation enrollment, first-device bootstrap, member listing, invitations, and device listing/revocation.
- `server/`: Python 3.11+ standard-library HTTP service with `cryptography` for Ed25519 verification. It stores only opaque envelope bytes; it has no decryption endpoint or content key. Admission uses a single-use expiring invitation followed by active-member approval. A new device must have its public key submitted by an authenticated existing device and then explicitly approved.
- `deploy/`: deployment templates. Nothing has been deployed.

The compose screen creates an explicitly labeled **local draft chat**. The conversation screen says messaging is unavailable and has no send action. It does not simulate successful encrypted delivery.

## Setup

### Relay on a development machine

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

The relay binds **127.0.0.1:8787**. For an iPhone build, expose it only through an authenticated HTTPS gateway configured from `deploy/nginx.conf.example`. The app rejects any gateway URL that is not HTTPS or still uses the placeholder host. It never falls back to another host or direct relay address. The server-side listener must remain local to the host. Do not use a self-signed certificate with a trust bypass in the app.

### iPhone app

On macOS with Xcode 26+, XcodeGen, and CocoaPods (required by the pinned libsignal release):

```sh
cd ios
# Set FL_GATEWAY_URL in Config.xcconfig to your actual https:// gateway origin.
xcodegen generate
pod install
open FuckinLocked.xcworkspace
```

Set the bundle identifier and signing team for your account, then build to an iOS 18+ device. The provided `Config.xcconfig` is a placeholder and will fail closed. Set the actual hostname before building. The app uses system TLS trust evaluation through `URLSession`; it has no certificate bypass, alternate endpoint, web view, or third-party network service. Rotate the TLS certificate by installing a CA-valid replacement on the same hostname, reloading nginx, and testing a signed iOS build. A hostname change requires a reviewed app configuration update. Keep old keys only as long as needed for TLS handover; never embed the server's private TLS key in the app.

Set a strong app password. For the very first account, use **First device setup** with the secret from `FL_BOOTSTRAP_TOKEN`; the signing key is generated on that iPhone. The service allows this only while no user exists. Remove the bootstrap secret from the service environment after first setup. Later users redeem an invitation in **Use invitation**; an active member approves the pending admission in **People**. New-device enrollment is server-side only for now: the existing device must submit the new device's public key through an authenticated session and approve the pending device. A secure pairing UI and out-of-band fingerprint comparison remain to be built.

### Tests

```sh
cd server
python3 -m unittest -v
```

On macOS after `xcodegen generate`, run the `FuckinLockedTests` scheme in Xcode. Those tests cover app/chat relock, persistent delays, and app password rewrapping. They are supplied but **not run here** because this environment has no Swift, Xcode, or iOS simulator.

## Key hierarchy and local protection

The app password goes through PBKDF2-HMAC-SHA256 with a random 128-bit salt and 600,000 iterations to wrap a random 256-bit app key with AES-GCM. The app key encrypts the local index, including chat names and device/account identifiers. Every chat has a separate random 256-bit content key wrapped by its own chat password, salt, and the same KDF. Chat content is AES-GCM encrypted with that content key inside the already encrypted index. Password changes rewrap the relevant key; they do not decrypt and rewrite the message body. No password or content key is sent to the relay. CryptoKit and CommonCrypto provide the cryptographic implementations; there is no custom cipher.

The vault file uses complete file protection and requests backup exclusion for its private directory and files. Apple's backup-exclusion resource flag is a hint rather than an absolute guarantee; backup behavior needs device verification. The device signing key is stored in a ThisDeviceOnly, WhenUnlocked Keychain item. The app clears SwiftUI message arrays and releases key references when inactive, on capture, and on leaving a chat. Swift and OS-managed memory may retain copies; guaranteed erasure is not claimed. App and chat backoff is stored on disk and survives an ordinary app restart, but a compromised or modified device can alter local state or its clock.

The relay database stores names and usernames encrypted with AES-GCM under `FL_METADATA_KEY`, and a keyed hash of usernames for uniqueness. It also stores membership, device public keys, invitation state, delivery times, ciphertext sizes, and ciphertext. It **must be placed on an encrypted volume** in deployment; field encryption does not cover all metadata. Keep the metadata key outside the database and back it up securely; losing it makes member names unrecoverable. The service can learn this metadata while running. It cannot decrypt ciphertext sent to its envelope endpoint because no message decryption keys are accepted or stored. At present, no official app code sends envelopes.

## Network and notifications

Only the configured HTTPS gateway is used for app service requests. Gateway failure produces “Can't connect.” The gateway sees transport metadata and forwards opaque envelopes. End-to-end encryption must remain independent of it. There is no push integration yet. A future APNs integration must send only a generic wake notification such as “New message,” with no sender, group, message, or attachment content. Apple's system APNs connections cannot be routed through this app-level gateway.

## Security work still required before real messaging

1. Install and integrate the pinned [Signal libsignal](https://github.com/signalapp/libsignal) CocoaPod for one-to-one asynchronous sessions on iOS, with durable encrypted protocol state and prekey publication/consumption. Its remote Swift Package integration and third-party use are unsupported. Verify compilation, license obligations, and upgrades; see `docs/protocol-integration.md`.
2. Build group key management using a maintained protocol/library, with membership changes and device revocation causing new key epochs. Do not use an ad-hoc shared room key. Add device-key fingerprints, out-of-band identity verification, and an explicit stop-and-review flow for identity changes.
3. Add encrypted attachment and thumbnail handling, no plaintext temporary files, authenticated chunking, internal media viewer, and encrypted sticker transport. The current emoji drawer is local UI only; GIFs and animated stickers are not implemented.
4. Add approval/pairing UI, call signaling/media with an audited encrypted calling library, and all service traffic through the gateway. Calls have no active tab.
5. Add generic APNs notifications, background delivery design, full device tests, integration tests, accessibility audit, privacy snapshot tests, and independent security review. No plaintext history restoration to a new device is planned.

The app has no copy, share, drag, external forwarding, open-in, Photos save, or Files save controls for chat content. A modified client, jailbroken device, compromised OS, or malicious recipient is outside this guarantee. An authorized recipient can still photograph or transcribe what they see.

## Dependency and license notes

The current iOS code uses Apple SwiftUI, UIKit, CryptoKit, CommonCrypto, and Security frameworks. The relay specifies `cryptography` 50.0.2 (Apache-2.0 OR BSD-3-Clause); local server tests ran against the preinstalled 41.0.7, so the pinned deployment version still needs a clean-install test. No sticker assets are bundled. `libsignal` is AGPL-3.0-only, currently maintained, and provides Swift bindings. It is pinned in `ios/Podfile`, but **has not been installed, compiled, or connected to message sending**. Its third-party support and license implications are documented in `docs/protocol-integration.md`. See `docs/threat-model.md` for limits.
