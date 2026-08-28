# FSRS-7 parity source

Plandalf treats the Open Spaced Repetition `srs-benchmark` FSRS-7 model as the authoritative reference for the FSRS-7 equations and default parameter vector.

Pinned fixture source used by the current parity suite:

```text
repository: open-spaced-repetition/srs-benchmark
commit:     1053082bd2d6dbedbbd9674c4c9683c203f6818a
file:       models/fsrs_v7.py
```

The parity tests cover:

- all 35 default parameters;
- initial stability and difficulty for Again, Hard, Good, and Easy;
- the two-component forgetting curve at same-day and multi-day intervals;
- same-day memory-state transitions for all four ratings;
- normal-review memory-state transitions for all four ratings;
- mixed-history replay including a lapse and same-day review;
- four-way new-card scheduling intervals;
- four-way review scheduling after a mixed history.

Expected floating-point values are checked with explicit tolerances. When upstream FSRS-7 changes, do not silently edit expected values. First record the new upstream commit, review formula/default changes, update the implementation if necessary, regenerate vectors from that exact commit, and keep old behavior reproducible through scheduler and parameter metadata.

FSRS-8 must not be inferred from FSRS-7 changes. It gets a separate engine/version only after an authoritative FSRS-8 specification or reference implementation exists.
