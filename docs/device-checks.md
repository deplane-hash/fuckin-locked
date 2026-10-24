# Physical iPhone release checks

These checks are still required on two separately installed, properly signed
iPhones. A simulator result does not establish the physical-device behaviors.
Record the app commit/build, iPhone model and exact iOS version for each result.

1. Install matching app/relay revisions, bootstrap the first account, redeem one
   expiring invitation, and approve the second account. Reject reuse and expiry.
2. Bind both chats to the same room and intended device. Set different app and
   chat passwords. Compare both fingerprints through a trusted external channel.
3. Exchange text, reactions, starter stickers and still images both ways. Confirm
   relay acceptance says Sent and recipient storage acknowledgement says Delivered.
   Neither state is a read receipt. Leave a phone offline and test later delivery.
4. Queue while offline, terminate/reopen/unlock, reconnect, and confirm one message
   is delivered despite retries. Interrupt an upload after server acceptance and
   before the response; confirm the stable ID does not create another envelope.
5. Background while viewing text/media and while a settings sheet is open. Inspect
   the app switcher, return and confirm both passwords are required. Repeat for
   Control Center, incoming calls, device locking, system permission prompts,
   interruptions during a send, and interrupted password changes.
6. Start supported recording and AirPlay/mirroring before and during chat use.
   Confirm the scene capture state hides content and invalidates keys. Stop capture
   and confirm passwords are required again. Take an ordinary screenshot: it may
   contain the prior screen because the notification is after capture; the chat
   must lock when the notification arrives. The app cannot erase that screenshot.
7. Fail app/chat passwords repeatedly, restart, and confirm escalating delays
   remain. Test old/new passwords around a password change. Never auto-delete data.
8. Link an additional phone with compared public key and explicit approval. Check
   pending/expired requests cannot authenticate and no history is restored. Revoke
   it; confirm existing sessions, pending envelopes and future key requests fail.
9. Exercise VoiceOver, Dynamic Type, Reduce Motion and keyboard navigation. While
   locked, accessibility must expose no chat names/messages/images. Check media,
   long press, selection, drag, previews and navigation have no content export path.
10. With an authorized developer tool, inspect file-protection and backup flags.
    Exercise real backup/restore and verify no usable plaintext history, media or
    transferred Keychain key appears. Inspect app-owned files/logs for test strings
    and keys. Do not publish or collect actual user passwords/private keys.
11. Disable the required gateway and attempt an invalid certificate and a redirect.
    Confirm a connection error with no alternate/direct host requests. Test TLS
    renewal for the same hostname and check only public prekeys/ciphertext reach
    the relay. Photos/iCloud and future APNs system connections are outside this
    app-level routing requirement.

Independent review, encrypted server storage/backup verification, and signed-device
results remain release gates. Do not describe an unfinished or untested item as
enforced merely because the UI displays a lock.
