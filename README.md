# Plandalf

Plandalf is a terminal-first spaced-repetition flashcard application written in Zig.

> A review is never late, nor is it early. It arrives precisely when it means to.

Plandalf keeps the application deliberately local and simple:

- Zig 0.16
- SQLite as the only storage backend
- FSRS-7 scheduling
- terminal study workflow
- local web UI/API bound to loopback
- one shareable deck format: `.deck`

## Install

Plandalf releases are native archives. The initial supported release targets are:

- Linux x86_64
- macOS Apple Silicon (aarch64)
- macOS Intel (x86_64)

Download the archive for your platform from GitHub Releases, extract it, and put `plandalf` somewhere on your `PATH`.

For example:

```bash
tar -xzf plandalf-v0.1.0-<platform>.tar.gz
mkdir -p ~/.local/bin
install -m 0755 plandalf ~/.local/bin/plandalf
plandalf --help
```

Every release also publishes `SHA256SUMS` so the downloaded archive can be verified before installation.

Plandalf currently links against the platform SQLite library. macOS provides SQLite with the operating system. Linux users need a compatible SQLite runtime library installed (for example the distro package that provides `libsqlite3.so`). Linux release artifacts are built on GitHub's Ubuntu runner, so fully static/musl portability is not claimed yet.

Windows is not advertised as supported until a native Windows build and smoke test are part of CI.

## Build

Plandalf currently targets Zig 0.16.0 and links against SQLite.

```bash
zig build
./zig-out/bin/plandalf --help
```

Run the tests:

```bash
zig build test
```

Run deterministic benchmarks:

```bash
zig build benchmark -Doptimize=ReleaseFast
```

## Storage

Plandalf uses SQLite only.

The default database is:

```text
~/.local/share/plandalf/plandalf.db
```

Override it with `PLANDALF_DB`:

```bash
PLANDALF_DB=/tmp/plandalf.db plandalf decks
```

There is no storage-backend selection step and no MongoDB configuration in the Plandalf application.

## Basic usage

Create and list decks:

```bash
plandalf deck add "Spanish"
plandalf decks
```

Add a card:

```bash
plandalf card add 1 "hola" "hello"
```

Study:

```bash
plandalf study 1
```

Inspect the scheduler:

```bash
plandalf inspect 1
plandalf scheduler list
```

## Notes and card types

Plandalf supports logical notes that generate one or more cards. Built-in note types include basic, reverse, optional reverse, cloze, and typed-answer flows.

For example:

```bash
plandalf note add 1 basic "Capital of France" "Paris"
plandalf note add 1 cloze "Paris is the capital of {{c1::France}}." "Europe"
```

## `.deck` files

`.deck` is Plandalf's only public shareable deck format.

Export:

```bash
plandalf deck export 1 > spanish.deck
```

Import:

```bash
plandalf deck import spanish.deck
```

The format is UTF-8 NDJSON. Version 2 begins with a header like:

```json
{"kind":"deck","format":"plandalf.deck","version":2,"name":"Spanish"}
```

It then stores logical note records. Review history, scheduler state, due dates, and other personal study progress are intentionally excluded from shareable deck files.

See [`docs/deck-format.md`](docs/deck-format.md).

## FSRS-7

Plandalf uses FSRS-7 and keeps immutable review history as source data. Scheduler state can be rebuilt from that history.

Useful commands include:

```bash
plandalf fsrs evaluate
plandalf fsrs optimize
plandalf fsrs simulate
plandalf fsrs retention
```

The repository includes parity and property tests for the FSRS-7 implementation.

## Local web app

Plandalf can expose its local application UI/API on loopback:

```bash
plandalf web
```

The listener is local-only (`127.0.0.1`). To avoid opening a browser automatically:

```bash
plandalf web --no-open
```

## Development philosophy

Plandalf favors:

- local-first data ownership
- a small native executable
- SQLite instead of an external database service
- deterministic, testable scheduling behavior
- portable deck content without portable personal history
- straightforward CLI workflows

## License

MIT
