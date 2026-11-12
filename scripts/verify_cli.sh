#!/usr/bin/env bash
# verify_cli.sh — proves that a running viewer can be driven entirely from the
# command line: launch the app, then exercise every control verb over the socket.
#
#   ./scripts/verify_cli.sh [sample.s3dv]
#
# Prints a PASS/FAIL table; exits non-zero on any failure. The app is always
# terminated and the socket removed afterwards.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIT="$(cd "$ROOT/../.." && pwd)"
# The app source can live outside the research repo (e.g. a working copy in
# ~/Downloads); when the sibling samples layout is missing, fall back to the
# research kit's recordings so the default sample resolves.
[ -f "$KIT/samples/cube_orbit.s3dv" ] || KIT="/Users/yuki/Places_M1/研究/S3DV_研究"
APP="$ROOT/build/S3DV viewer.app/Contents/MacOS/S3DVViewer"
CTL="$ROOT/build/S3DV viewer.app/Contents/MacOS/s3dvctl"
SAMPLE="${1:-$KIT/samples/cube_orbit.s3dv}"
SOCK="${S3DV_CONTROL_SOCKET:-$HOME/Library/Application Support/S3DV viewer/control.sock}"
LOG="$(mktemp "${TMPDIR:-/tmp}/s3dv-cli-log.XXXXXX")"
CAUGHT="$(mktemp "${TMPDIR:-/tmp}/s3dv-cli-shot.XXXXXX").png"

[ -x "$APP" ] || { echo "ERROR: $APP missing — run scripts/build_app.sh" >&2; exit 1; }
[ -x "$CTL" ] || { echo "ERROR: $CTL missing — run scripts/build_app.sh" >&2; exit 1; }

PASS=0; FAIL=0
rows=()
check() { # check <name> <condition-exit-code> <detail>
  if [ "$2" -eq 0 ]; then rows+=("PASS|$1|$3"); PASS=$((PASS+1));
  else rows+=("FAIL|$1|$3"); FAIL=$((FAIL+1)); fi
}
json() { "$CTL" "$@" --json 2>/dev/null || true; }
field() { # field <json> <key>  — prints the value or empty
  printf '%s' "$1" | /usr/bin/python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
v=d.get(sys.argv[1])
print("" if v is None else (str(v).lower() if isinstance(v,bool) else v))' "$2"
}

cleanup() {
  pkill -f "S3DV viewer.app/Contents/MacOS/" >/dev/null 2>&1 || true
  rm -f "$SOCK" 2>/dev/null || true
  rm -f "$LOG" "$CAUGHT" 2>/dev/null || true
}
trap cleanup EXIT

pkill -f "S3DV viewer.app/Contents/MacOS/" >/dev/null 2>&1 || true
rm -f "$SOCK"
sleep 0.5

echo "── launching $(basename "$SAMPLE")"
S3DV_CONTROL_SOCKET="$SOCK" "$APP" "$SAMPLE" >"$LOG" 2>&1 &
APP_PID=$!

ready=1
for _ in $(seq 1 60); do
  if S3DV_CONTROL_SOCKET="$SOCK" "$CTL" ping >/dev/null 2>&1; then ready=0; break; fi
  sleep 0.5
done
check "socket is up" "$ready" "$SOCK"

if [ "$ready" -ne 0 ]; then
  echo "app log:"; tail -20 "$LOG"; exit 1
fi

# Slow the replay down straight away so the transport checks land mid-stream
# (the bundled demo is only 7.5 s of timeline and otherwise finishes in ~2 s).
"$CTL" set rate 0.25 >/dev/null 2>&1 || true

status=""
for _ in $(seq 1 80); do
  status="$(json status)"
  # Break only once streaming has actually started: phase flips to `playing`
  # before the first packet counter is visible, so require packetCount > 0
  # to avoid a racy pass on an empty snapshot.
  [ "$(field "$status" pageReady)" = true ] && [ "$(field "$status" packetCount)" -gt 0 ] 2>/dev/null && break
  sleep 0.5
done
check "open via argv" "$([ "$(field "$status" packetCount)" -gt 0 ] 2>/dev/null && echo 0 || echo 1)" \
  "packetCount=$(field "$status" packetCount)"
check "page attached" "$([ "$(field "$status" pageReady)" = true ] && echo 0 || echo 1)" \
  "pageReady=$(field "$status" pageReady) phase=$(field "$status" phase)"

# ── transport ────────────────────────────────────────────────────────────────
"$CTL" pause >/dev/null 2>&1 || true
sleep 0.4
check "pause" "$([ "$(field "$(json status)" phase)" = paused ] && echo 0 || echo 1)" \
  "phase=$(field "$(json status)" phase)"

before="$(field "$(json status)" framesSent)"
"$CTL" step >/dev/null 2>&1 || true
sleep 0.4
after="$(field "$(json status)" framesSent)"
check "step advances one frame" "$([ "$after" -gt "$before" ] 2>/dev/null && echo 0 || echo 1)" \
  "$before → $after"

"$CTL" play >/dev/null 2>&1 || true
sleep 0.4
check "play" "$([ "$(field "$(json status)" phase)" != paused ] && echo 0 || echo 1)" \
  "phase=$(field "$(json status)" phase)"

seek_reply="$(json seek t=0)"
check "seek accepted" "$([ "$(field "$seek_reply" requested)" = 0 ] && echo 0 || echo 1)" \
  "requested=$(field "$seek_reply" requested)"
sleep 0.6
seek_time="$(field "$(json status)" time)"
check "seek re-anchored near 0 s" \
  "$(/usr/bin/python3 -c "import sys;sys.exit(0 if float('${seek_time:-99}') < 5.0 else 1)" && echo 0 || echo 1)" \
  "time=${seek_time}s"

"$CTL" set rate 0.5 >/dev/null 2>&1 || true
sleep 0.3
check "set rate" "$([ "$(field "$(json status)" rate)" = 0.5 ] && echo 0 || echo 1)" \
  "rate=$(field "$(json status)" rate)"

"$CTL" loop on >/dev/null 2>&1 || true
sleep 0.3
check "loop on" "$([ "$(field "$(json status)" loop)" = true ] && echo 0 || echo 1)" \
  "loop=$(field "$(json status)" loop)"
"$CTL" loop off >/dev/null 2>&1 || true

# ── settings surface ─────────────────────────────────────────────────────────
"$CTL" set budget 384 >/dev/null 2>&1 || true
sleep 0.3
check "set budget" "$([ "$(field "$(json status)" budgetMB)" = 384 ] && echo 0 || echo 1)" \
  "budgetMB=$(field "$(json status)" budgetMB)"

"$CTL" wireframe on >/dev/null 2>&1 || true
sleep 0.3
check "wireframe on" "$([ "$(field "$(json settings)" wireframe)" = true ] && echo 0 || echo 1)" \
  "wireframe=$(field "$(json settings)" wireframe)"
"$CTL" wireframe off >/dev/null 2>&1 || true

"$CTL" set evictionPolicy lru >/dev/null 2>&1 || true
sleep 0.3
check "set enum (evictionPolicy)" \
  "$([ "$(field "$(json settings)" evictionPolicy)" = lru ] && echo 0 || echo 1)" \
  "evictionPolicy=$(field "$(json settings)" evictionPolicy)"
"$CTL" set evictionPolicy spatial >/dev/null 2>&1 || true

bad="$("$CTL" set nosuchkey 1 2>&1; echo "rc=$?")"
check "unknown setting is rejected" "$(printf '%s' "$bad" | grep -q 'rc=1' && echo 0 || echo 1)" \
  "$(printf '%s' "$bad" | head -1)"

# ── introspection ────────────────────────────────────────────────────────────
metrics="$(json metrics)"
check "metrics" "$([ -n "$(field "$metrics" chunks)" ] && echo 0 || echo 1)" \
  "chunks=$(field "$metrics" chunks) triangles=$(field "$metrics" triangles) fps=$(field "$metrics" fps)"

bench="$(json bench 3)"
ms="$(field "$bench" msPerFrame)"
check "bench (GPU-synchronised)" "$([ -n "$ms" ] && /usr/bin/python3 -c "import sys;sys.exit(0 if float('$ms')>0 else 1)" && echo 0 || echo 1)" \
  "msPerFrame=$ms"

logs="$(json logs 5)"
check "logs" "$(printf '%s' "$logs" | grep -q '"logs"' && echo 0 || echo 1)" \
  "$(printf '%s' "$logs" | /usr/bin/python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("logs",[])),"lines")' 2>/dev/null)"

"$CTL" screenshot path="$CAUGHT" >/dev/null 2>&1 || true
check "screenshot" "$([ -s "$CAUGHT" ] && echo 0 || echo 1)" "$(basename "$CAUGHT") $([ -s "$CAUGHT" ] && wc -c <"$CAUGHT" | tr -d ' ' || echo 0) bytes"

help_out="$("$CTL" help 2>&1)"
check "help lists commands" "$(printf '%s' "$help_out" | grep -q 'seek' && echo 0 || echo 1)" \
  "$(printf '%s' "$help_out" | wc -l | tr -d ' ') lines"

# ── completion ───────────────────────────────────────────────────────────────
waited="$(json wait timeout=120)"
if [ "$(field "$waited" finished)" != true ]; then
  waited="$(json wait timeout=120)"   # one retry: the first call can race a reload
fi
check "wait reaches completion" "$([ "$(field "$waited" finished)" = true ] && echo 0 || echo 1)" \
  "phase=$(field "$waited" phase) packets=$(field "$waited" packetsSent) raw=$(printf '%s' "$waited" | head -c 80)"

"$CTL" quit >/dev/null 2>&1 || true
gone=1
for _ in $(seq 1 40); do
  if ! kill -0 "$APP_PID" 2>/dev/null; then gone=0; break; fi
  sleep 0.25
done
check "quit terminates the app" "$gone" "pid $APP_PID"

echo
printf '%-4s %-28s %s\n' RSLT CHECK DETAIL
for row in "${rows[@]}"; do
  IFS='|' read -r r c d <<<"$row"
  printf '%-4s %-28s %s\n' "$r" "$c" "$d"
done
echo
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS checks — the app was driven entirely from the CLI"
  exit 0
fi
echo "FAIL: $FAIL of $((PASS+FAIL)) checks failed"
exit 1
