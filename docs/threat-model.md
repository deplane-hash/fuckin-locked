# Threat model and verification limits

## Protected assets

App and chat passwords, local app/chat keys, device signing keys, message and attachment content, member admission, and device authorization.

## Trust boundaries

The iPhone app controls its UI and local vault on an uncompromised device. iOS supplies file protection, Keychain access control, capture notifications, and TLS trust evaluation. The gateway authenticates TLS for app requests and forwards to a localhost relay. The relay authenticates devices, controls membership and delivery, and stores opaque envelopes. An eventual E2EE library must keep content keys exclusively on approved devices.

## Attacker capabilities considered

- Network attacker can drop, replay, or alter traffic but should fail TLS certificate validation. Gateway outage must never trigger direct fallback.
- Unapproved user may possess or guess an invitation; codes are high entropy, single use, expire, and still need approval.
- Revoked device may hold ciphertext and keys delivered before revocation. Revocation blocks new authenticated requests and new envelopes, removes its undelivered envelopes and published prekeys, and terminates its sessions. A request already in flight can complete before the revocation transaction wins the database lock. Revocation cannot retract previously delivered data. Future group rekeying is mandatory before group messaging can be enabled.
- Someone with a locked but otherwise uncompromised phone may read on-disk files; app/chat keys require their separate passwords and files use complete protection. Password quality remains important. The persistent delay is not tamper-resistant against a compromised device.
- A malicious gateway or relay can withhold, reorder, or duplicate ciphertext and observe metadata. Future protocol integration must authenticate senders and detect replay; this is not implemented.
- A recipient can reveal content through transcription, photography, or a modified client. The official UI's lack of export cannot prevent this.

## Capture and background behavior

On inactive scene state the app immediately replaces content with a plain cover and drops its unlocked vault state. It uses SwiftUI's supported `isSceneCaptured` environment value for screen recording/mirroring and UIKit's screenshot notification to lock a chat after a screenshot. A screenshot notification is delivered **after** capture, so ordinary screenshots cannot be claimed blocked. These hooks require device checks on each supported iOS release. No private secure-text-field layer trick is used.

## Open risks

There is no E2EE protocol session, no attachment exchange, no push, no calls, no secure new-device pairing UI, and no independent review. The relay is a control-plane and ciphertext-storage prototype, not proof of complete secure messaging. Its single-use prekey bundle endpoint has not been integrated with libsignal and needs replenishment for normal asynchronous use. SwiftUI's transient string and data buffers cannot be guaranteed wiped. Apple's backup exclusion is a resource hint and needs device-level verification; a backup policy should additionally exclude the app's private files. The relay's metadata requires encrypted server storage and operational access control, even though names and usernames are field-encrypted. Server backups, if enabled, must also be encrypted and must never contain plaintext content.
