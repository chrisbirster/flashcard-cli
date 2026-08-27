# Deez v0.1.0 release gate

Do not create the first Deez release tag until every required item below is checked on the final release commit.

## Scheduler correctness

- [ ] `zig build test` passes on Zig 0.16.0.
- [ ] FSRS-7 parity fixtures pass against the pinned reference vectors.
- [ ] FSRS-7 optimizer objective and positional recency-weighting tests pass.
- [ ] Time-series evaluation tests pass without future leakage.
- [ ] Simulation, forecast, and retention regression tests pass.
- [ ] Multi-engine fixture tests pass while the production registry exposes only published engines.
- [ ] Property/fuzz smoke tests pass with no panic, NaN, infinity, negative interval, or invalid transition regression.

## MongoDB / Bongo

- [ ] Deez uses Bongo v0.4.0 at commit `8184b6266bab78fd3eb7fd8d2318f79f90e51937` with the pinned package hash.
- [ ] Live replica-set integration suite passes.
- [ ] Standalone fallback integration suite passes.
- [ ] TLS/authentication/error propagation coverage passes.
- [ ] Transactional review append/state update passes.
- [ ] Reconnect persistence passes.
- [ ] Scheduler pinning and immutable parameter-set tests pass.
- [ ] Global/group/deck parameter precedence passes.
- [ ] Logical archive dry-run/restore passes.
- [ ] Recovery rebuild preserves immutable review history.
- [ ] Anki-to-Store migration is validated with MongoDB as destination.
- [ ] Required MongoDB indexes are verified independently.

## Data safety

- [ ] Existing deck scheduler majors do not silently change.
- [ ] Unsupported engines fail explicitly.
- [ ] Parameter activation is explicit and previous parameter sets remain available.
- [ ] Scheduler migration preview is side-effect free.
- [ ] Failed migrations/restores leave source history unchanged.
- [ ] Backup/restore and recovery documentation matches tested behavior.

## Performance

- [ ] `zig build benchmark -Doptimize=ReleaseFast` completes successfully.
- [ ] Scheduling benchmark recorded.
- [ ] Long-history replay benchmark recorded.
- [ ] Mongo due-queue benchmark recorded.
- [ ] Optimization benchmark recorded.
- [ ] Representative archive/import benchmark recorded.
- [ ] Baseline hardware, dataset size, Zig mode, Mongo version, and Bongo version are recorded.
- [ ] Five measured runs after warm-up are recorded and medians calculated.
- [ ] No comparable-hardware median exceeds 2.0× the previous accepted baseline without an explicit explanation in release notes.

## User experience

- [ ] README installation/build instructions work from a clean checkout.
- [ ] MongoDB environment examples work.
- [ ] First deck/card/study workflow works.
- [ ] `deez fsrs optimize --recency` matches current positional recency behavior.
- [ ] Help output matches supported CLI syntax.
- [ ] Stats/inspect human and JSON output work.
- [ ] Backup/recovery/migration docs are discoverable.

## Required final commands

Run from the exact release commit:

```bash
zig fmt --check build.zig src test
zig build
zig build test
zig build benchmark -Doptimize=ReleaseFast
zig build mongo-integration-test
```

The Mongo integration command requires the documented Mongo fixtures/CI environment. The GitHub checks for the exact commit must also be green.

## Compatibility notes for release notes

Release notes must state:

- Deez version: v0.1.0;
- supported Zig version: 0.16.0;
- supported scheduler major(s): FSRS-7;
- MongoDB driver: Bongo v0.4.0 at the pinned commit/hash;
- MongoDB is the primary production validation backend;
- review history is immutable source of truth;
- existing deck scheduler major is pinned and never silently migrated;
- FSRS-8 is not claimed until a published implementation passes the full engine definition of done.

## Tagging

Only after this checklist is satisfied:

1. merge the release PR;
2. verify the exact merge commit with the final validation commands;
3. create tag `v0.1.0` on that commit;
4. publish the prepared release notes with the compatibility guarantees above.
