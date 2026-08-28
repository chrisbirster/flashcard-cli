# Plandalf client architecture

Plandalf keeps one Zig source of truth for study behavior while allowing terminal and graphical interfaces to use the same domain model.

## Core ownership

The Zig core owns:

- SQLite persistence;
- immutable review history;
- FSRS scheduling and derived scheduler state;
- note-type definitions and validation;
- deterministic note-to-card generation;
- template and interaction rendering;
- `.deck` import/export;
- media identity/storage;
- the loopback HTTP API.

Clients should not reimplement scheduling, durable data rules, or note-to-card generation.

## Terminal client

The installed executable is `plandalf`. CLI parsing uses Thrawn, but Plandalf owns its command semantics and domain behavior.

## Local web/API surface

`plandalf web` starts the local application surface on `127.0.0.1`. It is on-demand, not an always-running operating-system daemon.

The API is versioned beneath `/api/v1`. Current areas include health, decks, notes, cards, media, and study operations.

The server applies local Host/Origin validation before serving application/API requests. Graphical clients should treat the local server as a private local capability, not as an internet-facing service.

Use:

```bash
plandalf web --no-open
```

when a shell or desktop host wants to manage browser/WebView behavior itself.

## Data boundary

All interfaces operate on the same SQLite database. By default:

```text
~/.local/share/plandalf/plandalf.db
```

Override it with `PLANDALF_DB` when a client needs an isolated database for development or testing.

The database and immutable review history remain authoritative. UI state is not.

## Content interchange

`.deck` is the portable deck-content boundary. It is for sharing/importing logical study content, not synchronizing an entire application database.

Version 2 contains logical notes and regenerates cards on import. Review history and scheduler state stay local.

Media references currently retain the established `deez-media://sha256:` URI scheme so existing stored card content remains valid. The URI is a data protocol and is intentionally versioned separately from the executable/product name.

## Client rules

A new client should:

1. use the Plandalf local API or core behavior rather than duplicate scheduler logic;
2. preserve string IDs exactly as returned by the API;
3. treat reviews as append-only events;
4. expect scheduler state to be rebuildable;
5. use `.deck` for portable deck content;
6. avoid exposing the loopback API beyond the local machine;
7. keep client-specific navigation and presentation outside the Zig domain core.

## Testing clients

End-to-end tests should start Plandalf with an isolated `HOME` or `PLANDALF_DB`, bind to a test port, exercise `/api/v1/health`, and clean up the process/database afterward.

The repository's `test/web_smoke.sh` and `test/web_media_smoke.sh` are the reference smoke flows for the local API contract.
