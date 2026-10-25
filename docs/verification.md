# Verification report — 2026-10-25

## Call privacy corrections awaiting new Xcode verification

- Incoming calls now require explicit Accept before network/media construction.
  Both directions check verified identity, unlocked chat, app activity, and an
  operation generation across asynchronous setup. Every vault lock stops the
  call synchronously, including screenshots, recording, and password changes.
- Media failures disable the track, close the connection, clear candidate
  buffers, and deactivate audio. Outbound signaling is serialized; SDP precedes
  ICE. Call signaling no longer enters the durable message retry outbox and
  carries an encrypted expiration. Legacy call history remains decodable but
  cannot trigger calls.
- Added coordinator tests for consent, rejection, identity changes, synchronous
  locks, delayed completions, failed media setup, and matching hangups. Added an
  HTTPS integration regression for abandoned offline calls and expiry tests.
  These new iOS checks are pending the next macOS workflow.
- Corrected the UIKit composer's vertical sizing and duplicate local-draft
  notice. Local drafts remain explicitly separate from recipient-bound chats.
- Previous run 40149937507 built the unsigned device IPA and passed the
  protocol/vault suite, but lifecycle verification timed out with an incomplete
  result bundle. The lifecycle job now uses a fresh simulator and propagates
  failures without continue-on-error. A timeout is never a pass.
- Server suite rerun locally: 21 tests passed. Physical iPhone call audio,
  TURN deployment, capture/snapshot timing, and signing remain unverified.

## Current milestone status (supersedes historical notes below)

- The voice-call transport is now implemented in source: authenticated call
  signaling is carried as libsignal ciphertext, WebRTC is configured with
  relay-only ICE and a same-host `turns:` endpoint, and calls stop on inactive
  transitions. The server advertises `encrypted_calls_v1` only with a complete
  TURN-over-TLS configuration and never exposes the route without an active
  session. Calls remain omitted from bottom navigation.
- Server suite currently passes **21 tests**, including authenticated TURN
  capability gating, invalid/absent TURN configuration, opaque envelope
  storage, revocation, and invitation races.
- Xcode run `40144712171` compiled the WebRTC/libsignal integration and passed
  the full protocol/vault simulator suite, including the call-signal ciphertext
  assertion. Its lifecycle UI test failed only on the local-draft status lookup;
  run `40145403938` reruns that test using the explicit accessibility identifier.
- A physical two-iPhone test is still required for microphone permission,
  TURN certificate/credential rotation, DTLS-SRTP audio, background teardown,
  capture behavior, and call interruption. The call path is not production-ready
  or independently reviewed.

- The local relay suite now has **18 passing tests**, including actual HTTP route
  dispatch/auth, stable ciphertext upload IDs/conflict detection, sender-only
  delivery status, expiring device approval and recoverable requester-scoped
  prekey claims. No production database or live accounts are used by these tests.
- Expanded Xcode runs `40129471328` and `40130411164` compiled the app but failed
  the explicitly enabled relay integration test with a connection error. This
  corrects the earlier assumption that a successful build proved that integration
  test ran: setting a shell variable alone did not establish test-runner activation.
- The CI-only scheme now passes the fixture enable flag directly to the test
  runner. Results are preserved as an `.xcresult` and include failure summaries.
- Run `40131001883` found a new compose-view catch-variable compile error; that
  error is fixed in the working source. The newest rerun must be checked before
  calling this source a buildable or verified beta.
- Run `40131445830` compiled and ran **19 simulator tests: 18 passed, 1 failed,
  0 skipped**. The passing cases include the real UI background/relaunch test,
  vault/password-failure/atomic-write tests, and the libsignal store round trip.
  The HTTPS fixture health request succeeds; integration stops at the first
  device's Keychain identity creation before a bootstrap POST reaches the server.
  The next revision uses ad-hoc simulator signing with explicit simulator-only
  Keychain entitlements and reports safe OSStatus codes. Device builds do not use
  the simulator entitlement file. This correction still requires a successful run.
- Run `40132216165` validates that correction: **the two-client HTTPS/libsignal
  integration test passed**, including invitation → approval → device binding →
  both password gates → text/reaction/image delivery → offline queue reopening →
  additional-device approval → session revocation and no silent forwarding.
  All 18 non-UI cases passed; the one lifecycle UI case failed an assertion in
  that run. Earlier unsigned simulator run `40131445830` passed that UI case.
  The test is now isolated, time bounded and given descriptive assertion messages;
  its exact prior source location is being extracted before a beta is verified.
- A restricted native composer and third-party keyboard policy have been added
  to close default Copy/Cut/drag/Writing Tools paths. Their new tests require the
  next Xcode run. Public pairing keys remain selectable by design.
- Added source/tests: persisted encrypted outbox; distinct Sent/Delivered states;
  images/reactions; original stickers and encrypted preferences; explicit device
  linking; synchronous native inactive cover; scene-local capture observation;
  generation checks rejecting stale async completions; password-wrapper failure
  recovery; and real simulator background/relaunch UI coverage. New tests are not
  reported as passed until the matching Xcode run succeeds.
- No new source in this milestone has been installed on physical iPhones. Live
  two-device E2E, screenshots/recording/mirroring, snapshot timing, backup behavior
  and full accessibility checks remain unverified. See `device-checks.md`.
- Source changes are not automatically deployed to the live relay. The new client
  requires matching authenticated relay capabilities and fails closed on an older
  service. The prior signing failure requires valid matching repository secrets.

The following sections record earlier results and limitations for traceability;
their old feature counts and pending-work descriptions are historical.

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
