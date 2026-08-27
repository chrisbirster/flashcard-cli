# Performance benchmarks

Plandalf ships a deterministic workload harness. Shared-runner wall-clock time is noisy, so CI treats the benchmark as a functional smoke gate; release baselines should be recorded only on comparable hardware.

## Run benchmarks

Use a release-optimized build when recording a baseline:

```bash
zig build benchmark -Doptimize=ReleaseFast
```

The harness currently reports:

- `schedule_100_long_history_ns` — schedule 100 times against a 1,000-review history;
- `replay_100x_1000_reviews_ns` — replay a 1,000-review history 100 times;
- `optimize_79_examples_1_epoch_ns` — one deterministic optimizer epoch;
- `deck_import_10x_1000_cards_ns` — import and remove ten 1,000-card `plandalf.deck` v1 fixtures in an in-memory SQLite database.

The output begins with:

```text
plandalf benchmark format=1
```

## What the benchmark is for

The benchmark is primarily a regression signal for hot scheduler/replay paths and native `.deck` ingestion. It is not a universal latency guarantee.

CI runs:

```bash
zig build benchmark -Doptimize=ReleaseFast
```

as a smoke gate after the normal build and test suite. A benchmark process failure is a correctness failure; a timing change should be investigated against a comparable machine before being treated as a performance regression.

## Recording a release baseline

For a meaningful baseline, record:

```text
Plandalf commit:
Plandalf version:
Zig version:
OS:
CPU:
Memory:
Optimization: ReleaseFast
```

Then capture the complete benchmark output.

Run at least one warm-up and several measured runs on the same machine when comparing releases. Prefer the median rather than a single sample.

## Historical results

Old Deez/Mongo/Bongo benchmark numbers are historical measurements of removed code paths and are intentionally not part of the active Plandalf benchmark contract. Use repository history if those results are needed for archaeology.
