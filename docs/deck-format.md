# Plandalf `.deck` format

Plandalf uses `.deck` as its single shareable deck format.

The format is UTF-8 newline-delimited JSON (NDJSON). Each non-empty line is one JSON object.

## Header

The first record is the deck header:

```json
{"kind":"deck","format":"plandalf.deck","version":2,"name":"Example Deck"}
```

Fields:

- `kind` must be `deck`.
- `format` must be `plandalf.deck`.
- `version` is the format version. Plandalf currently writes version 2.
- `name` is the deck name.

## Notes

Version 2 stores logical notes rather than generated cards. A basic note looks like:

```json
{"kind":"note","note_type":"basic","fields":["Question","Answer"],"tags_json":"[]"}
```

A cloze note can look like:

```json
{"kind":"note","note_type":"cloze","fields":["Paris is the capital of {{c1::France}}.","Europe"],"tags_json":"[]"}
```

Generated cards are rebuilt from note type semantics during import.

## What a `.deck` file contains

A `.deck` file is intentionally content-only. It contains the deck name and logical note content needed to recreate its cards.

It does not contain personal review history, scheduler state, due dates, learned FSRS parameters, or other study progress.

## CLI

Export a deck:

```bash
plandalf deck export 1 > french.deck
```

Import a deck:

```bash
plandalf deck import french.deck
```

Plandalf intentionally exposes no alternate deck-package extensions. `.deck` is the public interchange format.
