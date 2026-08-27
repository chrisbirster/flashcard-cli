# Deez `.nut` deck format

`.nut` is the native human-readable shareable deck format for Deez.

It is **NDJSON** (newline-delimited JSON): every non-empty line is one complete JSON object. The `.nut` extension identifies the file as a Deez deck, but each record remains ordinary JSON so the format is easy to inspect, generate, diff, and stream.

## Version 2

The first non-empty record describes the deck:

```json
{"kind":"deck","format":"deez.nut","version":2,"name":"Zig Basics"}
```

Every following record is a **logical note**, not a generated study card:

```json
{"kind":"note","note_type":"basic","fields":["What is Zig?","A systems programming language"],"tags_json":"[]"}
{"kind":"note","note_type":"reverse","fields":["Capital of France","Paris"],"tags_json":"[]"}
{"kind":"note","note_type":"cloze","fields":["Paris is the capital of {{c1::France}}.","Europe"],"tags_json":"[]"}
```

Generated cards are rebuilt from the note type and templates during import. This keeps `.nut` files portable and prevents rendered card copies from becoming a second source of truth.

A complete file can therefore look like:

```text
{"kind":"deck","format":"deez.nut","version":2,"name":"Geography"}
{"kind":"note","note_type":"reverse","fields":["Capital of France","Paris"],"tags_json":"[]"}
{"kind":"note","note_type":"cloze","fields":["Paris is the capital of {{c1::France}}.","Europe"],"tags_json":"[]"}
```

Blank lines are ignored. Comments are not supported because every non-empty line must remain valid JSON.

## Built-in note types

Version 2 supports Deez's built-in logical note types:

- `basic`
- `basic-reverse` / `reverse`
- `optional-reverse`
- `cloze`
- `type-answer`
- `multiple-choice`
- `multiple-select`
- `ordering`
- `image-occlusion`

The number and meaning of `fields` are defined by the note type. The structured field schemas for multiple choice, multiple select, ordering, and image occlusion are documented in `docs/interactions.md`.

Interaction data remains ordinary field text in `.nut` v2. Structured values such as choices, correct IDs, ordered items, and image masks are encoded as JSON strings inside the `fields` array. This keeps the outer `.nut` record model stable while allowing future terminal, desktop, mobile, and web clients to render richer interactions.

## Media references

`.nut` remains text-only even when a deck uses images, audio, or video.

Media is referenced by stable content identity:

```text
deez-media://sha256:<64-character-lowercase-sha256>
```

For example, a field may contain:

```html
<img src="deez-media://sha256:0123456789abcdef...">
```

Image-occlusion notes use the same media reference as their `Image` field. The binary media is not embedded in the `.nut`. Use a `.sack` bundle when the deck and its referenced media need to travel together.

## Commands

List stored decks using the intentionally ridiculous alias:

```bash
deez nuts
```

Export one stored deck as `.nut`:

```bash
deez nut export 1 > zig-basics.nut
```

Import a `.nut` deck:

```bash
deez nut import zig-basics.nut
```

The general deck importer also recognizes the `.nut` extension:

```bash
deez deck import zig-basics.nut
```

For rich media:

```bash
deez media add diagram.png
deez sack export 1 zig-basics.sack
deez sack import zig-basics.sack
```

`deez nuts` and `deez decks` list the same persisted decks. A nut is not a second database entity; `.nut` is the portable file representation of a deck.

## Data-safety boundary

`.nut` files are intentionally **content-only**. They contain the deck name and logical notes, but not personal review history, due dates, stability, difficulty, scheduler cache, or FSRS parameter state.

This means a deck downloaded from someone else starts with fresh study history after import. Use Deez backup/restore when the goal is to migrate your own complete database and immutable review history.

## Compatibility

- `format` must be `deez.nut`.
- New exports use `version: 2`.
- Version 1 card-based files remain import-compatible.
- Version 2 accepts logical `note` records only after the deck header.
- The deck record must appear before note/card records.
- A file may contain exactly one deck record.
- Unknown record kinds are rejected rather than silently ignored.
- Empty deck names and invalid note fields are rejected.
- Structured interaction fields are validated during note generation/import rather than silently accepting malformed choices, IDs, ordering data, or masks.

The line-oriented layout leaves room for future record kinds without requiring one giant JSON document or loading the entire logical deck structure into memory at once.
