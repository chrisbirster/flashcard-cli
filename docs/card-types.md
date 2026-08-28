# Built-in note and card types

Plandalf stores **notes** as source content and derives study **cards** from a note type. Review history belongs to generated card identities, not to rendered front/back text.

The same content model is used by the terminal and local web/API interfaces.

## Built-in note types

### Basic

Fields:

- `Front`
- `Back`

Generates one card with stable identity `note:<note-id>:template:0`.

```bash
plandalf note add 1 basic "What is SQLite?" "An embedded SQL database"
```

### Basic + Reverse

Fields:

- `Front`
- `Back`

Generates two cards:

- forward: `note:<note-id>:template:0`
- reverse: `note:<note-id>:template:1`

```bash
plandalf note add 1 reverse "France" "Paris"
```

### Basic + Optional Reverse

Fields:

- `Front`
- `Back`
- `Add Reverse`

A non-empty third field requests the reverse generated card.

```bash
plandalf note add 1 optional-reverse "France" "Paris" "yes"
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

Generates one card. `Choices` is JSON containing stable choice IDs and display text; `Correct` is the stable choice ID rather than a letter or array position. A graphical client can randomize choices without changing the semantic answer.

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

Generates one card. `Items` is a JSON array in canonical correct order, with stable item IDs. Presentation order can be shuffled independently of stored answer order.

### Image Occlusion

Fields:

- `Image`
- `Masks`
- `Extra`

`Image` uses the established `deez-media://sha256:<hash>` content-addressed URI. That URI remains stable for stored-data compatibility and is independent from the Plandalf executable name.

`Masks` is JSON containing normalized rectangles, stable positive mask IDs, answers, and optional per-mask prompts. Each mask generates one card with identity:

```text
note:<note-id>:occlusion:<mask-id>
```

Reordering masks does not change card identities, so review history stays attached to the same semantic mask.

See `docs/interactions.md` for the exact structured-field schemas.

## Listing and editing notes

```bash
plandalf notes <deck-id>
plandalf note edit <deck-id> <note-id> <fields...>
```

`plandalf notes` lists logical notes rather than duplicating one row for every reverse, cloze, or image-occlusion card.

Editing a note regenerates content using stable generation keys. An unchanged generation identity keeps the same card ID, so its immutable review history remains attached even when field text changes.

Plandalf will not destructively delete a card that already has review history. Generated-card retirement is non-destructive so immutable reviews remain available for replay and recovery.

## `.deck` v2

Plandalf's shareable format represents logical notes rather than flattened generated cards. It is line-oriented NDJSON:

```text
{"kind":"deck","format":"plandalf.deck","version":2,"name":"Geography"}
{"kind":"note","note_type":"reverse","fields":["France","Paris"],"tags_json":"[]"}
```

This prevents a reverse note from becoming two unrelated Basic cards after sharing it. Structured interactive fields are preserved as note fields as well.

Version 1 `plandalf.deck` files containing `kind:"card"` records remain importable for compatibility. Version 2 is the emitted format.

`.deck` is **content-only**. It intentionally excludes review history, due dates, stability, difficulty, scheduler cache, and parameter-set identity.
