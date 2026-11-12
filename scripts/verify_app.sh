#!/usr/bin/env bash
# Runs the verification matrix for S3DV viewer and collects one JSON report per
# case into runs/viewer_verify/.
#
# Every case is a real app launch: the app opens the recording, streams it over
# its own loopback WebSocket into WKWebView, then writes a self-test report.
# Exit codes: 0 pass, 3 mismatch, 4 timeout (see AutotestController).
#
#   ./scripts/verify_app.sh            # full matrix
#   ./scripts/verify_app.sh --quick    # demo + 244 MB only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIT="${S3DV_KIT:-$(cd "$ROOT/../.." && pwd)}"
# The app source can live outside the research repo (e.g. a working copy in
# ~/Downloads); when the sibling layout is missing, use the research kit's
# recordings so the matrix still exercises the real data.
[ -f "$KIT/samples/cube_orbit.s3dv" ] || KIT="/Users/yuki/Places_M1/研究/S3DV_研究"
APP="$ROOT/build/S3DV viewer.app/Contents/MacOS/S3DVViewer"
OUT="$ROOT/runs/viewer_verify"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

[ -x "$APP" ] || { echo "ERROR: $APP missing — run scripts/build_app.sh" >&2; exit 1; }
# Stray instances from an interrupted run keep WebGL contexts and file mappings
# alive and make later measurements (and throughput) meaningless.
pkill -f "S3DV viewer.app/Contents/MacOS/S3DVViewer" 2>/dev/null || true
sleep 1
mkdir -p "$OUT"

pass=0; fail=0; declare -a rows=()

run_case() { # name file seconds rate extra-env...
  local name="$1" file="$2" timeout="$3" rate="$4"; shift 4
  local report="$OUT/$name.json"
  echo "── $name"
  if [ ! -f "$file" ]; then
    echo "   SKIP (missing $file)"; rows+=("SKIP|$name|file missing"); return 0
  fi
  rm -f "$report"
  local t0; t0=$(date +%s)
  set +e
  env S3DV_VIEWER_AUTOTEST=1 S3DV_VIEWER_REPORT="$report" S3DV_VIEWER_RATE="$rate" \
      S3DV_VIEWER_TIMEOUT="$timeout" "$@" "$APP" "$file" >/dev/null 2>&1
  local code=$?
  set -e
  local spent=$(( $(date +%s) - t0 ))
  local verdict="missing"
  [ -f "$report" ] && verdict=$(/usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('verdict','?'))" "$report" 2>/dev/null || echo "?")
  if [ "$code" = 0 ] && [ "$verdict" = pass ]; then
    pass=$((pass+1)); rows+=("PASS|$name|${spent}s")
    echo "   PASS (${spent}s)"
  else
    fail=$((fail+1)); rows+=("FAIL|$name|exit=$code verdict=$verdict ${spent}s")
    echo "   FAIL exit=$code verdict=$verdict (${spent}s)"
  fi
}

run_case demo_product "$KIT/samples/cube_orbit.s3dv" 150 4 \
  'S3DV_VIEWER_EXPECT={"packets":34,"chunks":8,"triangles":1557}' \
  S3DV_VIEWER_SETTLE_MS=1500 S3DV_VIEWER_SHOT="$OUT/demo_product.png"
run_case demo_parity "$KIT/samples/cube_orbit.s3dv" 150 4 \
  S3DV_VIEWER_MODE=parity S3DV_VIEWER_SETTLE_MS=1500

run_case const_product "$KIT/runs/tdt_fuse/prod_const.s3dv" 420 8 \
  S3DV_VIEWER_SETTLE_MS=3000 S3DV_VIEWER_SHOT="$OUT/const_product.png"

if [ "$QUICK" = 0 ]; then
  run_case gt_product_2g "$KIT/runs/tdt_fuse/prod_gt.s3dv" 1500 16 \
    S3DV_VIEWER_SETTLE_MS=3000 S3DV_VIEWER_BUDGET_MB=2048 S3DV_VIEWER_SHOT="$OUT/gt_product.png"
  run_case gt_product_384m "$KIT/runs/tdt_fuse/prod_gt.s3dv" 1500 16 \
    S3DV_VIEWER_SETTLE_MS=3000 S3DV_VIEWER_BUDGET_MB=384
  run_case model_product "$KIT/runs/tdt_fuse/prod_model.s3dv" 1500 16 \
    S3DV_VIEWER_SETTLE_MS=3000 S3DV_VIEWER_BUDGET_MB=2048
  run_case leak_repeat10 "$KIT/runs/tdt_fuse/prod_const.s3dv" 3600 8 \
    S3DV_VIEWER_SETTLE_MS=1200 S3DV_VIEWER_REPEAT=10
fi

echo
echo "RSLT  CASE"
for row in "${rows[@]}"; do echo "$row" | awk -F'|' '{printf "%-5s %-18s %s\n",$1,$2,$3}'; done
echo
echo "pass=$pass fail=$fail  reports: $OUT"

# Summary markdown for the report.
{
  echo "# S3DV viewer verification matrix"
  echo
  echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo
  echo "| Result | Case | Detail |"
  echo "|---|---|---|"
  for row in "${rows[@]}"; do echo "$row" | awk -F'|' '{printf "| **%s** | %s | %s |\n",$1,$2,$3}'; done
} > "$OUT/SUMMARY.md"

[ "$fail" = 0 ]
