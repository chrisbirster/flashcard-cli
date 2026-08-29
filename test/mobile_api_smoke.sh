#!/usr/bin/env bash
set -euo pipefail

home=$(mktemp -d)
port=5884
token='plandalf-mobile-api-smoke-token'
origin='http://127.0.0.1:4173'
log=$(mktemp)

cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$home" "$log"
}
trap cleanup EXIT

HOME="$home" ./zig-out/bin/plandalf deck add 'Mobile Study' >/dev/null
HOME="$home" ./zig-out/bin/plandalf card add 1 'What is BSON?' 'Binary JSON' >/dev/null

HOME="$home" \
PLANDALF_API_TOKEN="$token" \
./zig-out/bin/plandalf serve --bind all --port "$port" --cors-origin "$origin" >"$log" 2>&1 &
server_pid=$!

for _ in $(seq 1 50); do
  if curl --silent --fail "http://127.0.0.1:${port}/api/v1/health" >/dev/null; then
    break
  fi
  sleep 0.1
done

curl --silent --fail "http://127.0.0.1:${port}/api/v1/health" | grep -q '"status":"ok"'

unauthorized=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  "http://127.0.0.1:${port}/api/v1/decks")
test "$unauthorized" = '401'

auth=(-H "Authorization: Bearer ${token}")

curl --silent --fail "${auth[@]}" \
  "http://127.0.0.1:${port}/api/v1/decks" | grep -q 'Mobile Study'

preflight=$(curl --silent --include --request OPTIONS \
  -H "Origin: ${origin}" \
  -H 'Access-Control-Request-Method: GET' \
  -H 'Access-Control-Request-Headers: Authorization' \
  "http://127.0.0.1:${port}/api/v1/decks")
printf '%s' "$preflight" | grep -q '204'
printf '%s' "$preflight" | grep -qi "Access-Control-Allow-Origin: ${origin}"

curl --silent --fail "${auth[@]}" \
  "http://127.0.0.1:${port}/api/v1/decks/1/study/next" | grep -q '"id":"1"'

curl --silent --fail "${auth[@]}" \
  "http://127.0.0.1:${port}/api/v1/cards/1/rendered" | grep -q 'What is BSON?'

curl --silent --fail "${auth[@]}" \
  "http://127.0.0.1:${port}/api/v1/cards/1/study/preview" | grep -q '"review_count":0'

review_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  "${auth[@]}" \
  -H 'Content-Type: application/json' \
  --data '{"rating":3,"expected_review_count":0}' \
  "http://127.0.0.1:${port}/api/v1/cards/1/reviews")
test "$review_status" = '201'

echo 'Plandalf mobile API smoke passed'
