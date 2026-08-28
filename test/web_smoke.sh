#!/usr/bin/env bash
set -euo pipefail

tmp=$(mktemp -d)
port=49319
base="http://127.0.0.1:${port}"
api="$base/api/v1"
export HOME="$tmp/home"
export PLANDALF_DB="$tmp/plandalf.db"
mkdir -p "$HOME" "$tmp/web/assets"
printf '<!doctype html><title>Plandalf Web Smoke</title><div id="app">plandalf-spa-smoke</div>\n' >"$tmp/web/index.html"
printf 'console.log("plandalf-asset-smoke");\n' >"$tmp/web/assets/app.js"
printf 'must-not-be-served\n' >"$tmp/secret"

cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

./zig-out/bin/plandalf deck add "Web Smoke" >/dev/null
./zig-out/bin/plandalf web --port "$port" --web-root "$tmp/web" >"$tmp/web.log" 2>&1 &
server_pid=$!

ready=0
for _ in $(seq 1 50); do
  if curl -fsS "$api/health" >"$tmp/health.json" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.1
done
if [[ "$ready" != 1 ]]; then
  cat "$tmp/web.log" >&2
  exit 1
fi

# Static app serving and Solid Router fallback.
curl -fsS "$base/" | grep -q 'plandalf-spa-smoke'
curl -fsS "$base/decks/1" | grep -q 'plandalf-spa-smoke'
curl -fsS -D "$tmp/asset-headers.txt" "$base/assets/app.js" -o "$tmp/app.js"
grep -q 'plandalf-asset-smoke' "$tmp/app.js"
grep -qi '^content-type: text/javascript' "$tmp/asset-headers.txt"
grep -qi '^cache-control: public, max-age=31536000, immutable' "$tmp/asset-headers.txt"

missing_asset_code=$(curl -sS -o "$tmp/missing-asset.json" -w '%{http_code}' "$base/assets/missing.js")
test "$missing_asset_code" = "404"
unsafe_code=$(curl --path-as-is -sS -o "$tmp/unsafe.json" -w '%{http_code}' "$base/../secret")
test "$unsafe_code" = "404"
test "$(cat "$tmp/unsafe.json")" != 'must-not-be-served'

static_forbidden_code=$(curl -sS -o "$tmp/static-forbidden.json" -w '%{http_code}' -H 'Origin: https://example.com' "$base/")
test "$static_forbidden_code" = "403"

python3 - "$tmp/health.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    body = json.load(f)
assert body == {"status": "ok"}, body
PY

forbidden_code=$(curl -sS -o "$tmp/forbidden.json" -w '%{http_code}' -H 'Origin: https://example.com' "$api/health")
test "$forbidden_code" = "403"
python3 - "$tmp/forbidden.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    body = json.load(f)
assert body["error"]["code"] == "forbidden_origin", body
PY

curl -fsS "$api/decks" >"$tmp/decks.json"
python3 - "$tmp/decks.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    decks = json.load(f)
assert len(decks) == 1, decks
assert decks[0]["id"] == "1", decks
assert decks[0]["name"] == "Web Smoke", decks
assert decks[0]["note_count"] == 0, decks
assert decks[0]["card_count"] == 0, decks
PY

create_code=$(curl -sS -o "$tmp/created.json" -w '%{http_code}' \
  -X POST \
  -H 'Content-Type: application/json' \
  --data '{"note_type":"basic-reverse","fields":["France","Paris"],"tags":["geo"]}' \
  "$api/decks/1/notes")
test "$create_code" = "201"
note_id=$(python3 - "$tmp/created.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    note = json.load(f)
assert note["deck_id"] == "1", note
assert note["note_type"] == "basic-reverse", note
assert note["fields"] == ["France", "Paris"], note
assert note["tags"] == ["geo"], note
print(note["id"])
PY
)

curl -fsS \
  -X POST \
  -H 'Content-Type: application/json' \
  --data '{"note_type":"basic-reverse","fields":["France","Paris"],"tags":["geo"]}' \
  "$api/notes/preview" >"$tmp/preview.json"
python3 - "$tmp/preview.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    preview = json.load(f)
cards = preview["cards"]
assert len(cards) == 2, preview
assert [card["generation"] for card in cards] == [
    {"kind": "template", "ordinal": 0},
    {"kind": "template", "ordinal": 1},
], preview
assert all(card["interaction"]["type"] == "reveal" for card in cards), preview
assert all("front" in card and "back" in card and "css" in card for card in cards), preview
PY

curl -fsS "$api/decks/1/notes" >"$tmp/notes.json"
python3 - "$tmp/notes.json" "$note_id" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    notes = json.load(f)
assert len(notes) == 1, notes
assert notes[0]["id"] == sys.argv[2], notes
assert notes[0]["card_count"] == 2, notes
PY

curl -fsS "$api/decks/1/cards" >"$tmp/cards.json"
forward_card_id=$(python3 - "$tmp/cards.json" "$note_id" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    cards = json.load(f)
assert len(cards) == 2, cards
assert all(card["deck_id"] == "1" for card in cards), cards
assert all(card["note_id"] == sys.argv[2] for card in cards), cards
by_generation = {(card["generation"]["kind"], card["generation"]["ordinal"]): card for card in cards}
assert set(by_generation) == {("template", 0), ("template", 1)}, cards
assert by_generation[("template", 0)]["front"] == "France", cards
assert by_generation[("template", 1)]["front"] == "Paris", cards
print(by_generation[("template", 0)]["id"])
PY
)

curl -fsS "$api/cards/$forward_card_id" >"$tmp/card.json"
python3 - "$tmp/card.json" "$forward_card_id" "$note_id" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    card = json.load(f)
assert card["id"] == sys.argv[2], card
assert card["deck_id"] == "1", card
assert card["note_id"] == sys.argv[3], card
assert card["note_type"] == "basic-reverse", card
assert card["generation"] == {"kind": "template", "ordinal": 0}, card
assert card["rendered"]["front"] == "France", card
assert "Paris" in card["rendered"]["back"], card
assert card["rendered"]["interaction"]["type"] == "reveal", card
assert card["review_count"] == 0, card
PY

curl -fsS \
  -X PATCH \
  -H 'Content-Type: application/json' \
  --data '{"note_type":"basic-reverse","fields":["Capital of France","Paris"],"tags":["geo","edited"]}' \
  "$api/notes/$note_id" >"$tmp/updated.json"
python3 - "$tmp/updated.json" "$note_id" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    note = json.load(f)
assert note["id"] == sys.argv[2], note
assert note["fields"] == ["Capital of France", "Paris"], note
assert note["tags"] == ["geo", "edited"], note
PY

curl -fsS "$api/cards/$forward_card_id" >"$tmp/card-after-update.json"
python3 - "$tmp/card-after-update.json" "$forward_card_id" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    card = json.load(f)
assert card["id"] == sys.argv[2], card
assert card["rendered"]["front"] == "Capital of France", card
assert "Paris" in card["rendered"]["back"], card
PY

curl -fsS "$api/decks/1" >"$tmp/deck.json"
python3 - "$tmp/deck.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    deck = json.load(f)
assert deck["note_count"] == 1, deck
assert deck["card_count"] == 2, deck
assert deck["due_count"] == 2, deck
PY

# Study uses the same FSRS core as the terminal flow and protects immutable history.
curl -fsS "$api/decks/1/study/next" >"$tmp/study-next.json"
python3 - "$tmp/study-next.json" "$forward_card_id" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    body = json.load(f)
card = body["card"]
assert card is not None, body
assert card["id"] == sys.argv[2], body
assert card["deck_id"] == "1", body
assert card["due_at_ms"] is None, body
PY

curl -fsS "$api/cards/$forward_card_id/study/preview" >"$tmp/study-preview.json"
python3 - "$tmp/study-preview.json" "$forward_card_id" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    body = json.load(f)
assert body["card_id"] == sys.argv[2], body
assert body["review_count"] == 0, body
assert body["retrievability"] is None, body
schedule = body["schedule"]
assert [schedule[name]["rating"] for name in ("again", "hard", "good", "easy")] == [1, 2, 3, 4], body
assert all(schedule[name]["due_at_ms"] > 0 for name in schedule), body
assert all(schedule[name]["interval_days"] > 0 for name in schedule), body
PY

invalid_rating_code=$(curl -sS -o "$tmp/invalid-rating.json" -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' \
  --data '{"rating":5,"expected_review_count":0}' \
  "$api/cards/$forward_card_id/reviews")
test "$invalid_rating_code" = "400"
python3 - "$tmp/invalid-rating.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    body = json.load(f)
assert body["error"]["code"] == "invalid_rating", body
PY

review_code=$(curl -sS -o "$tmp/review.json" -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' \
  --data '{"rating":3,"expected_review_count":0}' \
  "$api/cards/$forward_card_id/reviews")
test "$review_code" = "201"
review_due=$(python3 - "$tmp/review.json" "$forward_card_id" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    body = json.load(f)
assert body["card_id"] == sys.argv[2], body
assert body["rating"] == 3, body
assert body["review_id"].isdigit(), body
assert body["interval_days"] > 0, body
assert body["scheduler"]["last_reviewed_at_ms"] is not None, body
assert body["scheduler"]["due_at_ms"] == body["due_at_ms"], body
print(body["due_at_ms"])
PY
)

test "$review_due" -gt 0

stale_code=$(curl -sS -o "$tmp/stale-review.json" -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' \
  --data '{"rating":3,"expected_review_count":0}' \
  "$api/cards/$forward_card_id/reviews")
test "$stale_code" = "409"
python3 - "$tmp/stale-review.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    body = json.load(f)
assert body["error"]["code"] == "stale_review", body
PY

early_code=$(curl -sS -o "$tmp/early-review.json" -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' \
  --data '{"rating":3,"expected_review_count":1}' \
  "$api/cards/$forward_card_id/reviews")
test "$early_code" = "409"
python3 - "$tmp/early-review.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    body = json.load(f)
assert body["error"]["code"] == "card_not_due", body
PY

curl -fsS "$api/cards/$forward_card_id" >"$tmp/reviewed-card.json"
python3 - "$tmp/reviewed-card.json" "$review_due" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    card = json.load(f)
assert card["review_count"] == 1, card
assert card["scheduler"]["due_at_ms"] == int(sys.argv[2]), card
assert card["scheduler"]["last_reviewed_at_ms"] is not None, card
PY

curl -fsS "$api/decks/1/study/next" >"$tmp/study-next-after-review.json"
python3 - "$tmp/study-next-after-review.json" "$forward_card_id" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    body = json.load(f)
card = body["card"]
assert card is not None, body
assert card["id"] != sys.argv[2], body
assert card["due_at_ms"] is None, body
PY

delete_code=$(curl -sS -o "$tmp/delete.txt" -w '%{http_code}' -X DELETE "$api/notes/$note_id")
test "$delete_code" = "204"

missing_code=$(curl -sS -o "$tmp/missing.json" -w '%{http_code}' "$api/notes/$note_id")
test "$missing_code" = "404"
python3 - "$tmp/missing.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    body = json.load(f)
assert body["error"]["code"] == "note_not_found", body
PY

missing_card_code=$(curl -sS -o "$tmp/missing-card.json" -w '%{http_code}' "$api/cards/$forward_card_id")
test "$missing_card_code" = "404"
python3 - "$tmp/missing-card.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    body = json.load(f)
assert body["error"]["code"] == "card_not_found", body
PY

curl -fsS "$api/decks/1/cards" >"$tmp/cards-after-delete.json"
python3 - "$tmp/cards-after-delete.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    cards = json.load(f)
assert cards == [], cards
PY

curl -fsS "$api/decks/1" >"$tmp/deck-after-delete.json"
python3 - "$tmp/deck-after-delete.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    deck = json.load(f)
assert deck["note_count"] == 0, deck
assert deck["card_count"] == 0, deck
assert deck["due_count"] == 0, deck
PY

echo "Plandalf Web app/API smoke passed"
