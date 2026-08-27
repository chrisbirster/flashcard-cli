# Deez v0.1.0 release notes

Deez v0.1.0 is the first release intended for real daily terminal study.

## Compatibility

- Zig: 0.16.0
- Scheduler: FSRS-7
- MongoDB driver: Bongo v0.4.0
- Bongo commit: `8184b6266bab78fd3eb7fd8d2318f79f90e51937`
- Primary production validation backend: MongoDB

FSRS-8 is not included. Deez will not claim FSRS-8 support until a published specification/reference implementation exists and passes the full multi-engine parity, replay, optimizer, evaluator, simulator, and migration requirements.

## Scheduler guarantees

Deez treats immutable review history as the source of truth. Stability, difficulty, due time, and related scheduler state are rebuildable derived data.

Existing decks remain pinned to their explicit scheduler major and parameter set. Upgrading Deez does not silently move a deck to another scheduler major. Unsupported engines fail explicitly.

FSRS-7 parity is regression-tested against pinned Open Spaced Repetition reference vectors. Parameter sets are immutable and retain version/source identity for reproducibility.

## Optimization and evaluation

FSRS-7 parameter optimization consumes immutable review history and exposes standard and opt-in recency-weighted fitting.

Recency mode uses the current positional benchmark weighting:

```text
x = linspace(0, 1, N)
weight = 0.25 + 0.75 * x^3
```

Use:

```bash
deez fsrs optimize --recency
```

Evaluation includes chronological splitting so future reviews are not leaked into earlier predictions.

## MongoDB data safety

Replica-set MongoDB review writes use Bongo transactions to append the immutable review and update derived scheduler state atomically.

On standalone MongoDB, Deez appends the immutable review first. If the derived-state write fails, recovery can reconstruct scheduler state by replaying preserved history.

The live integration suite exercises replica-set, standalone, TLS, reconnect persistence, scheduler pinning, immutable parameter sets, logical archive restore, and recovery against the pinned Bongo v0.4.0 package.

## Backup, restore, and migration

The MongoDB logical Deez archive preserves deck/card IDs, immutable reviews, scheduler stamps, parameter sets, scheduler defaults/pins, and counters.

Restore validates before mutation, requires a clean destination, uses transactions where available, and rebuilds scheduler cache from immutable history.

Anki migration reads Anki's SQLite collection as an input format but writes destination data through Deez `storage.Store`, allowing MongoDB to be the destination backend.

## Multi-engine framework

The scheduler registry supports multiple major versions. FSRS-7 is the only production FSRS major advertised by v0.1.0. A test-only fixture engine proves dispatch/comparison/migration abstractions are genuinely multi-engine without pretending to implement FSRS-8.

## Hardening

v0.1.0 includes deterministic property coverage, Zig fuzz entry points, recovery/replay tests, benchmark workloads, Mongo integration coverage, and a release checklist.

Performance release baselines use median measurements on comparable hardware. A median slowdown greater than 2.0× the prior accepted baseline requires investigation or explicit release-note acceptance; correctness remains a hard gate regardless of performance.
