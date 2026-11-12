#!/usr/bin/env bash
# DEBUG ONLY — assembles the bundle, appends the temporary scene probe hooks to
# the BUILT main.js (never to the source tree), and runs one autotest pass.
# The hooks vanish on the next ./scripts/build_app.sh (bundle main.js is copied
# from the pristine source copy), which is why this script re-appends each time.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_PARENT="$(cd "$HERE/.." && pwd)"
KIT="$(cd "$APP_PARENT/../.." && pwd)"
SAMPLE="${1:-$KIT/samples/cube_orbit.s3dv}"
RATE="${S3DV_VIEWER_RATE:-8}"
MAINJS="$APP_PARENT/build/S3DV Viewer.app/Contents/Resources/web/main.js"

"$APP_PARENT/scripts/build_app.sh" >/dev/null

if ! grep -q "s3dvDbg" "$MAINJS"; then
cat >> "$MAINJS" <<'HOOK'

// ==== TEMPORARY DEBUG HOOKS (built bundle only; removed by rebuild) ====
window.__s3dvDbg = () => {
  const meshes = [];
  for (const [id, it] of registry.entries()) {
    const m = it.mesh, g = m.geometry;
    const p = g.attributes.position, c = g.attributes.color;
    let pmin = Infinity, pmax = -Infinity;
    if (p) { for (let i = 0; i < p.array.length; i++) { const v = p.array[i]; if (v < pmin) pmin = v; if (v > pmax) pmax = v; } }
    let cmin = Infinity, cmax = -Infinity;
    if (c) { for (let i = 0; i < c.array.length; i++) { const v = c.array[i]; if (v < cmin) cmin = v; if (v > cmax) cmax = v; } }
    g.computeBoundingSphere();
    const b = g.boundingSphere;
    meshes.push({ id, rev: it.rev, verts: p ? p.count : -1, tris: g.index ? g.index.count / 3 : -1,
      inScene: m.parent === scene, visible: m.visible,
      bs: { c: b.center.toArray().map(v => Math.round(v * 1000) / 1000), r: Math.round(b.radius * 1000) / 1000 } });
  }
  return JSON.stringify({ meshes,
    camera: { pos: camera.position.toArray().map(v => Math.round(v * 1000) / 1000),
              up: camera.up.toArray(), fov: camera.fov },
    lights: scene.children.filter(o => o.isLight).map(l => l.type),
    sceneTypes: scene.children.map(o => o.type),
    canvas: { w: renderer.domElement.width, h: renderer.domElement.height,
              styleW: renderer.domElement.clientWidth, styleH: renderer.domElement.clientHeight,
              pixelRatio: renderer.getPixelRatio() },
    info: { calls: renderer.info.render.calls, triangles: renderer.info.render.triangles } });
};

window.__s3dvDbgDrawTest = () => {
  const m = registry.get('1').mesh, g = m.geometry;
  renderer.render(scene, camera);
  const a = renderer.info.render;
  return JSON.stringify({
    frustumCulled: m.frustumCulled,
    drawRange: { start: g.drawRange.start, count: g.drawRange.count },
    pos: { itemSize: g.attributes.position.itemSize, T: g.attributes.position.array.constructor.name,
           len: g.attributes.position.array.length },
    idx: { T: g.index.array.constructor.name, len: g.index.array.length,
           max: Math.max(...Array.from(g.index.array.slice(0, 60))) },
    progN: renderer.info.programs ? renderer.info.programs.length : -1,
    matType: m.material.type, outCS: renderer.outputColorSpace,
    trisAfter: a.triangles, callsAfter: a.calls,
    projNaN: camera.projectionMatrix.elements.some(v => Number.isNaN(v)),
    meshWorldNaN: m.matrixWorld.elements.some(v => Number.isNaN(v)),
    typesInScene: Array.from(new Set(scene.children.map(o => o.type))),
    dataUrl: renderer.domElement.toDataURL('image/png'),
    visibility: document.visibilityState,
    hidden: document.hidden
  });
};
HOOK
fi

RUN_DIR="${S3DV_PROBE_DIR:-$APP_PARENT/runs}"
mkdir -p "$RUN_DIR"
STAMP="$(date +%H%M%S)"
TMP_REPORT="$RUN_DIR/probe-$STAMP.json"

S3DV_VIEWER_TIMEOUT="${S3DV_VIEWER_TIMEOUT:-20}" \
S3DV_VIEWER_AUTOTEST=1 \
S3DV_VIEWER_RATE="$RATE" \
S3DV_VIEWER_REPORT="$TMP_REPORT" \
  "$APP_PARENT/build/S3DV Viewer.app/Contents/MacOS/S3DVViewer" "$SAMPLE" || true

python3 - "$TMP_REPORT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("verdict:", d["verdict"], "mismatch:", d.get("mismatch"))
print("console:", json.dumps(d.get("console")))
p = d.get("probe")
if isinstance(p, dict) and "drawTest" in p:
    dt = p.pop("drawTest")
    compact = {k: dt[k] for k in ("frustumCulled", "trisAfter", "callsAfter", "progN",
                                  "hidden", "visibility") if k in dt}
    print("drawTest:", json.dumps(compact, ensure_ascii=False))
print("probe:", json.dumps(p, ensure_ascii=False)[:1200] if p else "NONE")
PY
