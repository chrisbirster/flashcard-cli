# Performance benchmarks

Deez ships a deterministic workload harness. Shared-runner wall-clock time is noisy, so CI treats the benchmark as a functional smoke gate while release baselines are recorded on comparable hardware.

## Run CPU workloads

Use a release-optimized build when recording a baseline:

```bash
zig build benchmark -Doptimize=ReleaseFast
```

The harness reports nanoseconds for:

- scheduling 100 times against a 1,000-review history;
- replaying a 1,000-review history 100 times;
- one optimizer epoch over 79 scoreable reviews;
- dry-running a 1,000-card interchange archive 100 times.

CI runs one warm-up plus five measured ReleaseFast runs and prints the median for each CPU workload.

## Run MongoDB/Bongo workload

Use a dedicated disposable MongoDB database and set:

```bash
export DEEZ_MONGO_BENCH_URI='mongodb://localhost:27017/deez_benchmark'
zig build benchmark -Doptimize=ReleaseFast
```

The Mongo workload creates 1,000 cards and measures 25 deterministic due-queue reads through the same `storage.Store` → `MongoStore` → Bongo v0.4.0 path used by Deez.

The live Mongo workflow runs one warm-up plus five measured ReleaseFast runs and prints the median Mongo due-queue result. Do not point the benchmark at a real Deez study database.

## v0.1.0 ReleaseFast baseline

Recorded on August 21, 2026 from PR #67 source head `28daba0314bcec4f118b65350152c565ea1a82a4`. Each number below is the median of five measured runs after one warm-up run.

### CPU workloads

GitHub Actions hosted runner context:

```text
OS: Ubuntu 24.04.4 LTS, x86_64, Azure hosted runner
CPU: 4 vCPU, AMD EPYC 7763 64-Core Processor
Memory: 15 GiB
Zig: 0.16.0
Optimization: ReleaseFast

schedule_100_long_history_ns=57528978
replay_100x_1000_reviews_ns=55579659
optimize_79_examples_1_epoch_ns=5078080
archive_dry_run_100x_1000_cards_ns=23535981
```

### MongoDB/Bongo workload

The Mongo baseline ran on a separate GitHub-hosted runner, so compare this value only with equivalent Mongo runner/server context:

```text
OS: Ubuntu 24.04.4 LTS, x86_64, Azure hosted runner
CPU: 4 vCPU, AMD EPYC 9V74 80-Core Processor
Memory: 15 GiB
Zig: 0.16.0
Optimization: ReleaseFast
MongoDB: 8.2.12
Bongo: 0.4.0
Bongo commit: 8184b6266bab78fd3eb7fd8d2318f79f90e51937

mongo_due_queue_25x_1000_cards_ns=91542532
```

That Mongo median is about 3.66 ms per 1,000-card due-queue read over the measured 25-query workload. Hosted-runner results are reference baselines, not universal latency guarantees.

## Baseline record template

For every future release baseline record:

```text
Deez commit:
Zig version:
Optimization mode:
OS:
CPU:
Memory:
MongoDB version:
Bongo version:
Bongo commit:

schedule_100_long_history_ns=
replay_100x_1000_reviews_ns=
optimize_79_examples_1_epoch_ns=
archive_dry_run_100x_1000_cards_ns=
mongo_due_queue_25x_1000_cards_ns=
```

Run each baseline at least five times after one warm-up run and record the median for each workload.

## Regression thresholds

Correctness regressions always fail release validation. Performance thresholds are intentionally split into two tiers:

1. **CI functional threshold:** every deterministic benchmark workload must complete successfully with the expected dataset/result counts. Any error, panic, invalid numeric result, wrong due-card count, or failed archive parse is a hard failure.
2. **Comparable-hardware release threshold:** if the median of a workload is more than **2.0×** the previous baseline on comparable hardware and software, the release is blocked until the regression is explained, fixed, or explicitly accepted in release notes.

A 2× wall-clock rule is deliberately broad enough to avoid treating ordinary machine noise as a regression while still catching accidental algorithmic or query-plan blowups. Once repeated release baselines establish a tighter stable variance band, this threshold can be reduced per workload.

Mongo due-queue performance should be reviewed first because MongoDB/Bongo is the primary production persistence path. Performance changes must never weaken deterministic ordering, immutable-history guarantees, scheduler parity, or transaction/recovery behavior.
