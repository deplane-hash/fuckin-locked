# Foreground beta 0.3.0

This is a testing release, not a production-security certification. Use test
messages first. Simulator results do not replace two real iPhones.

## Download and install

Use the successful run for the latest source on
[GitHub Actions](https://github.com/deplane-hash/fuckin-locked/actions).
The verified 0.3.0 artifacts are [iPhone IPA](https://github.com/deplane-hash/fuckin-locked/actions/runs/40199838055/artifacts/12602032741)
and [Appetize simulator](https://github.com/deplane-hash/fuckin-locked/actions/runs/40199838055/artifacts/12602047167).

- Real iPhones: download `fuckin-locked-unsigned-ipa`, extract the outer GitHub
  ZIP, sign its `.ipa` with a valid matching profile, then install.
- Appetize: download `fuckin-locked-appetize-simulator`, extract the outer GitHub
  ZIP, and upload `FuckinLocked-simulator.app.zip`. Do not upload a device IPA
  or the device `.app` extracted from it. No Apple signing certificate is needed
  for the simulator. Select a supported iOS version at least 18.

## Start the first account

The live deployment had no enrolled users at the 2026-10-25 preparation check.
The one-time setup secret is in a root-only server file. Retrieve it privately
in PowerShell (never add it to GitHub or send it to friends):

```powershell
scp root@62.171.165.206:/root/fuckin-locked-first-device-setup.txt "$HOME\Downloads\first-device-setup.txt"
```

Create the app password, open **You → First device setup**, and enter the setup
secret, name and username. Delete the downloaded secret after use. Bootstrap is
refused once an account exists; it is not a recovery/decryption key. Friends
must use an invitation and existing-member approval.

## Two-device test

1. Create an invitation in People. On the other phone choose You → Use
   invitation. The first phone explicitly approves the admission.
2. Create a new encrypted conversation; the other phone continues the same room.
   Set different local chat passwords. Local drafts never deliver messages.
3. Compare both device fingerprints through a trusted channel and approve them.
4. Keep that chat open and unlocked on both phones. Exchange text, reactions,
   images and starter/imported stickers. Sent means relay acceptance; Delivered
   means durable recipient storage, not a read receipt.
5. Retry interrupted messages and restart the app. Queued messages should retain
   their identity and deliver once. Plaintext drafts are not delivery receipts.
6. Call from the chat's phone button. Accept on the other device. Test audio both
   ways, hangup, decline and unanswered timeout. The first microphone permission
   prompt may lock the app; unlock and retry after granting permission.
7. Leave the chat: its password must be required again. Background/force-quit and
   return: both passwords must be required. Check persistent failed-password
   delays on both gates using test data.
8. Open the app switcher, record/mirror the screen and take a screenshot. Check
   hiding/relocking. Screenshot notification arrives after capture and cannot
   prevent the screenshot that already happened.
9. Revoke the other device. New service access/messages must fail. Previously
   delivered data cannot be retracted. Re-enrollment must not restore history.

Messages and incoming calls are fetched only while their chat is open and
unlocked. No background push, CallKit ringing or background call continuation is
included. Locking stops calls immediately. No Calls tab or unfinished GIF tab is
shown. General files/video/animated-sticker import is not advertised.

## Server route and limits

Service requests use `https://freedomhub.at/fuckin-locked/`; call media uses
`turns:turn.freedomhub.at:5349?transport=tcp` with relay-only ICE and normal TLS
validation. There is no direct fallback. The gateway cannot decrypt libsignal
messages or WebRTC DTLS-SRTP audio. Apple/system file-provider traffic is outside
ordinary app routing control.

Server health/TLS/TURN checks do not prove two-iPhone audio or signed-device
vault behavior. Report the iOS version, build, steps and expected/actual result
without passwords, private keys or real message contents. Complete the
[device checks](device-checks.md) and independent security review before relying
on the app for sensitive communication.
