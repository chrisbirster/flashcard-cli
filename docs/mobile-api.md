# Plandalf mobile API

`plandalf serve` exposes the SQLite-backed Plandalf API without changing CLI study behavior.

## Local development

```bash
plandalf serve
```

The default endpoint is `http://127.0.0.1:5882`.

## LAN or remote access

Binding beyond loopback is explicit and requires a bearer token:

```bash
export PLANDALF_API_TOKEN="$(openssl rand -hex 32)"
plandalf serve --bind all --cors-origin https://study.example.com
```

`--cors-origin` is one exact browser origin. It is optional for non-browser API clients.

`plandalf serve` provides HTTP, not TLS. For access away from the local network, put it behind a trusted HTTPS reverse proxy or a private VPN such as Tailscale. Do not expose the raw HTTP listener directly to the public internet.

Health and version are public. Other endpoints require:

```text
Authorization: Bearer <PLANDALF_API_TOKEN>
```

## Study flow

List decks:

```http
GET /api/v1/decks
```

Fetch the next due/new card ID:

```http
GET /api/v1/decks/:id/study/next
```

Fetch the rendered card, including its interaction model and current review count:

```http
GET /api/v1/cards/:id/rendered
```

Fetch the current FSRS rating schedule:

```http
GET /api/v1/cards/:id/study/preview
```

Record a review:

```http
POST /api/v1/cards/:id/reviews
Content-Type: application/json

{"rating":3,"expected_review_count":4}
```

Ratings are:

- `1` Again
- `2` Hard
- `3` Good
- `4` Easy

`expected_review_count` is an optimistic-concurrency guard. If another client reviewed the card after it was loaded, the API returns `409 stale_review` instead of double-recording a stale answer.

The rendered-card response supports the same interaction types as Plandalf Web: reveal, type answer, single choice, multiple choice, ordering, and image occlusion.

## Existing content API

The existing `plandalf serve` deck, card, note, preview, health, version, and capabilities routes remain available. The mobile study routes are additive.
