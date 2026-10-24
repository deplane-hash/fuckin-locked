# Verification report — 2026-10-24

## Executed in this environment

- `python3 -m py_compile server/service.py`: passed.
- `python3 -m unittest -q` in `server/`: 13 tests passed. Coverage includes single-use and expired invitations, concurrent invitation and approval single-winner behavior, pending-device approval, one-time Ed25519 challenge, bootstrap exclusivity, encrypted member names, recipient-scoped ciphertext envelopes, one-time prekey retrieval, revocation blocking sessions and new envelopes, and delivery acknowledgment authorization.
- `python3 -m py_compile service.py`: passed after relay changes.
- Source scan for accidental app network endpoints, pasteboard, sharing, drag-and-drop, context menus, and arbitrary-load ATS setting. The source has one `URLSession` client, configured for HTTPS only, with redirects refused. No export APIs were found.

## Supplied but not executed

- `ios/FuckinLockedTests/LocalVaultTests.swift` covers relocking, app and chat attempt delays across vault reinitialization, and password rewrapping. The tests have not run. This host is Linux; `xcodebuild`, `xcrun`, `swift`, `pod`, and Xcode.app were not found, and no remote macOS build tool is connected.
- `ios/Podfile` pins LibSignalClient and its prebuilt FFI checksum. CocoaPods installation, iOS compilation, simulator tests, and two-device exchange have not run.
- iOS compilation, lifecycle transition timing, app-switcher snapshots, screenshot timing, capture state, VoiceOver, Dynamic Type, Reduce Motion, secure keyboard behavior, Keychain migration, and actual file protection attributes need testing on a signed device build.
- The relay's pinned `cryptography==50.0.2` needs a clean-environment install test. The server tests here used preinstalled 41.0.7.
- TLS certificate validation and rotation need an actual gateway hostname and certificate. No server was deployed.

## Security claims not yet verified or implemented

No E2EE messaging session, attachment transfer, generic push, call media, group key rotation, identity-key comparison, secure new-device pairing UI, or independent audit exists. The UI blocks the corresponding sending paths. The relay tests establish opaque storage and authorization behavior only; they do not prove that a sender encrypted content before upload. No test can establish that the server cannot read content from a client that has not yet sent a protocol-encrypted message.
