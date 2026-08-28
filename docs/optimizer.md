# FSRS-7 optimization and evaluation

Plandalf trains FSRS-7 parameters from immutable review history. Scheduler state is not training input; it is derived from that history.

## Reference methodology

The implementation tracks the Open Spaced Repetition `srs-benchmark` FSRS-7 model and training objective used by the parity fixtures.

Current training defaults include:

- 35 FSRS-7 weights;
- 8 epochs;
- learning rate 0.02;
- Adam-style beta values 0.8 and 0.85;
- binary cross-entropy recall objective;
- FSRS-7 parameter bounds;
- the published FSRS-7 L2 prior/penalty values.

Plandalf computes deterministic finite-difference gradients rather than depending on PyTorch autograd. This changes how the gradient is obtained, not the BCE + L2 objective being optimized.

## Standard fitting

Standard fitting gives each scoreable review example weight 1.0.

```bash
./zig-out/bin/plandalf fsrs optimize
./zig-out/bin/plandalf fsrs optimize <deck-id>
```

A review is scoreable when it follows an earlier review for the same card. The previous history is replayed to derive the memory state used to predict recall for that review.

## Recency-weighted fitting

Recency weighting is opt-in:

```bash
./zig-out/bin/plandalf fsrs optimize --recency
./zig-out/bin/plandalf fsrs optimize <deck-id> --recency
```

It follows chronological positional weighting rather than an exponential time half-life.

For `N` scoreable training examples ordered from oldest to newest:

```text
x = linspace(0, 1, N)
weight = 0.25 + 0.75 * x^3
```

The oldest example has weight 0.25 and the newest has weight 1.0. Weighted BCE is divided by the number of examples, matching the benchmark objective.

The optimizer records whether recency weighting was used plus deterministic configuration needed to reproduce a run.

## Evaluation

Evaluation is separate from optimization. Metrics include log loss, Brier/RMSE-style error, predicted/observed recall, and calibration measurements.

Chronological time-series splits use expanding training history followed by later test history. Earlier reviews may be replayed to construct state for a test review, but future reviews are never used to construct an earlier prediction.

## Minimum history

Optimization rejects histories with fewer scoreable reviews than the configured minimum. Invalid or non-monotonic histories are errors rather than being silently reordered inside a card's history.

## Parameter activation

Optimization produces a new immutable parameter set. It does not silently replace a deck's active set. Activation is explicit, and prior parameter-set IDs remain available for comparison and reproducibility.
