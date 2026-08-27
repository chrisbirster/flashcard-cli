# Deez CLI

Deez is terminal-first. Command parsing is separate from storage/scheduler behavior so the same domain rules apply to SQLite and MongoDB.

## Storage setup

The first storage-backed command prompts for a backend when no saved configuration or explicit environment override exists:

```text
Deez storage [sqlite/mongodb] (sqlite):
```

An empty response selects SQLite and creates the database at:

```text
~/.local/share/deez/deez.db
```

The selected backend is persisted in `~/.config/deez/config`. Re-run the setup prompt at any time with:

```text
deez setup
```

Environment variables override saved configuration:

```bash
export DEEZ_STORAGE=sqlite
export DEEZ_DB="$HOME/.local/share/deez/deez.db"
```

or:

```bash
export DEEZ_STORAGE=mongodb
export DEEZ_MONGO_URI='mongodb://localhost:27017/deez'
```

Help output does not require or initialize a database.

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Command completed successfully, including help output. |
| `2` | CLI usage error such as an unknown command, invalid arguments, invalid IDs/numbers, or a missing required `--yes` confirmation. |
| nonzero other than `2` | Runtime/storage/scheduler failure propagated by the executable. |

Examples:

```sh
deez --help
printf '%s\n' "$?"   # 0

deez wat
printf '%s\n' "$?"   # 2
```

## Deck and card commands

```text
deez decks
deez nuts
deez cards <deck-id>
deez deck add <name>
deez deck rename <deck-id> <name>
deez deck delete <deck-id> --yes
deez deck export <deck-id> > deck.json
deez deck import <deck.json|deck.nut>
deez nut export <deck-id> > deck.nut
deez nut import <deck.nut>
deez card add <deck-id> <question> <answer>
deez card edit <card-id> <question> <answer>
deez card delete <card-id> --yes
```

A deck is the top-level content container. Cards belong to exactly one deck. `deez nuts` is intentionally an alias of `deez decks`; it does not introduce a second persisted entity. Destructive operations require explicit `--yes` intent.

### Shareable JSON decks

`deck export` writes a portable content-only JSON document:

```json
{
  "format": "deez.deck",
  "version": 1,
  "deck": {
    "name": "Zig Basics",
    "cards": [
      {
        "question": "What is Zig?",
        "answer": "A systems programming language"
      }
    ]
  }
}
```

Example round trip:

```bash
deez deck export 1 > zig-basics.json
deez deck import zig-basics.json
```

Import creates a new deck and new cards in the currently configured backend. The same JSON file can therefore be loaded into SQLite or MongoDB without changing the file.

### Native `.nut` decks

`.nut` is Deez's native shareable deck format. It is NDJSON: one complete JSON object per non-empty line.

```text
{"kind":"deck","format":"deez.nut","version":1,"name":"Zig Basics"}
{"kind":"card","question":"What is Zig?","answer":"A systems programming language"}
{"kind":"card","question":"What is comptime?","answer":"Compile-time execution"}
```

Export and import with:

```bash
deez nut export 1 > zig-basics.nut
deez nut import zig-basics.nut
```

The general deck importer also recognizes `.nut` by extension:

```bash
deez deck import zig-basics.nut
```

JSON deck files and `.nut` files intentionally exclude personal review history, scheduler state, due dates, difficulty, stability, and parameter-set identity. A downloaded deck starts fresh for its importer. Use backup/restore for full-fidelity personal data migration.

See `docs/nut-format.md` for the `.nut` versioning and validation rules.

## Study

```text
deez study <deck-id> [--new-limit <count>] [--order due|reviews-first|new-first] [--shuffle]
```

The default is deterministic due-timestamp order with no explicit new-card limit and no shuffle. Relearning cards can re-enter the same session when their scheduler timestamp becomes due.

## Stats and inspection

```text
deez stats [deck-id] [--json]
deez inspect <card-id> [--json]
deez scheduler list
```

`--json` is the stable machine-readable form for stats and card inspection.

## Backup and restore

The existing logical archive is separate from shareable JSON and `.nut` decks. It is intended to preserve a user's complete study data and scheduler metadata.

MongoDB backups are pipe-friendly:

```bash
export DEEZ_STORAGE=mongodb
export DEEZ_MONGO_URI='mongodb://localhost:27017/deez'

deez backup > deez.backup
deez backup 42 > deck-42.backup

deez restore --dry-run < deez.backup
deez restore --yes < deez.backup
```

`backup` without a deck ID exports all Deez data. Supplying a deck ID exports that deck and its cards/reviews together with the scheduler metadata required to interpret them.

`restore --dry-run` validates and reports archive counts without connecting to MongoDB or mutating persistent data. Actual restore requires `--yes`, requires the MongoDB backend, and refuses a non-empty destination rather than silently merging or overwriting existing Deez data. Source-of-truth records are restored transactionally on a replica set and derived scheduler state is rebuilt from immutable review history after the transaction commits.

Archive input is limited to 256 MiB per invocation so malformed or accidentally redirected unbounded input cannot consume arbitrary memory.

## FSRS

```text
deez fsrs optimize [deck-id] [--recency]
deez fsrs evaluate [deck-id]
deez fsrs simulate [--retention <0..1>]
deez fsrs retention
```

`--recency` is opt-in and uses the documented current FSRS benchmark positional weighting. It is not a time half-life flag. See `docs/optimizer.md`.

## Help

```text
deez --help
deez help
deez help deck
deez help nut
deez help card
deez help study
deez help stats
deez help inspect
deez help fsrs
deez help scheduler
deez backup --help
deez restore --help
```

The declarative command tree and parser live in `src/thrawn_cli.zig` and use Thrawn for command resolution, options, and argument validation. `src/cli.zig` retains the Deez domain command union and stable help contract consumed by `src/app.zig`. Backup/restore keeps its dedicated streaming executor because archives flow through stdin/stdout, while Thrawn validates and routes those commands before execution. Storage and scheduling behavior remain behind Deez domain APIs rather than in the CLI framework.
