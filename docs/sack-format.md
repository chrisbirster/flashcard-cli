# Deez `.sack` bundle format

`.sack` is the portable rich-media companion to Deez's human-readable `.nut` deck format.

A `.nut` stays NDJSON and content-only. When a deck references images, audio, or video, a `.sack` packages the `.nut` plus the referenced media in one ZIP-compatible file.

## Commands

Add a local media file:

```bash
deez media add diagram.png
```

The command stores the bytes by SHA-256 under `~/.local/share/deez/media` and prints a stable reference such as:

```text
deez-media://sha256:0123456789abcdef...
```

Use that reference inside a note field or template, for example:

```html
<img src="deez-media://sha256:0123456789abcdef...">
```

Export a rich deck:

```bash
deez sack export 1 mongodb.sack
```

Import it:

```bash
deez sack import mongodb.sack
```

## Archive layout

A `.sack` is a standard ZIP container using stored (uncompressed) entries in version 1:

```text
manifest.json
deck.nut
media/sha256/<64-character-sha256>
media/sha256/<64-character-sha256>
...
```

`deck.nut` is a normal Deez `.nut` v2 file. It contains logical notes and stable media references, but no binary blobs.

`manifest.json` contains the media metadata required to verify and restore the bundle:

```json
{
  "format": "deez.sack",
  "version": 1,
  "deck": "deck.nut",
  "media": [
    {
      "sha256": "...",
      "path": "media/sha256/...",
      "mime": "image/png",
      "size": 12345,
      "original_filename": "diagram.png"
    }
  ]
}
```

## Media identity

Media identity is the lowercase SHA-256 digest of the exact file bytes. Identical files therefore resolve to the same Deez media identity and filesystem location, regardless of filename.

Supported metadata includes:

- SHA-256 identity
- MIME type
- byte size
- original filename

The CLI recognizes common image, audio, and video extensions. Unknown extensions use `application/octet-stream`.

## Storage boundary

Media blobs are intentionally outside the deck database.

For SQLite, the database stays at `~/.local/share/deez/deez.db` and media lives beneath `~/.local/share/deez/media`.

For MongoDB, notes/cards continue to live in MongoDB while media blobs and their portable metadata live in the same local/external media store. MongoDB stores stable `deez-media://sha256:` references as note content rather than embedding potentially large binary blobs. A future remote media provider can implement the same identity contract without changing `.nut` or `.sack` files.

## Import safety

`.sack` import is intentionally strict:

- absolute archive paths are rejected
- `..`, `.`, empty path components, and backslash traversal are rejected
- duplicate archive entry names are rejected
- only `manifest.json`, `deck.nut`, and manifest-declared media entries are accepted
- ZIP CRC values are verified
- media sizes are verified
- every media SHA-256 is recomputed and verified
- the media list must exactly match the media references found in `deck.nut`
- unsupported compression/data-descriptor forms are rejected rather than guessed

The deck import is rolled back if media restoration fails. Content-addressed media that was already verified can safely remain deduplicated in the media store.

## Versioning

The current bundle identifier is:

```text
format: deez.sack
version: 1
```

Future incompatible changes require a new major bundle version. Importers reject unsupported versions instead of silently interpreting them.
