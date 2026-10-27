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

The 0.4 implementation includes bounded animated GIFs, TXT/PDF/audio/video,
QR/manual pairing and generic APNs source. Actual Apple push delivery remains
unconfigured pending protected credentials and an entitled profile. QR codes are
typed public pairing data, never automatic authorization or arbitrary URL opening.
Independent review remains absent. Authenticated, expiring approval is mandatory.
The prekey path generates a replacement after local consumption, but sustained
exhaustion and larger multi-device pools still need review. Each chat binds one
explicit remote device. New devices receive no historical keys. SwiftUI's
transient strings/data cannot be guaranteed wiped. Backup exclusions and file
protection need real-device validation. Server metadata requires operational
access control and encrypted storage/backups even though names are field-encrypted.

Imported sticker packs are bounded untrusted input. The native picker explicitly
opens in place without an app-owned plaintext import copy; scoped access ends
after the coordinated read. Schema/IDs/codecs/frame count/dimensions/bytes are
checked before whole-pack vault commit; pixels are re-encoded without source
EXIF/GPS. A lock-generation change rejects delayed picker results. Original files
and file-provider caches remain outside the vault and are not retroactively
encrypted or deleted. Schema-3 GIFs preserve bounded animation; schema 2 rejects
animation. See `sticker-format.md`.

Voice calls use a relay-only WebRTC audio path. The Calls destination opens the
required chat-password gate; actual two-iPhone media still needs verification.
The relay supplies only authenticated TURN-over-TLS configuration; WebRTC's
DTLS-SRTP protects media and libsignal protects signaling. A malicious TURN
operator observes relay metadata/timing, and recipients can record audio.
Credentials are short-lived and rotated operationally. Gateway/capability/TURN
failure closes calling with no direct media fallback. Locking ends media rather
than continuing a background call. There is no background ringing implementation.

Private file viewing is bounded untrusted parsing, not arbitrary file opening.
PDF pages render to RAM images without scripts, links or QuickLook. Native video
uses a private memory resource loader, forbids all external asset references,
disables external playback and has no export/PiP/AirPlay controls. Audio/video
never auto-play and clear on lock. Views additionally require their owning chat
to remain unlocked. Framework/OS buffers cannot be guaranteed erased. Parser
bugs and compromised OS behavior remain risks despite size/frame/duration bounds.

The server sees accounts, device keys, room membership, delivery timing, sizes,
IP addresses and call allocation metadata. Names/usernames, device feature claims
and push tokens are field-encrypted with a separate server metadata key. That key
cannot decrypt Signal payloads. Coalesced push notices contain only New message;
Apple observes push metadata and system APNs traffic bypasses app routing.
Rich-content feature claims are compatibility hints, never identity proof.
Fixed group fan-out uses separately verified Signal pairs; roster removal closes
the group and requires a fresh group for new keys. Larger groups and three-real-
device behavior require further testing.

Operational snapshots are authenticated encrypted archives; their root-only key
is stored separately from backups. It is not a message decryption key. Backups
were verified by decrypting in memory before old plaintext backup files were
removed; no filesystem secure-erasure claim is made. Full-volume encryption and
off-site key custody remain deployment assumptions requiring operator review.
