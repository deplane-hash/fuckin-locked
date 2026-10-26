# Generic background notifications

The app and relay implement registration, encrypted token storage and a durable
coalescing queue. Only the fixed payload below can be sent; there is no preview,
sender-name, group-name, attachment or reply-action option.

```json
{"aps":{"alert":"New message","sound":"default"}}
```

Tapping a notification locks the app even if it was already open. Messages and
attachments remain on the relay as ciphertext until the recipient enters the
app and chat passwords. Push does not decrypt in the background. Calls stop on
locking; background audio continuation is intentionally incompatible with the
mandatory locks, not an option that can be enabled by a setting.

## Missing deployment inputs

Live push requires an Apple-issued **APNs authentication `.p8` key**, its **Key
ID**, the **Apple Team ID**, the exact signed **bundle identifier**, and a valid
**Push Notifications-enabled provisioning profile**. A distribution-signing
`.p12` alone cannot provide the APNs authentication key or entitlements.
No live APNs credentials have been supplied. The server does not advertise push
capability without a complete protected P-256 key configuration. Registration
reports that setup is needed rather than pretending notices can arrive.

1. Put the Apple APNs key outside source control, owned by the service account,
   mode 0600. Keep it outside ordinary backups or encrypt its operational backup.
2. Add the values from `deploy/apns.env.example` to the existing protected relay
   environment. Preserve the metadata/TURN/bootstrap keys and existing database.
3. Sign with a profile containing `aps-environment`. Development profiles use
   Apple's sandbox; Ad Hoc/distribution profiles normally use production. The
   relay's topic must match the actual signed bundle ID, including when a
   signing service changes it. Re-signing cannot invent Apple entitlements.
4. Restart only the messenger relay. In You → Notifications, request permission,
   unlock again if the system permission prompt locks the app, and complete
   registration while authenticated. Test an actual background notice on an
   iPhone; simulator registration and mock HTTP tests do not prove live delivery.

The server signs ES256 provider tokens with maintained PyJWT 2.15.1 (MIT) and
uses HTTPX 0.28.1 (BSD-3-Clause) with HTTP/2, TLS certificate validation, no
redirects and no environment proxy. APNs connections originate on your server.
Apple's system connection from iPhone to APNs cannot be routed through an
ordinary app's gateway. No message/private protocol key reaches Apple.

The queue coalesces by recipient and expires after five minutes. It survives
relay restart; delivered messages suppress pending notices. Temporary errors
back off. Invalid/unregistered device tokens are removed. Revocation removes
that device's queued notices and token; an already in-flight generic notice
cannot be retracted. Push tokens are encrypted using device-bound associated
data under the server metadata key. HTTP URLs, tokens, provider JWTs and error
bodies are not logged.

Rotate `.p8` keys by provisioning a new protected key/Key ID, restarting the
relay to close old HTTP/2 sessions, testing delivery, then revoking the old key
with Apple. Token/topic/environment changes require re-registration testing.

Primary references: [Apple APNs setup](https://developer.apple.com/documentation/usernotifications/setting-up-a-remote-notification-server),
[token authentication](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns),
[PyJWT API](https://pyjwt.readthedocs.io/en/stable/api.html),
[HTTPX HTTP/2](https://www.python-httpx.org/http2/).
