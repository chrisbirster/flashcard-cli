# Deez client architecture

Deez keeps one source of truth for study behavior while allowing multiple user interfaces.

## Repository boundaries

The core repository is `chrisbirster/deez`.

Separate client repositories:

- `chrisbirster/deez-web` — local SolidJS 2 web UI
- `chrisbirster/deez-desktop` — native desktop shell that reuses `deez-web`
- `chrisbirster/deez-mobile` — mobile client developed separately once StingJS is ready
- `chrisbirster/deez-run` — public catalog/discovery website for `.nut` content

Client repositories do not reimplement Deez domain behavior.

## Core ownership

The Zig core owns:

- SQLite and MongoDB/Bongo persistence
- immutable review history
- FSRS scheduling
- note-type definitions and validation
- note-to-card generation
- stable generated-card identity
- template rendering
- the structured `RenderedCard` interaction contract
- `.nut` and `.sack` import/export
- media identity and storage
- the local HTTP API used by graphical clients

## `deez serve`

`deez serve` is an on-demand local HTTP server for browser/desktop clients. It is not an always-running OS daemon.

The API is versioned beneath `/api/v1` and binds to loopback only by default.

Initial API areas:

```text
/api/v1/health
/api/v1/version
/api/v1/capabilities
/api/v1/decks
/api/v1/decks/:deck_id
/api/v1/decks/:deck_id/notes
/api/v1/decks/:deck_id/cards
/api/v1/notes/:note_id
/api/v1/notes/preview
/api/v1/cards/:card_id
```

`deez web` is a higher-level command planned to start the same local server, serve the built `deez-web` Vite `dist/`, and open the system browser.

## Local HTTP security

- bind to `127.0.0.1` by default
- never expose `0.0.0.0` without an explicit opt-in mode
- apply request/header/body/time limits
- validate browser-facing host/origin assumptions where appropriate
- do not treat CORS as authentication
- keep any future internet-facing service behind an appropriate reverse proxy/TLS boundary

## Notes versus cards

```text
Note (editable source)
        |
        v
card generation
        |
        v
Card(s) (study/scheduling identities)
```

Users normally edit notes. Generated cards are previewed/inspected and retain scheduling/review identity.

## Render contract

Clients consume:

```text
RenderedCard {
    front,
    back,
    css,
    interaction,
}
```

Interaction variants:

```text
reveal
type_answer
single_choice
multiple_choice
ordering
image_occlusion
```

Clients must not parse terminal text to infer interaction behavior.

## Web

`deez-web` is the local application UI. Its current direction is:

- SolidJS 2 current v2 beta/RC line
- Solid Router v2 compatible with Solid 2
- Vite
- TypeScript
- npm
- Tailwind CSS

The production build emits `dist/`; the Deez Zig process will serve those static assets for local web use.

## Desktop

`deez-desktop` is a thin native shell that reuses the authoritative `deez-web` UI. The first implementation may launch/connect to `deez serve` over loopback and load the same application in a system WebView.

## deez.run

`deez.run` is a separate public website/catalog. It is not the local application backend. Public `.nut` discovery/publishing may use a GitHub-backed registry/content model, but that work belongs in the separate `deez-run` repository.

## API evolution

- version wire endpoints
- use stable IDs for decks, notes, cards, choices, ordering items, and occlusion masks
- use tagged JSON interaction shapes
- return machine-readable error codes
- expose capability discovery
- add fields compatibly where possible
- make breaking wire changes in a new API version

See issue #95 for the local API implementation milestone.
