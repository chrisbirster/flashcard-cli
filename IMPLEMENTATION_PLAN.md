# Deez Implementation Plan

**DEEZ — Drill, Evaluate, Encode, Zen**

Deez is a terminal-first flashcard and spaced-repetition system written in Zig. The scheduler architecture is intentionally versioned so that multiple FSRS generations can coexist. FSRS-7 is the first supported engine; future versions such as FSRS-8 should be added as new engines rather than replacing historical behavior.

## Architectural principles

1. **Review history is the source of truth.** Ratings and timestamps are stored independently of any FSRS version.
2. **Schedulers are versioned engines.** A deck can remain pinned to FSRS-7 while another uses a future FSRS-8.
3. **No silent scheduler migration.** Upgrading Deez must not automatically change an existing deck's FSRS major version.
4. **Parameter sets are versioned.** Parameters must carry their algorithm/version identity and cannot be treated as an untyped array.
5. **Implementation versions are recorded.** Reviews should retain the FSRS major version, Deez scheduler implementation version, and parameter-set identity needed for reproducibility.
6. **Upstream parity is tested.** FSRS equations and scheduling behavior should be validated against upstream/reference test vectors.
7. **The CLI depends on a scheduler interface, not FSRS-7 internals.** Adding FSRS-8 should primarily mean adding `src/fsrs/v8/` plus migration/compatibility code.

## Proposed layout

```text
src/
├── main.zig
├── card.zig
├── deck.zig
├── review.zig
├── storage/
│   ├── root.zig
│   └── sqlite.zig
└── fsrs/
    ├── root.zig
    ├── algorithm.zig
    ├── engine.zig
    ├── rating.zig
    ├── history.zig
    ├── parameters.zig
    └── v7/
        ├── root.zig
        ├── model.zig
        ├── scheduler.zig
        ├── parameters.zig
        ├── optimizer.zig
        ├── evaluator.zig
        ├── simulator.zig
        └── migration.zig
```

A future FSRS-8 implementation should be additive:

```text
src/fsrs/v8/
├── root.zig
├── model.zig
├── scheduler.zig
├── parameters.zig
├── optimizer.zig
├── evaluator.zig
├── simulator.zig
└── migration.zig
```

---

# Milestone 1 — Foundation and versioned scheduler architecture

**Goal:** Establish the Zig project and the version-independent data model before implementing FSRS equations.

### Deliverables

- Zig project builds and tests cleanly.
- Core `Rating`, `Review`, `Card`, `Deck`, `AlgorithmId`, and parameter identity types exist.
- Scheduler engine API is independent of FSRS-7.
- Review records can identify the algorithm, implementation version, and parameter set used.
- FSRS-7 is registered as an engine without leaking its internal state into general Deez types.

### Issues

- #1 Initialize the Zig project and test harness
- #2 Define version-independent card, review, and rating types
- #3 Define scheduler algorithm/version and parameter-set identities
- #4 Add the versioned scheduler engine abstraction
- #5 Define FSRS-7 module boundaries and public API

---

# Milestone 2 — FSRS-7 scheduling core

**Goal:** Implement the latest FSRS-7 scheduling model in native Zig with upstream-compatible behavior.

### Deliverables

- FSRS-7 parameter model.
- Memory state with stability and difficulty.
- Retrievability/forgetting curve.
- Initial and subsequent stability/difficulty calculations.
- Same-day/fractional-interval behavior.
- Again/Hard/Good/Easy next-state calculation.
- Desired-retention and maximum-interval configuration.
- Deterministic compatibility fixtures against upstream/reference behavior.

### Issues

- #6 Implement FSRS-7 parameters and configuration
- #7 Implement FSRS-7 retrievability and forgetting curve
- #8 Implement FSRS-7 difficulty updates
- #9 Implement FSRS-7 stability updates
- #10 Implement Again/Hard/Good/Easy scheduling and fractional intervals
- #11 Add upstream FSRS-7 compatibility fixtures and regression tests

---

# Milestone 3 — Durable history and scheduling state

**Goal:** Make review history durable and independent from the selected scheduler so future engines can reconstruct state.

### Deliverables

- SQLite storage.
- Immutable review log.
- Current scheduling state/cache.
- Versioned parameter-set storage.
- Deck-level scheduler pinning.
- Replay/rebuild scheduling state from review history.

### Issues

- #12 Design the SQLite schema and migrations
- #13 Persist cards, decks, and immutable review history
- #14 Persist versioned FSRS parameter sets and scheduler metadata
- #15 Implement review-history replay and state reconstruction
- #16 Implement deck-level scheduler pinning with no silent migrations

---

# Milestone 4 — FSRS-7 optimization and evaluation

**Goal:** Support the full personalization workflow instead of only using default FSRS parameters.

### Deliverables

- Parameter optimization from review history.
- Recency weighting.
- Global, preset/group, and per-deck parameter strategies.
- Model evaluation metrics.
- Comparison of default and optimized parameters.
- Safe parameter activation/history.

### Issues

- #17 Implement FSRS-7 parameter optimization
- #18 Add recency-weighted optimization
- #19 Add global, preset/group, and per-deck parameter strategies
- #20 Implement FSRS model evaluation and calibration metrics
- #21 Add parameter-set lifecycle, comparison, and activation

---

# Milestone 5 — Simulation, workload, and optimal retention

**Goal:** Expose the planning and analysis features that make a full FSRS implementation useful beyond basic scheduling.

### Deliverables

- Review simulation.
- Workload forecasts.
- Retention tradeoff analysis.
- Optimal-retention calculation.
- CLI/API-ready result structures.

### Issues

- #22 Implement FSRS simulation
- #23 Implement workload and review-volume forecasting
- #24 Implement retention tradeoff analysis and optimal retention

---

# Milestone 6 — Terminal study experience

**Goal:** Build the actual Deez CLI on top of the scheduler and storage layers.

### Deliverables

- `deez study <deck>`.
- Question → reveal → Again/Hard/Good/Easy loop.
- Due-card queue.
- Deck creation and card management.
- Deck/statistics commands.
- Scheduler inspection commands.

### Issues

- #25 Implement CLI command routing and help
- #26 Implement `deez study <deck>`
- #27 Implement deck and card management commands
- #28 Implement due queue and study-session rules
- #29 Implement `deez stats` and card/scheduler inspection

---

# Milestone 7 — Import, export, migration, and interoperability

**Goal:** Protect user data and make Deez interoperable with existing flashcard systems.

### Deliverables

- Stable Deez export format.
- Import/export of decks and review history.
- Anki/SM-2 migration path where practical.
- Backup/restore.
- Validation and dry-run migration modes.

### Issues

- #30 Define a stable Deez interchange/export format
- #31 Implement Deez import/export and backup/restore
- #32 Implement Anki/SM-2 review-history migration
- #33 Add migration validation and dry-run tooling

---

# Milestone 8 — Multi-version FSRS framework and future FSRS-8 support

**Goal:** Prove that FSRS major versions can coexist and that upgrading does not rewrite historical truth.

This milestone establishes the machinery now. The actual FSRS-8 equations cannot be implemented until FSRS-8 is published.

### Deliverables

- Multiple scheduler engines can be registered simultaneously.
- Decks can remain pinned to FSRS-7.
- A future FSRS-8 engine can derive state from the same review history.
- Scheduler comparison/benchmarking can run without switching the live deck.
- Migration is explicit, reversible where possible, and preserves original review history.

### Issues

- #34 Implement multi-engine scheduler registry and dispatch
- #35 Implement cross-version scheduler comparison
- #36 Implement explicit scheduler migration framework
- #37 Add FSRS-8 implementation placeholder/spec checklist

---

# Milestone 9 — Production hardening and first release

**Goal:** Make Deez trustworthy for daily use.

### Deliverables

- Database recovery and corruption handling.
- Fuzz/property tests around scheduler/storage boundaries.
- Performance benchmarks.
- CLI usability polish.
- Documentation.
- Tagged first release.

### Issues

- #38 Add scheduler property tests and fuzz coverage
- #39 Add database recovery, integrity checks, and failure tests
- #40 Add performance benchmarks and regression thresholds
- #41 Write user and contributor documentation
- #42 Prepare the first tagged Deez release

---

## Definition of done for an FSRS engine

An FSRS major version is considered supported only when all applicable items are complete:

- Scheduling equations implemented.
- Default parameters implemented.
- Configurable desired retention and interval constraints implemented.
- Same-day behavior implemented when part of the specification.
- Upstream compatibility fixtures pass.
- Review-history reconstruction works.
- Parameter optimization works.
- Evaluation works.
- Simulation/workload analysis works.
- Optimal-retention support works when applicable.
- Parameter sets are versioned and persisted.
- Migration into the engine is explicit and tested.
- The engine can coexist with other supported FSRS major versions.

## Versioning policy

Deez should distinguish three identities:

1. **Algorithm:** e.g. `fsrs/7`.
2. **Implementation:** the Deez FSRS implementation release/version.
3. **Parameter set:** immutable identifier/hash for the exact trained/default parameters.

A scheduler upgrade must never rewrite immutable review events. Derived state may be rebuilt from those events using a selected engine.

## Recommended implementation order

Start with Milestones 1–3 before spending time on the interactive CLI. The first architectural success criterion is the ability to record reviews independently, schedule them with FSRS-7, discard derived scheduling state, and deterministically reconstruct it from history. Once that works, the CLI becomes a consumer of a stable core rather than the place where scheduling logic lives.
