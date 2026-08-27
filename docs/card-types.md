# Built-in note and card types

Deez stores **notes** as source content and derives study **cards** from a note type. Review history belongs to generated card identities, not to rendered front/back text.

This model is shared by SQLite and MongoDB and is the content boundary future CLI, desktop, mobile, and web clients should use.

## Built-in note types

### Basic

Fields:

- `Front`
- `Back`

Generates one card with stable identity `note:<note-id>:template:0`.

```bash
deez note add 1 basic "What is BSON?" "Binary JSON"
```

### Basic + Reverse

Fields:

- `Front`
- `Back`

Generates two cards:

- forward: `note:<note-id>:template:0`
- reverse: `note:<note-id>:template:1`

```bash
deez note add 1 reverse "France" "Paris"
```

### Basic + Optional Reverse

Fields:

- `Front`
- `Back`
- `Add Reverse`

A non-empty third field requests the reverse generated card.

```bash
deez note add 1 optional-reverse "France" "Paris" "yes"
```

### Cloze

Fields:

- `Text`
- `Extra`

Cloze markup follows the familiar form:

```text
{{c1::Paris}} is the capital of {{c2::France}}.
```

Each distinct cloze ordinal produces one generated card. Repeating `c1` in the same note still produces one `c1` card. Identities are stable and ordinal based:

```text
note:<note-id>:cloze:1
note:<note-id>:cloze:2
```

### Type in the Answer

Fields:

- `Front`
- `Back`

The built-in template contains `{{type:Back}}`. The renderer exposes typed-answer metadata while terminal study retains a self-grade fallback.

### Multiple Choice

Fields:

- `Prompt`
- `Choices`
- `Correct`
- `Explanation`

Generates one card. `Choices` is JSON containing stable choice IDs and display text; `Correct` is the stable choice ID rather than a letter or array position. This lets graphical clients randomize choices without changing the semantic answer.

### Multiple Select

Fields:

- `Prompt`
- `Choices`
- `Correct`
- `Explanation`

Generates one card. `Correct` is a JSON array of stable choice IDs. All IDs are validated against `Choices`.

### Ordering

Fields:

- `Prompt`
- `Items`
- `Explanation`

Generates one card. `Items` is a JSON array in canonical correct order, with stable item IDs. Presentation order can be shuffled independently of the stored answer order.

### Image Occlusion

Fields:

- `Image`
- `Masks`
- `Extra`

`Image` is a `deez-media://sha256:<hash>` reference. `Masks` is JSON containing normalized rectangles, stable positive mask IDs, answers, and optional per-mask prompts.

Each mask generates one card with identity:

```text
note:<note-id>:occlusion:<mask-id>
```

Reordering masks does not change card identities, so review history stays attached to the same semantic mask.

See `docs/interactions.md` for exact JSON schemas and CLI examples for these four interactive note types.

## Listing and editing notes

```bash
deez notes <deck-id>
deez note edit <deck-id> <note-id> <fields...>
```

`deez notes` lists logical notes rather than duplicating one row for every reverse/cloze/image-occlusion card. Legacy v0.1.x question/answer cards are shown as `legacy-basic` without mutating them merely to list content.

Editing a note regenerates content using stable generation keys. An unchanged generation identity keeps the same card ID, so its immutable review history remains attached even when field text changes.

Deez does not delete reviewed cards merely because a generated identity becomes temporarily absent. Destructive card deletion currently removes review history in storage, so generated-card retirement needs an explicit non-destructive card-state/tombstone model rather than using deletion as a shortcut.

## Shareable JSON v2

Exports represent logical notes instead of flattened generated cards:

```json
{
  "format": "deez.deck",
  "version": 2,
  "deck": {
    "name": "Geography",
    "notes": [
      {
        "note_type": "basic-reverse",
        "fields": ["France", "Paris"],
        "tags_json": "[]"
      }
    ]
  }
}
```

This prevents a reverse note from becoming two unrelated Basic cards after sharing it. Structured interactive fields are preserved as note fields as well.

Version 1 JSON deck files remain importable.

## `.nut` v2

`.nut` remains NDJSON, but v2 stores one logical note per record:

```text
{"kind":"deck","format":"deez.nut","version":2,"name":"Geography"}
{"kind":"note","note_type":"basic-reverse","fields":["France","Paris"],"tags_json":"[]"}
```

Version 1 `.nut` files containing `kind:"card"` records remain importable.

Both JSON and `.nut` are still **content-only**. They intentionally exclude review history, due dates, stability, difficulty, scheduler cache, and parameter-set identity. Use Deez backup/restore for full personal-data migration.
