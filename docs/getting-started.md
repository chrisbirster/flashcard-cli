# Getting started with Plandalf

Plandalf is a terminal-first spaced-repetition app. It stores your local data in SQLite and schedules reviews with FSRS-7.

## The model

```text
Deck
  -> Notes
      -> generated Cards
          -> Reviews
```

A **deck** groups material. A **note** is the source content you create. A note can generate one or more **cards**. A **review** is an immutable rating event recorded while studying.

## First run

Build Plandalf:

```bash
zig build
./zig-out/bin/plandalf --help
```

The first storage-backed command creates the SQLite database at:

```text
~/.local/share/plandalf/plandalf.db
```

To use another database path:

```bash
export PLANDALF_DB=/path/to/plandalf.db
```

You can inspect the resolved path with:

```bash
plandalf setup
```

## Create a deck

```bash
plandalf deck add "Data Structures"
plandalf decks
```

The list prints the deck ID used by later commands.

## Add notes

A basic note generates one card:

```bash
plandalf note add 1 basic \
  "What is a stack?" \
  "A LIFO data structure."
```

A reverse note generates both directions:

```bash
plandalf note add 1 reverse \
  "LIFO" \
  "Last in, first out"
```

Other built-in note types include `optional-reverse`, `cloze`, and `type-answer`. See `docs/card-types.md` for the supported field shapes.

List the generated cards:

```bash
plandalf cards 1
```

## Study

```bash
plandalf study 1
```

During study, Plandalf reveals the answer and asks for one of the FSRS ratings:

```text
1 Again
2 Hard
3 Good
4 Easy
```

Review events are append-only. Current scheduler state is derived from that history.

Useful study controls include:

```bash
plandalf study 1 --new-limit 20
plandalf study 1 --order reviews-first
plandalf study 1 --order new-first --shuffle
```

## Inspect progress

```bash
plandalf stats
plandalf stats 1
plandalf inspect <card-id>
plandalf scheduler list
```

Machine-readable output is available where documented, for example:

```bash
plandalf stats --json
plandalf inspect <card-id> --json
```

## Share a deck

Plandalf's shareable deck format is `.deck`:

```bash
plandalf deck export 1 > data-structures.deck
plandalf deck import data-structures.deck
```

The current emitted format is `plandalf.deck` version 2 NDJSON. It contains logical notes and rebuilds generated cards on import. It intentionally does **not** include your review history or scheduler state.

See `docs/deck-format.md` for the format contract.

## Local web UI/API

Plandalf can expose its local web/API surface on loopback:

```bash
plandalf web
```

Use `--no-open` when you do not want Plandalf to launch the default browser:

```bash
plandalf web --no-open
```

The server binds to `127.0.0.1` and applies local Host/Origin checks.

## Next commands to learn

```text
plandalf help deck
plandalf help note
plandalf help card
plandalf help study
plandalf help stats
plandalf help fsrs
```

The CLI itself is the authoritative command surface; if documentation and `plandalf --help` disagree, treat that as a documentation bug.
