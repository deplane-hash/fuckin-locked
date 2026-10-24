# Threat model and verification limits

## Protected assets

App and chat passwords, local app/chat keys, device signing keys, message and attachment content, member admission, and device authorization.

## Trust boundaries

The iPhone app controls its UI and local vault on an uncompromised device. iOS supplies file protection, Keychain access control, capture notifications, and TLS trust evaluation. The gateway authenticates TLS for app requests and forwards to a localhost relay. The relay authenticates devices, controls membership and delivery, and stores opaque envelopes. The one-to-one path uses libsignal on approved devices; the relay receives public prekey material and ciphertext, not protocol private keys.

## Attacker capabilities considered

- Network attacker can drop, replay, or alter traffic but should fail TLS certificate validation. Gateway outage must never trigger direct fallback.
- Unapproved user may possess or guess an invitation; codes are high entropy, single use, expire, and still need approval.
- Revoked device may hold ciphertext and keys delivered before revocation. Revocation blocks new authenticated requests and new envelopes, removes its undelivered envelopes and published prekeys, and terminates its sessions. A request already in flight can complete before the revocation transaction wins the database lock. Revocation cannot retract previously delivered data. Future group rekeying is mandatory before group messaging can be enabled.
- Someone with a locked but otherwise uncompromised phone may read on-disk files; app/chat keys require their separate passwords and files use complete protection. Password quality remains important. The persistent delay is not tamper-resistant against a compromised device.
- A malicious gateway or relay can withhold, reorder, or duplicate ciphertext and observe metadata. libsignal authenticates the session and the local vault deduplicates acknowledged envelope IDs, but availability, ordering, and retry reconciliation remain metadata/implementation concerns.
- A recipient can reveal content through transcription, photography, or a modified client. The official UI's lack of export cannot prevent this.

## Capture and background behavior

On inactive scene state the app immediately replaces content with a plain cover and drops its unlocked vault state. It uses SwiftUI's supported `isSceneCaptured` environment value for screen recording/mirroring and UIKit's screenshot notification to lock a chat after a screenshot. A screenshot notification is delivered **after** capture, so ordinary screenshots cannot be claimed blocked. These hooks require device checks on each supported iOS release. No private secure-text-field layer trick is used.

## Open risks

The current milestone adds bounded still-image/sticker transport and reactions
inside libsignal messages, an encrypted retry queue with stable upload IDs,
requester-scoped recoverable prekey claims, and explicit public-key device linking
with a ten-minute approval expiry. Chat identity/session operations occur in
synchronous scopes rather than retaining private protocol stores across network
awaits. Scene-local capture state and an opaque UIKit window supplement the
SwiftUI inactive cover; physical-device timing remains unverified. The system
Photos picker may use iCloud connections outside the app gateway. There is no
app-owned plaintext media cache. See `verification.md` for current pass/fail status.

Historical limitations below that say attachment exchange or pairing UI are absent
refer to the original foundation: still images and manual compared-key pairing
are now implemented, while general/animated files, QR pairing, group messaging,
push and calls remain unfinished. Each chat binds one remote device; adding a
device never silently authorizes it in existing protocol sessions.

There is no attachment exchange, push, calls, group key rotation, secure new-device pairing UI, or independent review. The relay is a control-plane and ciphertext-storage prototype, not proof of complete secure messaging. Its one-time prekey endpoint is integrated for the first one-to-one session but needs replenishment/exhaustion handling for normal asynchronous operation. The current chat binding supports one remote device; adding devices requires a separate approved binding and rekey design. SwiftUI's transient string and data buffers cannot be guaranteed wiped. Apple's backup exclusion is a resource hint and needs device-level verification; a backup policy should additionally exclude the app's private files. The relay's metadata requires encrypted server storage and operational access control, even though names and usernames are field-encrypted. Server backups, if enabled, must also be encrypted and must never contain plaintext content.
