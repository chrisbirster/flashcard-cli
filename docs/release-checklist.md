# Plandalf release gate

Run this checklist against the exact commit that will be tagged or released.

## Build and tests

- [ ] `zig fmt --check build.zig src test` passes.
- [ ] `zig build` passes on Zig 0.16.0.
- [ ] `zig build test` passes.
- [ ] FSRS-7 parity/regression tests pass.
- [ ] property/fuzz coverage has no known panic, NaN, invalid interval, or state-transition regression.
- [ ] `zig build benchmark -Doptimize=ReleaseFast` completes successfully.

## SQLite and data safety

- [ ] a clean first run creates `~/.local/share/plandalf/plandalf.db`.
- [ ] `PLANDALF_DB` cleanly overrides the database location.
- [ ] no MongoDB/Bongo runtime dependency or backend-selection path is present.
- [ ] immutable review history remains authoritative.
- [ ] reviewed cards cannot be destructively deleted through normal content mutation.
- [ ] derived scheduler state can be rebuilt without rewriting reviews.
- [ ] existing scheduler majors do not silently change.
- [ ] parameter activation and scheduler migration remain explicit.

## `.deck` compatibility

- [ ] `plandalf deck export <id>` emits `plandalf.deck` version 2 NDJSON.
- [ ] a clean database can import the exported file.
- [ ] version 1 `plandalf.deck` card records remain importable while compatibility is promised.
- [ ] logical-note round trips preserve built-in note types and stable generation behavior.
- [ ] malformed input does not leave a partially imported deck.
- [ ] documentation states that `.deck` is content-only and excludes review/scheduler state.

## CLI

- [ ] `plandalf --help` succeeds without creating a database.
- [ ] `plandalf setup` reports the resolved SQLite path.
- [ ] deck/card/note/study/stats/inspect workflows succeed.
- [ ] destructive CLI operations require explicit confirmation where designed.
- [ ] removed `nut`, `sack`, backup, and Mongo commands do not resolve.
- [ ] help output and `docs/cli.md` agree.

## Local web/API

- [ ] `test/web_smoke.sh` passes.
- [ ] `test/web_media_smoke.sh` passes.
- [ ] the web/API server binds only to loopback.
- [ ] Host/Origin rejection tests pass.
- [ ] `plandalf web --no-open` works for shell/desktop-managed launch behavior.

## Cross-platform release smoke

- [ ] Linux CI build/test/benchmark job is green.
- [ ] macOS Apple Silicon release build launches `plandalf --help` successfully.
- [ ] macOS Intel release build launches `plandalf --help` successfully.
- [ ] release artifacts contain the `plandalf` binary name, not a compatibility `deez` binary.

## Performance

Record release baselines only on comparable hardware. Capture:

```text
Plandalf commit:
Plandalf version:
Zig version:
OS:
CPU:
Memory:
Optimization: ReleaseFast
```

Investigate significant regressions in scheduler replay, optimization, or `.deck` import before release.

## Required final commands

```bash
zig fmt --check build.zig src test
zig build
zig build test
zig build benchmark -Doptimize=ReleaseFast
```

The GitHub checks for the exact release commit must also be green.

## Release notes

Release notes should state:

- the Plandalf version;
- supported Zig version;
- supported scheduler major(s);
- SQLite as the application datastore;
- `.deck` format/version compatibility;
- review history as immutable source of truth;
- any schema, CLI, API, or deck-format compatibility changes.

Do not claim support for a scheduler major, platform, migration path, or interchange format that has not passed the corresponding tests above.
