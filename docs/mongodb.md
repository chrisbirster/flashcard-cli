# MongoDB and Bongo

MongoDB is Deez's primary production validation backend. Deez talks to MongoDB through the pinned Bongo v0.4.0 package at commit `8184b6266bab78fd3eb7fd8d2318f79f90e51937`; application code does not depend on Bongo internals.

## Configuration

```bash
export DEEZ_STORAGE=mongodb
export DEEZ_MONGO_URI='mongodb://localhost:27017/deez'
```

A replica set is strongly preferred. Bongo exposes sessions and transactions when the selected server supports them.

## What is authoritative

The immutable review log is authoritative. A review records its rating, timestamp, scheduler major, Deez implementation version, exact parameter-set identity, and scheduled timestamp.

Card scheduler state is derived cache. It may contain stability, difficulty, due time, and last-review time, but it can be cleared and reconstructed from review history.

This distinction is deliberate: recovery and scheduler migration must never invent, discard, or rewrite historical reviews merely to repair cached state.

## Atomic review writes

On a MongoDB replica set, Deez uses a Bongo transaction to:

1. insert the immutable review document;
2. update the card's derived scheduler state;
3. commit both changes together.

On standalone MongoDB, multi-document transactions are unavailable. Deez therefore appends the review first. If the derived-state update fails, recovery replays the preserved review history.

## Scheduler pinning

Deck scheduler metadata is explicit. If a deck contains an unsupported scheduler major, Deez returns an error instead of silently falling back to FSRS-7. A new scheduler major must be registered and supported before it can be selected.

Parameter sets are immutable BSON documents identified by a deterministic 32-byte ID. Multiple parameter sets coexist, and older sets remain loadable after newer sets are added.

## Logical backup and restore

The terminal commands stream Deez's logical archive format through stdout/stdin:

```bash
# Full backup
deez backup > deez.backup

# One deck plus the scheduler metadata needed to interpret it
deez backup 42 > deck-42.backup

# Validation only; no MongoDB connection or writes
deez restore --dry-run < deez.backup

# Actual restore into a clean MongoDB destination
deez restore --yes < deez.backup
```

`interchange_mongodb` exports Deez's logical source-of-truth records. A dry run parses and validates the complete archive without mutating MongoDB.

Restore rules:

- destination must be empty;
- the archive is validated before writes;
- replica-set restore writes source-of-truth records in one transaction;
- IDs and counters are preserved;
- scheduler cache is rebuilt after commit;
- a failed transaction leaves the destination unchanged;
- an existing destination is never silently merged into;
- archive input is capped at 256 MiB per invocation.

The logical format is intended for Deez backup/migration, not as a general replacement for operational MongoDB backups.

## Recovery

If a card's derived state is missing or suspected stale, Deez recovery:

1. reads the immutable history;
2. clears/replaces only derived state;
3. replays history through the deck's pinned engine/parameter set;
4. verifies the immutable rating/timestamp sequence did not change.

## Integration testing

The Mongo workflow uses the exact pinned Bongo v0.4.0 source and starts:

- a MongoDB replica set for transactions;
- a standalone MongoDB fixture for review-first fallback;
- a TLS fixture for connection/error coverage.

Run the integration suite against those fixtures with:

```bash
zig build mongo-integration-test
```

The suite covers CRUD, reconnect persistence, due queues, sessions, scheduler pinning, immutable parameter sets, parameter scopes, archive restore, and recovery.

See `docs/bongo-0.4-integration.md` for the pinned consumer boundary.
