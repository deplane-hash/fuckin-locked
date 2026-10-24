# One-to-one protocol integration gate

## Decision

Use Signal's maintained `LibSignalClient` Swift bindings through its canonical CocoaPods integration. The Podfile pins `v0.105.0` and the FFI checksum used by Signal-iOS at the time of review. Remote Swift Package consumption is explicitly unsupported, but CocoaPods integration is documented and used by Signal-iOS. Third-party use is unsupported by Signal, and API or binary compatibility may change without notice. Its license is AGPL-3.0-only; distribution requires a legal review and compliance with that license.

The dependency is pinned, **not integrated into a working message path**. `pod install`, compilation, protocol tests, and device exchange have not run. Sending stays disabled until the checks below pass. The Python relay's prekey endpoint is a control-plane prototype, not proof of end-to-end encryption.

## Required implementation before enabling send

1. Generate Signal identity, signed prekeys, one-time prekeys, and Kyber prekeys on the device after app and chat unlock. The relay receives only public bundles. Verify signatures using libsignal, not custom cryptography.
2. Persist every protocol record and local identity under the corresponding chat content key, with atomic updates to the encrypted vault. Keep inbound ciphertext on the relay until that chat is unlocked. Do not persist a usable protocol decryption key under the app key alone.
3. Bind each protocol address to a relay device identifier and a stable room. Pin the first observed identity per device, show an out-of-band fingerprint comparison, and stop sending on any identity change until explicit verification. A server supplied first identity is not by itself authenticated.
4. Establish sessions with `processPreKeyBundle`, send via `signalEncrypt`, and decrypt with `signalDecrypt` or `signalDecryptPreKey`. Persist the updated session and plaintext history atomically before acknowledging delivery. Retry safely after interruption without duplicate display.
5. Publish multiple one-time prekeys, replenish them, and test concurrent fetches and exhausted bundles. The current single-bundle endpoint is insufficient for normal asynchronous operation.
6. Fan out a separately encrypted envelope to each active recipient device. On revocation, stop authorizing that device at the relay and refresh sender device lists before the next send. Revocation cannot erase ciphertext or session keys already obtained by a revoked device.
7. Test two independently installed clients through the HTTPS gateway, including offline delivery, restart, wrong password, identity substitution, prekey exhaustion, replay, concurrent send, revocation, and gateway failure. Check transport logs and relay database for plaintext and keys.

## Sources

- [libsignal Swift integration guide](https://github.com/signalapp/libsignal/blob/main/swift/README.md)
- [libsignal Swift protocol API](https://github.com/signalapp/libsignal/blob/main/swift/Sources/LibSignalClient/Protocol.swift)
- [libsignal store protocols](https://github.com/signalapp/libsignal/blob/main/swift/Sources/LibSignalClient/DataStoreProtocols.swift)
- [Signal-iOS Podfile pin](https://github.com/signalapp/Signal-iOS/blob/main/Podfile)
- [libsignal repository and license](https://github.com/signalapp/libsignal)
