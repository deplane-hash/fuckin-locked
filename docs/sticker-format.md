# Sticker assets and future import contract

The shipped Energy/Night starter packs are original artwork drawn by code in
`StarterStickers.swift`. They are sent as bounded images inside libsignal messages.
No downloaded third-party assets or screenshot examples are included.

Recent/Favorites and local search selections belong to the unlocked chat. They
are saved inside its encrypted payload. Searches are never sent to a GIF service.

Pack import is not implemented. A future importer should accept this versioned
manifest plus local image files, after validating the whole pack before writing:

```json
{
  "schema": 1,
  "id": "my-original-pack",
  "name": "My pack",
  "author": "Artist",
  "license": "License identifier or permission text",
  "stickers": [
    {"id": "hello", "name": "Hello", "tags": ["greeting"], "file": "hello.png"}
  ]
}
```

- Allow only flat relative filenames, no paths, symlinks, remote URLs or scripts.
- Require unique pack/sticker IDs, bounded strings and at most 100 assets.
- Version 1 assets are static single-frame PNG/JPEG, at most 1024 × 1024 pixels
  and 256 KB each. Preserve PNG alpha; reject oversized or malformed media.
- Store imported files and generated thumbnails under a chat-protected key; do
  not place decrypted files in temporary/share/backup directories.
- Animation is not supported by the present client. Reject animation explicitly;
  do not silently flatten it or claim it has been preserved. An animated format
  needs a later schema with codec/frame/memory limits and an internal renderer.
- Ship attribution/license information with any imported licensed pack.

This document defines a future compatibility contract, not a working import UI.
