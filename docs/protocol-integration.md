# One-to-one protocol integration gate

## Decision

Use Signal's maintained `LibSignalClient` Swift bindings through its canonical CocoaPods integration. The Podfile pins `v0.105.0` and the FFI checksum used by Signal-iOS at the time of review. The upstream repository has since published newer releases, but Signal-iOS's current primary Podfile still uses this v0.105.0 pin; upgrading must repeat the checksum, API, CI, and legal review. Remote Swift Package consumption is explicitly unsupported, but CocoaPods integration is documented and used by Signal-iOS. Third-party use is unsupported by Signal, and API or binary compatibility may change without notice. Its license is AGPL-3.0-only; distribution requires a legal review and compliance with that license.

The dependency is pinned and connected to the one-to-one message path in `MessagingService.swift`. The app generates a device identity and prekeys locally, publishes only the public bundle, pins the first observed peer identity after an out-of-band fingerprint comparison, encrypts with `signalEncrypt`, and decrypts with `signalDecryptPreKey`/`signalDecrypt`. Signal records, pending peer bundles, and message ciphertext are committed inside the chat-password-protected vault before relay acknowledgement. The macOS workflow is the current compilation and simulator-test authority; live two-device delivery, signed-device capture behavior, and independent review remain open. The Python relay is still only a control-plane/ciphertext relay and never receives protocol private keys.

## Required implementation before enabling send

1. Generate Signal identity, signed prekeys, one-time prekeys, and Kyber prekeys on the device after app and chat unlock. The relay receives only public bundles. Verify signatures using libsignal, not custom cryptography. The current path publishes one one-time prekey at a time; replenishment and exhaustion handling are release work.
2. Persist every protocol record and local identity under the corresponding chat content key, with atomic encrypted-vault replacement. Keep inbound ciphertext on the relay until that chat is unlocked. Do not persist a usable protocol decryption key under the app key alone.
3. Bind each protocol address to a relay device identifier and a stable room. Pin the first observed identity per device, show an out-of-band fingerprint comparison, reject identity changes, and reject envelopes from an unexpected relay device. A server-supplied first identity is not by itself authenticated.
4. Establish sessions with `processPreKeyBundle`, send via `signalEncrypt`, and decrypt with `signalDecrypt` or `signalDecryptPreKey`. Persist the updated session and plaintext history before acknowledging delivery. The sending status remains `Sending` if the process dies after relay acceptance but before local delivery reconciliation; duplicate/retry reconciliation needs a live integration test.
5. Fan out a separately encrypted envelope to each active recipient device. On revocation, stop authorizing that device at the relay, terminate its sessions, delete undelivered envelopes/prekeys, and refresh sender device lists before the next send. Revocation cannot erase ciphertext or session keys already obtained by a revoked device.
6. Test two independently installed clients through the HTTPS gateway, including offline delivery, restart, wrong password, identity substitution, prekey exhaustion, replay, concurrent send, revocation, and gateway failure. Check transport logs and relay database for plaintext and keys.

## Sources

- [libsignal Swift integration guide](https://github.com/signalapp/libsignal/blob/main/swift/README.md)
- [libsignal Swift protocol API](https://github.com/signalapp/libsignal/blob/main/swift/Sources/LibSignalClient/Protocol.swift)
- [libsignal store protocols](https://github.com/signalapp/libsignal/blob/main/swift/Sources/LibSignalClient/DataStoreProtocols.swift)
- [Signal-iOS Podfile pin](https://github.com/signalapp/Signal-iOS/blob/main/Podfile)
- [libsignal repository and license](https://github.com/signalapp/libsignal)
