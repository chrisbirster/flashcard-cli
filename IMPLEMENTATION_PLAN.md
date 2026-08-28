# Plandalf implementation plan

Plandalf is a terminal-first spaced-repetition application written in Zig 0.16. The current foundation is SQLite + immutable review history + versioned FSRS scheduling + a local loopback web/API surface.

## Architectural principles

1. **Review history is the source of truth.** Ratings and timestamps remain independent from derived scheduler state.
2. **Schedulers are versioned engines.** FSRS-7 is current; future majors are additive and require explicit migration.
3. **SQLite is the application datastore.** Plandalf intentionally avoids runtime database-backend selection.
4. **`.deck` is the portable content format.** `plandalf.deck` NDJSON carries logical deck content, not review history or scheduler cache.
5. **One domain core serves every interface.** Terminal and local web/API flows use the same storage, content, rendering, and study behavior.
6. **Local servers stay local.** Web/API listeners bind to loopback and validate local Host/Origin expectations.
7. **Generated state is disposable.** Scheduler state can be reconstructed from immutable reviews.

## Current layout

```text
src/
├── main.zig              # executable entrypoint
├── cli.zig               # domain command model/help
├── cli_tree.zig          # Thrawn command tree
├── app.zig               # CLI command execution
├── deck_file.zig         # plandalf.deck NDJSON
├── content.zig           # note/content model
├── card_types.zig        # built-in note/card generation
├── study.zig             # study sessions and review recording
├── recovery.zig          # rebuild derived scheduler state
├── web*.zig              # loopback web/API
├── import/               # external importers
├── storage/              # SQLite persistence
└── fsrs/
    └── v7/               # FSRS-7 model and tooling
```

## Completed foundation

- Zig 0.16 build and CI
- SQLite durable storage
- immutable review history
- FSRS-7 scheduling, replay, optimizer, evaluator, simulation, forecast, and retention tools
- versioned scheduler/parameter identities
- built-in note types and deterministic card generation
- Anki import support
- `.deck` v1 import compatibility and v2 logical-note export/import
- terminal study flow
- local loopback web/API flow
- Host/Origin checks on the web surface
- Linux test/build/benchmark smoke coverage
- native macOS release smoke coverage

## Near-term priorities

### 1. Harden the single-user local application

- keep all default data under the Plandalf data directory;
- document filesystem and network behavior;
- maintain strict loopback-only web/API behavior;
- expand malformed `.deck` and API-input regression coverage;
- keep destructive operations explicit.

### 2. Strengthen `.deck`

- keep v1 import compatibility while v2 remains the emitted format;
- add more round-trip fixtures for every built-in note type;
- add limits and adversarial fixtures for untrusted imports;
- document media-reference portability separately from deck JSON records.

### 3. Preserve scheduler reproducibility

- keep upstream FSRS-7 parity fixtures current;
- expand migration/replay tests before any future scheduler major is introduced;
- make scheduler/parameter provenance visible in diagnostics.

### 4. Improve the developer experience

- keep CLI help and docs generated from or checked against the real command surface where practical;
- keep CI fast enough to run on every PR;
- maintain deterministic benchmark workloads for scheduler and `.deck` operations.

### 5. Release hardening

Before a Plandalf release:

```bash
zig fmt --check build.zig src test
zig build
zig build test
zig build benchmark -Doptimize=ReleaseFast
```

The release pipeline should also exercise the installed `plandalf` binary on supported platforms and verify a clean first-run database plus `.deck` export/import round trip.

## Deliberate non-goals

The current architecture does not include:

- MongoDB/Bongo storage;
- runtime storage-backend selection;
- legacy `nut` or `sack` formats/commands;
- a public full-database archive format;
- an always-running daemon;
- automatic scheduler-major migration.

Those should not be reintroduced accidentally as compatibility layers. Any future expansion should start from a concrete Plandalf requirement and preserve the invariants above.
