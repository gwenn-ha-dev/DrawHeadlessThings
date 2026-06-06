#!/usr/bin/env bash
# End-to-end smoke test for dht-server.
#
# Builds the binary (if missing), starts the server in the background,
# exercises a small suite of endpoints with real curl + jq assertions,
# then tears the server down. Closes the loop the XCTest suite can't:
# the wire format actually crossed a socket, the engine actually loaded,
# the route → engine → response pipeline actually produced a PNG/JPEG.
#
# Usage:
#   ./scripts/smoke-test.sh
#
# Env vars:
#   DHT_PORT         port to bind on (default 7777)
#   DHT_MODELS_DIR   models directory (default Draw Things app's dir)
#   DHT_LOG_LEVEL    server log level (default warning)
#
# Exits 0 on full success, 1 on any failure, 2 on pre-flight problems.
#
# Real-engine tests are SKIPPED if no image base model is installed in
# DHT_MODELS_DIR — we never auto-download (1 GB+ models are an explicit
# user choice). To unlock the full suite, install at least one image
# base model via the Draw Things app or POST /v1/assets/install.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PORT="${DHT_PORT:-7777}"
HOST="127.0.0.1"
BASE_URL="http://$HOST:$PORT"
MODELS_DIR="${DHT_MODELS_DIR:-$HOME/Library/Containers/com.liuliu.draw-things/Data/Documents/Models}"
LOG_LEVEL="${DHT_LOG_LEVEL:-warning}"
BINARY="$REPO_ROOT/.build/debug/dht-server"
OUTPUT_DIR="$REPO_ROOT/output"

# Terminal colors when stdout is a tty; bare strings otherwise.
if [ -t 1 ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; DIM=''; RESET=''
fi

PASS=0; FAIL=0; SKIP=0
FAILURES=()

section() { echo; echo "${BOLD}$1${RESET}"; }
pass() { PASS=$((PASS+1)); echo "  ${GREEN}✓${RESET} $1"; }
fail() { FAIL=$((FAIL+1)); FAILURES+=("$1"$'\n      '"$2"); echo "  ${RED}✗${RESET} $1"; echo "    ${DIM}$2${RESET}"; }
skip() { SKIP=$((SKIP+1)); echo "  ${YELLOW}-${RESET} $1 ${DIM}($2)${RESET}"; }

# ─────────────────────────── Pre-flight ───────────────────────────
section "Pre-flight"

for tool in jq curl lsof; do
  if ! command -v "$tool" >/dev/null; then
    echo "  ${RED}✗${RESET} '$tool' not found in PATH" >&2; exit 2
  fi
done

if [ ! -d "$MODELS_DIR" ]; then
  echo "  ${RED}✗${RESET} models dir does not exist: $MODELS_DIR" >&2
  echo "    set DHT_MODELS_DIR to override" >&2; exit 2
fi
pass "tools present (jq, curl, lsof), models dir exists"

if [ ! -x "$BINARY" ]; then
  echo "  ${DIM}building $BINARY ...${RESET}"
  swift build > /dev/null
fi
pass "binary built at $BINARY"

mkdir -p "$OUTPUT_DIR"
pass "output dir ready at $OUTPUT_DIR"

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "  ${RED}✗${RESET} port $PORT already in use — set DHT_PORT to another port" >&2
  exit 2
fi

# ─────────────────────────── Start server ───────────────────────────
section "Start server"

LOG_FILE=$(mktemp -t dht-smoke.XXXXXX)
"$BINARY" --host "$HOST" --port "$PORT" \
  --models-dir "$MODELS_DIR" --log-level "$LOG_LEVEL" \
  > "$LOG_FILE" 2>&1 &
SERVER_PID=$!

cleanup() {
  if kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [ "${FAIL:-0}" -eq 0 ]; then
    rm -f "$LOG_FILE"
  else
    echo
    echo "${DIM}server log preserved at $LOG_FILE${RESET}"
  fi
}
trap cleanup EXIT INT TERM

# Wait up to 10s for the server to answer /v1/info.
for _ in $(seq 1 50); do
  if curl -sf "$BASE_URL/v1/info" >/dev/null 2>&1; then break; fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "  ${RED}✗${RESET} server crashed during startup:" >&2
    cat "$LOG_FILE" >&2; exit 2
  fi
  sleep 0.2
done
if ! curl -sf "$BASE_URL/v1/info" >/dev/null 2>&1; then
  echo "  ${RED}✗${RESET} server did not come up within 10s" >&2
  cat "$LOG_FILE" >&2; exit 2
fi
pass "server listening on $BASE_URL (pid $SERVER_PID)"

# ─────────────────────────── Stateless tests ───────────────────────────
section "Stateless wire tests"

# /v1/info shape
RESP=$(curl -sf "$BASE_URL/v1/info")
if jq -e '.api_version and .engine_version' <<<"$RESP" >/dev/null; then
  pass "GET /v1/info returns api_version + engine_version"
else
  fail "GET /v1/info" "$RESP"
fi

# /v1/resolve/compose with unknown model → 200 with errors[].code == MODEL_NOT_INSTALLED
RESP=$(curl -s -X POST "$BASE_URL/v1/resolve/compose" \
  -H 'content-type: application/json' \
  -d '{"model":"definitely-not-installed","prompt":"x","params":{"width":512,"height":512,"steps":1}}')
if jq -e '.errors[0].code == "MODEL_NOT_INSTALLED"' <<<"$RESP" >/dev/null; then
  pass "POST /v1/resolve/compose unknown model → errors[].code MODEL_NOT_INSTALLED"
else
  fail "POST /v1/resolve/compose unknown model" "$RESP"
fi

# /v1/compose validation (width not multiple of 64) → 400 VALIDATION_FAILED
TMPBODY=$(mktemp -t dht-smoke-body.XXXXXX)
STATUS=$(curl -s -o "$TMPBODY" -w '%{http_code}' -X POST "$BASE_URL/v1/compose" \
  -H 'content-type: application/json' \
  -d '{"model":"x","prompt":"x","params":{"width":100,"height":512,"steps":1}}')
BODY=$(cat "$TMPBODY"); rm -f "$TMPBODY"
if [ "$STATUS" = "400" ] && jq -e '.error_code == "VALIDATION_FAILED"' <<<"$BODY" >/dev/null; then
  pass "POST /v1/compose invalid width → 400 VALIDATION_FAILED"
else
  fail "POST /v1/compose invalid width" "status=$STATUS body=$BODY"
fi

# DELETE /v1/runs/{unknown} → 404 RUN_NOT_FOUND
TMPBODY=$(mktemp -t dht-smoke-body.XXXXXX)
STATUS=$(curl -s -o "$TMPBODY" -w '%{http_code}' -X DELETE "$BASE_URL/v1/runs/nope-xyz")
BODY=$(cat "$TMPBODY"); rm -f "$TMPBODY"
if [ "$STATUS" = "404" ] && jq -e '.error_code == "RUN_NOT_FOUND"' <<<"$BODY" >/dev/null; then
  pass "DELETE /v1/runs/{unknown} → 404 RUN_NOT_FOUND"
else
  fail "DELETE /v1/runs/{unknown}" "status=$STATUS body=$BODY"
fi

# /v1/assets returns an items[] array
RESP=$(curl -sf "$BASE_URL/v1/assets")
if jq -e '.items | type == "array"' <<<"$RESP" >/dev/null; then
  COUNT=$(jq '.items | length' <<<"$RESP")
  pass "GET /v1/assets returns an array ($COUNT items)"
else
  fail "GET /v1/assets" "$RESP"
fi

# ─────────────────────────── Real-engine tests ───────────────────────────
section "Real-engine tests"

IMAGE_MODEL=$(curl -sf "$BASE_URL/v1/assets?type=base_model&domain=image&downloaded=true" \
  | jq -r '.items[0].id // empty')

if [ -z "$IMAGE_MODEL" ]; then
  skip "real-engine happy path" "no image base model installed; install one via Draw Things or POST /v1/assets/install"
else
  echo "  ${DIM}using base model: $IMAGE_MODEL${RESET}"

  # /v1/resolve/compose happy path: errors[] empty, applied_defaults non-trivial
  REQ=$(jq -nc --arg m "$IMAGE_MODEL" \
    '{model: $m, prompt: "a misty forest at dawn", params: {width: 512, height: 512, steps: 4}}')
  RESP=$(curl -sf -X POST "$BASE_URL/v1/resolve/compose" \
    -H 'content-type: application/json' -d "$REQ")
  RESOLVE_JSON="$OUTPUT_DIR/smoke-resolve.json"
  jq . <<<"$RESP" > "$RESOLVE_JSON"
  if jq -e '.errors | length == 0' <<<"$RESP" >/dev/null; then
    pass "POST /v1/resolve/compose happy path returns no errors → $RESOLVE_JSON"
  else
    fail "POST /v1/resolve/compose happy path" "$RESP"
  fi
  if jq -e '.applied_defaults | type == "array"' <<<"$RESP" >/dev/null; then
    N=$(jq '.applied_defaults | length' <<<"$RESP")
    if [ "$N" -gt 0 ]; then
      pass "POST /v1/resolve/compose enriches applied_defaults ($N filled)"
    else
      # Not a failure on every model — z_image_turbo & co. expose few
      # defaultable Core fields. Skip rather than fail.
      skip "POST /v1/resolve/compose applied_defaults non-empty" "model exposes no Core defaults"
    fi
  else
    fail "POST /v1/resolve/compose applied_defaults shape" "$RESP"
  fi
  if jq -e '.estimated_compute_units | type == "number"' <<<"$RESP" >/dev/null; then
    ECU=$(jq '.estimated_compute_units' <<<"$RESP")
    pass "POST /v1/resolve/compose estimates compute units ($ECU)"
  else
    skip "POST /v1/resolve/compose ECU present" "engine returned null for this archi"
  fi

  # /v1/compose minimal happy path. 256² steps=2 to keep it fast; first
  # call may pay weight-load cost, hence the 300s timeout. We capture
  # the X-DHT-Recipe header — it must be present on every successful
  # generation response — and dump it alongside the JSON / PNG.
  REQ=$(jq -nc --arg m "$IMAGE_MODEL" \
    '{model: $m, prompt: "smoke test", params: {width: 256, height: 256, steps: 2}}')
  echo "  ${DIM}running real generation (may take 30-90s on first run while weights load) ...${RESET}"
  HDR_FILE=$(mktemp -t dht-smoke-headers.XXXXXX)
  RESP=$(curl -sf --max-time 300 -D "$HDR_FILE" -X POST "$BASE_URL/v1/compose" \
    -H 'content-type: application/json' -d "$REQ")
  if jq -e '.images | length >= 1' <<<"$RESP" >/dev/null; then
    SIZE=$(jq -r '.images[0] | length' <<<"$RESP")
    MS=$(jq -r '.generation_time_ms' <<<"$RESP")
    # Persist artifacts: full response with metadata, plus the decoded PNG
    # so a visual eyeball check is one open away. Overwrites on each run.
    COMPOSE_JSON="$OUTPUT_DIR/smoke-compose.json"
    COMPOSE_PNG="$OUTPUT_DIR/smoke-compose.png"
    # Dump the response with images[] elided (keep metadata + counts) to
    # keep the JSON readable — base64 PNG bytes go to the .png next to it.
    jq '. + {images: (.images | map(.[0:32] + "...(elided)"))}' <<<"$RESP" > "$COMPOSE_JSON"
    jq -r '.images[0]' <<<"$RESP" | base64 -D > "$COMPOSE_PNG"
    pass "POST /v1/compose produces an image (${SIZE} base64 chars in ${MS}ms) → $COMPOSE_PNG"
  else
    PREVIEW=$(head -c 400 <<<"$RESP")
    fail "POST /v1/compose happy path" "$PREVIEW"
  fi
  # X-DHT-Recipe header: header names are case-insensitive on the wire
  # but curl preserves the server's casing, so match insensitively.
  if grep -iq '^x-dht-recipe:' "$HDR_FILE"; then
    pass "POST /v1/compose response carries X-DHT-Recipe header"
  else
    fail "POST /v1/compose X-DHT-Recipe header" "headers: $(cat "$HDR_FILE")"
  fi
  rm -f "$HDR_FILE"
fi

# ─────────────────────────── Summary ───────────────────────────
section "Summary"
echo "  ${GREEN}$PASS passed${RESET}, ${RED}$FAIL failed${RESET}, ${YELLOW}$SKIP skipped${RESET}"
if [ "$FAIL" -gt 0 ]; then
  echo
  echo "${BOLD}Failures:${RESET}"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
