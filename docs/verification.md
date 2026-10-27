# Verification report — beta 0.4.0, 2026-10-27

This is a testing beta, not a production-security certification. Historical
results are retained in [the 0.3 report](verification-history-0.3.md).

## Source and Xcode checks

The completed [run 40422660333](https://github.com/deplane-hash/fuckin-locked/actions/runs/40422660333)
at `cffeb2ba0a98804f17528c0c2d0e21653000f51d` passed with Xcode 26.6:

- 47 core simulator tests, zero failures.
- 1 lifecycle UI test, zero failures.
- 33 relay tests, zero failures; repeated successfully on the live host using
  isolated fixtures on 2026-10-27.

The final media-owner hardening at `0db49c65beda5ff00084f6fea96644fb4ac5b5eb`
is being checked by [run 40425352480](https://github.com/deplane-hash/fuckin-locked/actions/runs/40425352480).
Use its artifacts only after it completes successfully. The iPhone artifact is
unsigned and requires legitimate signing before installation. For Appetize,
extract the outer GitHub artifact ZIP and upload the inner simulator `.app.zip`;
a device IPA is not a simulator binary.

## What the automated checks establish

The real two-isolated-client HTTPS fixture uses libsignal for encrypted text,
reactions, still/animated media and files, fingerprint approval, queued delivery
and device revocation. Tests exercise real protocol keys rather than substituting
a cosmetic lock. Local vault tests cover app/chat password protection of private
protocol records, persistent delays on both gates, restart relocking, encrypted
metadata/media, password rewrapping and interrupted atomic-write recovery.

Native tests cover synchronous inactive shielding/invalidation, export edit-action
and keyboard restrictions, bounded QR/pack/file parsing, GPS stripping, animation
frame/timing bounds and encrypted preference/avatar persistence. Native audio and
video tests validate no autoplay, memory range bounds, real AVFoundation loading
through the private memory resource loader, no external playback and lock teardown.
The video test writes only a synthetic public fixture to the test temporary
directory; production playback does not write decrypted media files.

The lifecycle UI test enters actual passwords, backgrounds/returns, terminates/
relaunches and checks both gates and the compact composer. It does not bypass
authentication. Simulator checks do not prove physical snapshot/capture timing.

Relay tests cover single-use/expiry/raced admission and approval, authentication,
session revocation, recipient-scoped ciphertext and activity, fixed-group roster
authorization, prekey recovery, idempotent upload/delivery acknowledgement,
encrypted profile/feature/push-token fields, bounded session retention and private
APNs queue behavior. Push tests use mocks and generated fixture keys, not Apple
production credentials. No test proves security against a compromised OS.

## Applied server checks

The final tested relay source was installed on 2026-10-27 after creating and
decrypt-verifying the root-only encrypted backup
`/root/fuckin-locked-backup-20261027T002322Z/snapshot.tar.gz.fernet`.
Only the messenger service restarted. Installed `service.py` and `push.py` match
the tested working source. The first health request applies additive schema
migrations; afterward SQLite integrity was `ok`, foreign-key errors were zero,
and the device-feature table existed.

The public gateway returned health 200 and unauthenticated features access 401.
The existing FreedomHub homepage returned 200. Messenger and coturn were active.
No APNs credentials are configured, so live background notices remain unavailable.

Earlier TURN checks verified the public TLS chain/name, rejected invalid
credentials, and transferred 200 sent/198 received packets on this host's public
IP. They do not prove off-host reachability, zero loss or two-iPhone WebRTC audio.
The TLS certificate expires 2027-01-23; the protected renewal hook was exercised.
See [call deployment](calls-setup.md).

## Remaining external checks and limits

- Two separately signed physical iPhones: actual live messaging and audio calls,
  camera/file-provider interactions, recording/mirroring, screenshot response,
  app-switcher snapshots, VoiceOver and real backups/file-protection behavior.
- Three separately installed clients: complete fixed-group exchange/roster-change
  testing. Server group authorization tests do not substitute for this.
- Apple APNs `.p8`, Key ID, Team ID/topic and an entitled provisioning profile,
  then real notification/token rotation/revocation tests. See [push setup](push-setup.md).
- Independent security review, parser/dependency maintenance, license obligations,
  encrypted-volume verification and off-site backup/key custody.

Background call continuation/ringing, presence, typing and read receipts are not
provided. GIF search is local, not an external integration. Groups use fixed
verified pairwise Signal fan-out, not an invented group cryptographic protocol.
No content export is provided, but recipients can transcribe or photograph it.
Screenshot notifications occur after capture; screenshots are not fully blocked.
No guaranteed memory erasure, malicious-recipient or compromised-OS protection is
claimed. See [physical-device checks](device-checks.md) before relying on the app.
