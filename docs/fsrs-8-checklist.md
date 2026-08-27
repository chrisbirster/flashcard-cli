# FSRS-8 implementation checklist

FSRS-8 is not implemented until an authoritative FSRS-8 specification and/or reference implementation is published. Deez must not infer equations, parameter meanings, defaults, or migration rules from FSRS-7.

When FSRS-8 is published, use the upstream Open Spaced Repetition project/reference implementation as the source of truth and complete every applicable item below.

## Model and parameters

- [ ] Record the authoritative FSRS-8 specification/reference commit used for the port.
- [ ] Add `src/fsrs/v8/` as a new module; do not replace `src/fsrs/v7/`.
- [ ] Implement the exact FSRS-8 parameter count, meanings, defaults, and valid ranges.
- [ ] Implement the FSRS-8 forgetting/retrievability model.
- [ ] Implement initial difficulty and stability.
- [ ] Implement subsequent difficulty and stability updates.
- [ ] Implement same-day/short-term behavior exactly as specified.
- [ ] Implement interval calculation, desired retention, and interval constraints.

## Compatibility

- [ ] Add upstream/reference scalar test vectors for every equation.
- [ ] Add multi-review replay fixtures.
- [ ] Verify fractional-time behavior and numerical tolerances.
- [ ] Record implementation version separately from `fsrs/8`.
- [ ] Store FSRS-8 parameter sets with `algorithm = fsrs/8`; never reinterpret FSRS-7 parameter arrays.

## Full feature envelope

- [ ] Add FSRS-8 optimization from review history.
- [ ] Add any FSRS-8 recency/training options supported upstream.
- [ ] Add evaluation/calibration metrics.
- [ ] Add simulation/workload support.
- [ ] Add optimal-retention analysis when supported by the reference implementation.
- [ ] Add import/reconstruction behavior for historical review logs.

## Coexistence and migration

- [ ] Register FSRS-8 alongside FSRS-7; both must work in one build and one database.
- [ ] Prove two decks can be pinned to FSRS-7 and FSRS-8 concurrently.
- [ ] Add side-effect-free FSRS-7 vs FSRS-8 comparison.
- [ ] Migration must replay immutable review history through FSRS-8 rather than translate FSRS-7 stability/difficulty directly unless upstream publishes an explicit conversion.
- [ ] Add a dry-run migration report before activation.
- [ ] Never rewrite historical review events during migration.
- [ ] Preserve the old scheduler/parameter metadata needed for audit and rollback planning.

## Definition of done

FSRS-8 becomes `supported` in Deez only after the scheduler, optimizer, evaluator, simulator/retention features, replay, persistence, comparison, migration, and upstream compatibility tests all pass. Until then, `fsrs/8` must return `UnsupportedAlgorithm` rather than silently falling back to FSRS-7.
