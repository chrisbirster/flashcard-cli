# FSRS-7 optimization and evaluation

Deez trains FSRS-7 parameters from immutable review history. Scheduler state is not training input; it is derived from that history.

## Reference methodology

The implementation tracks the current Open Spaced Repetition `srs-benchmark` FSRS-7 model and training objective.

Current training defaults include:

- 35 FSRS-7 weights;
- 8 epochs;
- learning rate 0.02;
- Adam-style beta values 0.8 and 0.85;
- binary cross-entropy recall objective;
- FSRS-7 parameter bounds;
- the published FSRS-7 L2 prior/penalty values.

Deez computes deterministic finite-difference gradients rather than depending on PyTorch autograd. This changes how the gradient is obtained, not the BCE + L2 objective being optimized.

## Standard fitting

Standard fitting gives each scoreable review example weight 1.0.

```bash
./zig-out/bin/deez fsrs optimize
./zig-out/bin/deez fsrs optimize <deck-id>
```

A review is scoreable when it follows an earlier review for the same card. The previous history is replayed to derive the memory state used to predict recall for that review.

## Recency-weighted fitting

Recency weighting is opt-in. Enable it with:

```bash
./zig-out/bin/deez fsrs optimize --recency
./zig-out/bin/deez fsrs optimize <deck-id> --recency
```

It follows the benchmark's chronological positional weighting rather than an exponential time half-life.

For `N` scoreable training examples ordered from oldest to newest:

```text
x = linspace(0, 1, N)
weight = 0.25 + 0.75 * x^3
```

The oldest example has weight 0.25 and the newest has weight 1.0. Weighted BCE is divided by the number of examples, matching the benchmark objective.

The optimizer records whether recency weighting was used plus the deterministic seed/configuration needed to reproduce a run.

## Evaluation

Evaluation is separate from optimization. Metrics include:

- log loss;
- Brier score / RMSE;
- mean predicted recall;
- mean observed recall;
- calibration error and calibration bins.

Chronological time-series splits use the same expanding-train / next-test shape as a five-way `TimeSeriesSplit` by default. Earlier history may be replayed to construct state for a test review, but future reviews are never used to construct an earlier prediction.

## Minimum history

Optimization rejects histories with fewer scoreable reviews than the configured minimum. Invalid/non-monotonic histories are errors instead of being silently reordered inside a card's history.

## Parameter activation

Optimization produces a new immutable parameter set. It does not silently replace a deck's active set. Activation is explicit, and the prior parameter-set ID remains available for comparison, reproducibility, and rollback planning.
