#!/usr/bin/env bash
# Keeps the app's bundled copy of the kit web assets in lock-step with web/ of
# the kit. Differences from the kit's canonical files are limited to:
#   1. index.html importmap URLs point at the bundled copies of three@0.180.0
#      (offline capability). main.js is copied VERBATIM — do not edit the copy.
#   2. A demo .s3dv recording is embedded for first-run use.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"        # apps/s3dv-viewer
KIT="$(cd "$ROOT/../.." && pwd)"                # kit root
WEB="$KIT/web"
RES="$ROOT/Sources/S3DVViewer/Resources/web"
DEMO="$ROOT/Sources/S3DVViewer/Resources/demo"

# Hash pins for the vendored files (three@0.180.0, fetched 2026-10-19 from jsDelivr).
# three.module.js r180 re-export splits core into three.core.js, which it imports
# via a relative './three.core.js' URL — vendored right next to it.
PIN_THREE="c8211c69345d2e9949dc7a8ac969380497aa0600a5a8ac6a459c8cd02dd9cb8a"
PIN_THREE_CORE="eb077d2417f61d3e6d9264c317cabc4ea35769ed6b0ab533067292a550784c20"
PIN_ORBIT="b97879c748170baadeb3fb84cea1ffdf4674e283dc06042f34e2acb95a76042c"
# Pin the kit copies too: the app's parity guarantees are only valid for the
# main.js these were verified against. Bump deliberately when the kit evolves.
# 2026-10-25 consciously adopted (W3-B, docs/04 §5 P1): pause/step/resume/
# seek/speed JSON control channel, timeline + auto-reconnect UI. The app's
# transport is command-ignorant (see README "W3-B"), the new main.js degrades
# gracefully there.
# 2026-10-26 re-pin (docs/09 追記(7) audit): main.js ingest now rejects unknown
# opcodes (decode parity with s3dv.protocol), resolves the seek-waiting status
# at the SNAPSHOT_BEGIN even while paused, and flushes the pause-buffered tail
# on a clean end-of-stream so the session stays lossless. index.html unchanged.
# 2026-10-26 re-pin (W5, docs/14 §2.3): main.js enables TEXTURE_UPDATE (op 6):
# ingest-time payload pre-validation (codec/dims/crop/png sniff) + TextureCache
# (uv attr, per-chunk nearest/clamp sRGB material, bitmap lifecycle),
# telemetry "Textured chunks". index.html gains the matching metric row.
# 2026-10-26 re-pin (W5精査修正 F-C): main.js hardens op6: superseded bitmap
# disposal in applyTexture/textureMesh, texture-rev check without tombstones
# (cmp series independent, mirroring Python texture_rev-only ReduceResult),
# IHDR depth/colorType/interlace sniff at PNG offset 24, and
# createImageBitmap colorSpaceConversion:'none' for pixel parity with Pillow.
# telemetryJS gains an optional "tex" field (not an EXPECT key). index.html unchanged.
# 2026-10-26 re-pin (W6, docs/09 追記(13)): main.js gains the Runtime Metrics
# measurement UI: apply-time moving average (128 packets, decode+apply measured
# in onMessage / the replay paths), 1 s rolling rate windows (pkt_s, kib_s),
# fps/frame_ms (rAF window), renderer.info GPU-side proxies (draw calls,
# geometries, textures, programs), JS heap (Chromium-only, honest fallback),
# WebSocket bufferedAmount — all null-guarded DOM refs for the WKWebView
# bundle; per-packet DOM writes are avoided (4 Hz coalesced refresh). index.html
# gains the matching "Runtime Metrics" group and an honest proxy-scope note.
# 2026-10-26 W6精査 re-pin (docs/09 追記(14)): main.js gains the stale-socket
# onmessage guard (a replaced socket during mid-replay Restart must never
# double-ingest → Sequence gap) and rtReset clears pkt_s/kib_s off the previous
# connection's window. index.html clarifies the apply_ms semantics (decode+apply
# on live receive, apply-only on replay) in the label + honest-scope note.
PIN_MAIN="2177fd51af156519442919e89c9fb8b179e02502f1d60e49b7d0362cf4139ad7"
PIN_INDEX="005b3076c4020276c7fe0e8c2239a2c5d3f0e165bda5dcc05a52a7a06f5b093e"

mkdir -p "$RES/vendor/controls" "$DEMO"
for pin in "$PIN_MAIN  $WEB/main.js" "$PIN_INDEX  $WEB/index.html"; do
  echo "$pin" | (cd / && shasum -a 256 -c -) \
    || { echo "ERROR: kit web file changed — update the pin consciously (app parity was proven against the pinned bytes)" >&2; exit 1; }
done
cp "$WEB/index.html" "$RES/index.html"
cp "$WEB/main.js" "$RES/main.js"

sed -i '' \
  -e 's#https://cdn\.jsdelivr\.net/npm/three@0\.180\.0/build/three\.module\.js#./vendor/three.module.js#' \
  -e 's#https://cdn\.jsdelivr\.net/npm/three@0\.180\.0/examples/jsm/#./vendor/#' \
  "$RES/index.html"

# The importmap must now be local-only; fail loudly if the CDN URLs survived.
if grep -q jsdelivr "$RES/index.html"; then
  echo "ERROR: importmap still references the CDN after patching" >&2
  exit 1
fi

cp "$KIT/samples/cube_orbit.s3dv" "$DEMO/cube_orbit.s3dv"

for pin in "$PIN_THREE  $RES/vendor/three.module.js" \
           "$PIN_THREE_CORE  $RES/vendor/three.core.js" \
           "$PIN_ORBIT  $RES/vendor/controls/OrbitControls.js"; do
  echo "$pin" | (cd / && shasum -a 256 -c -) \
    || { echo "ERROR: vendored file hash mismatch — refetch from three@0.180.0" >&2; exit 1; }
done

echo "web assets synced: $(ls "$RES") + demo $(ls "$DEMO")"
