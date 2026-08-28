# Contributing to Plandalf

Plandalf is a terminal-first spaced-repetition application written in Zig 0.16. Its core invariants are intentionally small and strict.

## Core invariants

1. **Review history is immutable and authoritative.** Scheduler state is derived and may be rebuilt; historical reviews are not rewritten to fit an implementation.
2. **SQLite is the storage backend.** Do not add backend-selection abstractions or network database dependencies to the core application.
3. **FSRS engines are versioned.** Existing decks must not silently change scheduler major versions.
4. **`.deck` is the shareable deck format.** Keep `plandalf.deck` compatibility explicit and tested.
5. **The CLI is Plandalf-specific; Thrawn is generic.** Domain behavior belongs here, not in Thrawn.

## Architecture

- `src/fsrs/` — scheduler interfaces, versioning, comparison, migration, and FSRS-7 implementation
- `src/storage/` — SQLite persistence, reports, content metadata, and low-level SQLite backup helpers
- `src/study.zig` — study/replay/session orchestration
- `src/deck_file.zig` — native `.deck` NDJSON import/export
- `src/import/` — external importers such as Anki
- `src/cli_tree.zig` — declarative Thrawn command tree and option validation
- `src/cli.zig` — domain command union and help text
- `src/app.zig` — execution of parsed commands
- `src/web*.zig` — loopback-only local web/API surface

The application database defaults to:

```text
~/.local/share/plandalf/plandalf.db
```

Use `PLANDALF_DB` to override that path.

## Storage changes

Keep storage APIs operation-oriented. The application has one backend, so do not introduce a fake generic query layer or a second persistence implementation.

Changes that affect durable data should preserve:

- immutable reviews;
- scheduler and parameter-set identity;
- note/card relationships;
- stable card IDs where the operation promises stability;
- migration safety for existing SQLite databases.

## FSRS parity

Changes to FSRS equations, defaults, intervals, optimizer loss, evaluator behavior, simulation, or retention methodology require an authoritative upstream reference and regression fixtures.

Do not copy stability/difficulty directly across scheduler major versions. Reconstruct target state by replaying immutable history under the target engine.

A future scheduler major should be additive and must coexist with FSRS-7 until an explicit migration is performed.

## `.deck` compatibility

`.deck` is UTF-8 NDJSON. Version 2 stores a deck header followed by logical notes; generated cards are rebuilt on import. Review history and scheduler state are intentionally excluded from the shareable deck file.

When changing the format:

- preserve explicit version handling;
- keep malformed input from leaving partial decks behind;
- add round-trip tests;
- document compatibility in `docs/deck-format.md`.

## Tests

Before submitting changes:

```bash
zig fmt --check build.zig src test
zig build
zig build test
zig build benchmark -Doptimize=ReleaseFast
```

CI additionally exercises the local web/API smoke tests and native macOS release builds.

For fuzz-sensitive changes:

```bash
zig build test --fuzz
```

## Pull requests

Keep changes focused and preserve the invariants above. If a change alters a durable format, scheduler contract, CLI behavior, or API response shape, call that out explicitly in the PR description and include a compatibility test.
