# Verification report — beta 0.4.0, 2026-10-27

This is a testing beta, not a production-security certification. Historical
results are retained in [the 0.3 report](verification-history-0.3.md).

## Source and Xcode checks

The final [run 40428125711](https://github.com/deplane-hash/fuckin-locked/actions/runs/40428125711)
at `ce249a625dc339fe15907623425a06529fd7ac94` completed successfully with Xcode 26.6:

- 47 core simulator tests, zero failures.
- 1 lifecycle UI test, zero failures.
- 33 relay tests, zero failures; repeated successfully on the live host using
  isolated fixtures on 2026-10-27.

The final media-owner hardening at `0db49c65beda5ff00084f6fea96644fb4ac5b5eb`
passed all 47 core tests in [run 40425352480](https://github.com/deplane-hash/fuckin-locked/actions/runs/40425352480),
but its lifecycle test exceeded the four-minute test-runner allowance. The
diagnostic activity log reached final relaunch checks without a failed lock
assertion. This is a failed verification run, not a lifecycle pass.
`ce249a625dc339fe15907623425a06529fd7ac94` increases only bounded test-runner
allowances, retaining all assertions and production password delays.
The rerun passed all 47 core tests and the lifecycle UI test with zero failures.
The iPhone artifact is
unsigned and requires legitimate signing before installation. For Appetize,
extract the outer GitHub artifact ZIP and upload the inner simulator `.app.zip`;
a device IPA is not a simulator binary.

Verified downloads:

- [Unsigned iPhone IPA](https://github.com/deplane-hash/fuckin-locked/actions/runs/40428125711/artifacts/12701377293), version 0.4.0 build 74.
- [Appetize simulator app](https://github.com/deplane-hash/fuckin-locked/actions/runs/40428125711/artifacts/12701044077), version 0.4.0 build 1.

Both outer downloads matched GitHub's SHA-256 digests. Outer/inner ZIP integrity
passed; executable headers are arm64 and Mach-O platform 2 (iPhone) or 7
(Simulator), respectively. Execution on Appetize itself remains untested.
GitHub supplies an outer ZIP; extract the IPA or simulator app ZIP inside it.
Copies are available on the server under `/root/fuckin-locked/build/beta-0.4.0/`.

Inner-file SHA-256:

```text
fbc53ae08a6fa4e73163d735d2831b2bde17d0caa6961aa4eabf9b63e6c2633e  FuckinLocked-0.4.0-unsigned.ipa
f19240171710d98c10b5b4eb53173ad2a197b11621d2b055a190335d14e0d316  FuckinLocked-0.4.0-simulator.app.zip
```

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
The existing FreedomHub homepage returned 200 with FreedomHub content rather
than a default nginx page. Messenger and coturn were active.
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
