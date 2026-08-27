# Bongo v0.4.0 integration boundary

Deez uses Bongo v0.4.0 as its MongoDB driver and pins the exact package in `build.zig.zon`.

Current compatibility baseline:

```text
Bongo version: 0.4.0
Bongo commit: 8184b6266bab78fd3eb7fd8d2318f79f90e51937
Zig: 0.16.0
```

Deez compiles only against Bongo's public package module. It does not import Bongo source internals, wire-protocol implementation files, topology internals, transport internals, or pool internals.

## Deez dependency path

```text
Deez
  -> storage.Store
  -> MongoStore
  -> Bongo RuntimeClient
  -> MongoDB
```

The storage boundary is owned by Deez. Scheduler and study code call Deez storage operations rather than issuing MongoDB commands directly.

## Public Bongo capabilities Deez relies on

The Mongo backend uses the public runtime client for URI connections, document CRUD, cursors, indexes, BSON values/readers, sessions, and transactions. Replica-set review writes use transactions when available. Standalone MongoDB uses review-first writes and treats scheduler state as rebuildable cache.

## Required validation

Every Bongo dependency change must run:

```bash
zig build
zig build test
zig build mongo-integration-test
```

The live Mongo integration workflow starts replica-set, standalone, and TLS fixtures and must use the same Bongo commit pinned by Deez.

The Mongo acceptance suite covers:

- connection and reconnect persistence;
- deck/card CRUD and due queues;
- immutable review history;
- transactional review/state updates;
- standalone review-first recovery;
- scheduler pinning and unsupported-engine rejection;
- immutable parameter sets and parameter scope resolution;
- logical archive dry-run and restore;
- recovery from immutable history;
- required MongoDB indexes.

## Upgrade rule

Do not track an unreleased Bongo branch from Deez. A Bongo upgrade is a deliberate dependency change: update the exact URL/commit/hash, update this compatibility document, run the consumer and live Mongo suites, and only then treat the new Bongo release as the Deez baseline.
