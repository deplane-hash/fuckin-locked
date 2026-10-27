# Local sticker packs

Open an unlocked chat's sticker drawer and choose **Import sticker pack**. Import
a single UTF-8 `.json` document using schema 2 (PNG/JPEG) or schema 3 (also GIF).
The earlier schema-1 directory
proposal was never implemented and is not accepted.

```json
{
  "schema": 2,
  "id": "my-pack",
  "name": "My original pack",
  "author": "Artist",
  "license": "CC0-1.0",
  "stickers": [
    {"id": "hello", "name": "Hello", "tags": ["greeting"], "image": "BASE64_PNG_OR_JPEG_BYTES"}
  ]
}
```

Replace the image placeholder with base64 PNG/JPEG data. Only import artwork you
own or have permission to use. Attribution stays in **Pack credits**. Imported
artwork, attribution, Recent and Favorites are chat-password encrypted. The app
reads the scoped source URL without creating a plaintext import or thumbnail
file. The external original remains wherever you placed it; importing does not
encrypt or delete it. File providers may use their own cloud connections.

[Download the original CC0 example pack](example-sticker-pack.json) to exercise
the importer with a small, non-private lime-circle asset.

- Schema 2 or 3, 1–32 stickers, unique lowercase ASCII IDs using letters/digits/`-`/`_`.
- At most 3 MB JSON, 2 MB decoded images per pack, 8 packs and 8 MB per chat.
- PNG/JPEG at most 1024 × 1024 pixels and 256 KB per image.
- Schema-3 animated GIF: 2–30 frames, at most 512 × 512 pixels including logical canvas,
  4,194,304 aggregate decoded pixels, 256 KB, 20 ms–1 second per frame, at most 100 loops.
- Bounded names, tags, author and license; no control characters.
- No URLs, archive extraction, asset paths, symlinks or scripts.

Pixels are re-encoded as PNG, preserving alpha and dropping source EXIF/GPS.
Re-encoded artwork must also fit the limits. Schema 2 rejects animation. Schema 3
preserves supported GIF animation through bounded ImageIO re-encoding; unsupported
animation is rejected. Reduce Motion displays the first frame. GIF search stays
local and never contacts a third-party search service.

The complete pack commits through the atomic encrypted vault. A lock-generation
change rejects a delayed picker result. If the picker causes an inactive
transition, reopen and unlock before retrying; locks are never bypassed.

Apple references: [open-in-place picker](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller/init(foropeningcontenttypes:ascopy:)),
[Image I/O destinations](https://developer.apple.com/documentation/imageio/cgimagedestination).
