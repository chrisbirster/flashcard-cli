# Plandalf CLI

Plandalf is a terminal-first spaced-repetition application using SQLite and FSRS-7.

## Storage

There is no backend-selection prompt. The first storage-backed command creates the SQLite database automatically at:

```text
~/.local/share/plandalf/plandalf.db
```

Override the path with:

```bash
export PLANDALF_DB=/path/to/plandalf.db
```

`plandalf setup` prints the resolved SQLite database path.

Help output does not require or initialize a database.

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Command completed successfully, including help output. |
| `2` | CLI usage error such as an unknown command, invalid arguments, invalid IDs/numbers, or a missing required `--yes` confirmation. |
| nonzero other than `2` | Runtime, storage, or scheduler failure propagated by the executable. |

Examples:

```sh
plandalf --help
printf '%s\n' "$?"   # 0

plandalf wat
printf '%s\n' "$?"   # 2
```

## Decks, notes, and cards

```text
plandalf decks
plandalf cards <deck-id>
plandalf deck add <name>
plandalf deck rename <deck-id> <name>
plandalf deck delete <deck-id> --yes
plandalf deck export <deck-id> > deck.deck
plandalf deck import <deck.deck>
plandalf add [deck-id]
plandalf edit [deck-id] [note-id]
plandalf note add [deck-id]
plandalf note edit [deck-id] [note-id]
plandalf note add <deck-id> <note-type> <fields...>
plandalf note edit <deck-id> <note-id> <fields...>
plandalf card add <deck-id> <question> <answer>
plandalf card edit <card-id> <question> <answer>
plandalf card delete <card-id> --yes
```

`plandalf add` and `plandalf edit` are the human-facing interactive flows. Guided editing shows the current values, lets Enter keep an existing value, previews the regenerated cards, and asks for confirmation before saving. Supplying all note fields keeps the deterministic non-interactive form for scripts.

A deck is the top-level content container. Cards belong to exactly one deck. Destructive operations require explicit `--yes` intent.

## `.deck` interchange

`.deck` is Plandalf's only public shareable deck format. It is UTF-8 NDJSON: one JSON object per non-empty line.

A version 2 file begins with:

```json
{"kind":"deck","format":"plandalf.deck","version":2,"name":"Zig Basics"}
```

and then contains logical note records, for example:

```json
{"kind":"note","note_type":"basic","fields":["What is Zig?","A systems programming language"],"tags_json":"[]"}
```

Export and import with:

```bash
plandalf deck export 1 > zig-basics.deck
plandalf deck import zig-basics.deck
```

`.deck` files intentionally exclude personal review history, scheduler state, due dates, difficulty, stability, and parameter-set identity. Generated cards are rebuilt from their logical notes when imported.

See `docs/deck-format.md` for the format contract.

## Study

```text
plandalf study <deck-id> [--new-limit <count>] [--order due|reviews-first|new-first] [--shuffle]
```

The default is deterministic due-timestamp order with no explicit new-card limit and no shuffle. Relearning cards can re-enter the same session when their scheduler timestamp becomes due.

## Stats and inspection

```text
plandalf stats [deck-id] [--json]
plandalf inspect <card-id> [--json]
plandalf scheduler list
```

`--json` is the machine-readable form for stats and card inspection.

## FSRS

```text
plandalf fsrs optimize [deck-id] [--recency]
plandalf fsrs evaluate [deck-id]
plandalf fsrs simulate [--retention <0..1>]
plandalf fsrs retention
```

`--recency` uses recency weighting when optimizing FSRS parameters. See `docs/optimizer.md` for optimizer details.

## Media

```text
plandalf media add <path>
```

The command stores media content by SHA-256 and prints its stable reference.

## Local web app

```text
plandalf web [--port <port>] [--web-root <path>] [--no-open]
```

The web listener binds to `127.0.0.1` only. `PLANDALF_WEB_ROOT` can override packaged web assets.

## Help

```text
plandalf --help
plandalf help
plandalf help deck
plandalf help note
plandalf help card
plandalf help study
plandalf help stats
plandalf help inspect
plandalf help fsrs
plandalf help scheduler
```

The declarative command tree and parser live in `src/cli_tree.zig` and use Thrawn for command resolution, options, and argument validation. Storage and scheduling behavior remain behind Plandalf domain APIs rather than in the CLI framework.
