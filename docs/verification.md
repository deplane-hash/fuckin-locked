# Verification report — 2026-10-24

## Executed in this environment

- `python3 -m py_compile server/service.py`: passed.
- `python3 -m unittest -q` in `server/`: 14 tests passed. Coverage includes single-use and expired invitations, concurrent invitation and approval single-winner behavior, pending-device approval, one-time Ed25519 challenge, bootstrap exclusivity, encrypted member names, authenticated room listing, recipient-scoped ciphertext envelopes, one-time prekey retrieval and consumption preservation, revocation blocking sessions and new envelopes, and delivery acknowledgment authorization.
- `python3 -m py_compile service.py`: passed after relay changes.
- The host deployment virtual environment installed the pinned `cryptography==50.0.2`; the relay starts under systemd as `fuckinlocked` and listens only on `127.0.0.1:8787`.
- Through the live `freedomhub.at` HTTPS route, `/fuckin-locked/health` returned 200 and an unauthenticated `/fuckin-locked/v1/people` request returned 401. The existing FreedomHub homepage still returned 200 after the isolated route was added.
- Source scan for accidental app network endpoints, pasteboard, sharing, drag-and-drop, context menus, and arbitrary-load ATS setting. The source has one `URLSession` client, configured for HTTPS only, with redirects refused. No export APIs were found.

## Not executed on this Linux workspace

- `ios/FuckinLockedTests/LocalVaultTests.swift` covers relocking, app and chat attempt delays across vault reinitialization, and password rewrapping. `SignalProtocolTests.swift` exercises a persistent two-store libsignal prekey/whisper round trip. This host is Linux; local Xcode tools are unavailable, so these tests run in the macOS GitHub Actions workflow rather than here.
- `ios/Podfile` pins LibSignalClient and its prebuilt FFI checksum. CocoaPods installation and compilation now run in GitHub Actions on Xcode 26; the current run is the verification authority for the latest source. This does not prove live gateway delivery or signed-device behavior.
- GitHub Actions macOS 15 with Xcode 16.4 installed the pod, then failed compiling libsignal v0.105.0 because generated Swift source uses tuple trailing commas unsupported by that compiler. The workflow now targets macOS 26 and Xcode 26 for a rerun.
- The first Xcode 26 run compiled libsignal, then found view-state `error` names shadowed by Swift's implicit catch value. These app source compile errors were fixed. The next run compiled the app but CocoaPods' framework embed script was blocked by Xcode user-script sandboxing; the project setting was changed to permit that script, and the simulator suite remains to be rerun.
- iOS lifecycle transition timing, app-switcher snapshots, screenshot timing, capture state, VoiceOver, Dynamic Type, Reduce Motion, secure keyboard behavior, Keychain migration, and actual file protection attributes need testing on a signed device build.
- The relay's pinned `cryptography==50.0.2` needs a clean-environment install test. The server tests here used preinstalled 41.0.7.
- TLS validation and rotation still need a signed iOS device check. The live host route uses the existing CA-validated `freedomhub.at` certificate; the relay remains localhost-only and no direct fallback exists.

## Remote macOS simulator verification

- GitHub Actions run `40111100679` completed successfully on macOS 26.6 / Xcode 26.6. It generated the Xcode project, installed the pinned LibSignalClient CocoaPod, and ran `xcodebuild test` for the `FuckinLocked` scheme on an iPhone 17 simulator with code signing disabled.
- That run compiled the app and executed the supplied vault tests plus `SignalProtocolTests`: the libsignal prekey/whisper round trip passed using two independently serialized stores. It also verifies the app/chat lock and persistent failed-attempt delay test code at simulator runtime.
- The earlier Xcode 26 run `40110805303` failed only because `RelayPrekeyBundle` lacked `Encodable`; the fix is included in the successful run. Earlier Xcode 16.4/macOS 15 failures were toolchain incompatibilities with libsignal's generated Swift, not app protocol behavior.
- The latest source at the time of this report also completed successfully in run `40112832355` on the same Xcode 26.6/iPhone 17 simulator workflow after the receive-after-fingerprint, delivery-state, and vault rewrap validation fixes.

## Security claims not yet verified or implemented

The one-to-one libsignal session path and persistent-store round trip are implemented and covered by the simulator test suite. The live gateway health/auth boundary is verified, but two independently provisioned iPhones still need to complete encrypted delivery through that route. Attachment transfer, generic push, call media, group key rotation, secure new-device pairing UI, capture/lifecycle device checks, backup behavior, accessibility review, and independent audit remain open. The relay tests establish opaque storage and authorization behavior; the Swift protocol test establishes client-side encryption/decryption but does not replace a live two-device test. No test here proves protection against a compromised OS, modified client, or malicious recipient.
