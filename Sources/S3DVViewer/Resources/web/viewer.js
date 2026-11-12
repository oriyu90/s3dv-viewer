// S3DV viewer — standard (batched) renderer.
//
// Derived from the research kit's web/main.js: the wire parsing, validation and
// control-channel semantics are intentionally identical, so both renderers agree
// on what a stream means. What differs is the draw path:
//
//   * chunks are packed into large arenas (one BufferGeometry per ~4M vertices)
//     and drawn with ONE call each, instead of one Mesh per chunk. A 8,236-chunk
//     city stream drops from 8,236 draw calls to 3, which is the difference
//     between a slideshow and an interactive view;
//   * freed ranges are reused, and an arena is compacted (in-place copyWithin)
//     once fragmentation exceeds 50 %, so a stream full of CHUNK_REPLACE events
//     does not grow without bound;
//   * a byte budget is enforced on the viewer side too: when resident geometry
//     passes it, the oldest chunks are released. This is defence in depth for
//     the native governor (which uses a header-only cost estimate).
//
// Textured chunks are promoted out of the arena into their own mesh on the first
// TEXTURE_UPDATE for that chunk; texture projection is the same as main.js.
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

const cfg = Object.assign({
  budgetMB: 2048, arenaVertices: 4000000, wireframe: false, grid: true,
  hud: true, pixelRatio: 2, textureQuality: 1, telemetryHz: 4,
  autoReconnect: true, reconnectAttempts: 3,
  // Frame-complete presentation: packets are buffered and applied inside the
  // render tick, so a presented frame is always the full scene state at a
  // packet boundary. 'immediate' restores the research-kit behaviour (apply on
  // arrival, render whatever exists at rAF time).
  presentation: 'frameComplete', applyBudgetMs: 6,
}, window.__s3dvConfig || {});
const FRAME_MODE_DEFAULT = cfg.presentation !== 'immediate';
const APPLY_BUDGET_DEFAULT = Math.min(50, Math.max(1, Number(cfg.applyBudgetMs) || 6));
// Live overrides (applyConfig) let settings change without a page reload.
let frameMode = FRAME_MODE_DEFAULT;
let applyBudgetMs = APPLY_BUDGET_DEFAULT;

const $ = (id) => document.getElementById(id);
const set = (id, text) => { const e = $(id); if (e) e.textContent = text; };
// Bilingual status labels: Japanese is the source language; English is used
// when the browser/user locale is English.
const IS_EN = /^en/i.test(navigator.language || '');
const t = (jp, en) => IS_EN ? en : jp;

// Status-bar text localization map (Japanese key → English value). Prefix
// matching handles dynamic suffixes (e.g. "シーク中 → 12.345 s").
const STATUS_EN = {
  '接続中…': 'Connecting…',
  '接続済み': 'Connected',
  '一時停止': 'Paused',
  '完了': 'Finished',
  '通信エラー': 'Communication error',
  '切断': 'Disconnected',
  '切断 — 再接続': 'Disconnected — reconnecting',
  'シーク中 → ': 'Seeking → ',
  'デコードエラー: ': 'Decode error: ',
  '描画エラー: ': 'Render error: ',
};
function localizeStatus(text) {
  if (!IS_EN) return text;
  for (const [jp, en] of Object.entries(STATUS_EN)) {
    if (text.startsWith(jp)) return en + text.slice(jp.length);
  }
  return STATUS_EN[text] ?? text;
}

// ---------------------------------------------------------------- scene
const stage = $('stage');
const scene = new THREE.Scene();
scene.background = new THREE.Color(0x0b1119);
const grid = new THREE.GridHelper(8, 16, 0x3c5a7d, 0x1b2a3a);
grid.rotateX(Math.PI / 2);
grid.visible = !!cfg.grid;
scene.add(grid);
const key = new THREE.DirectionalLight(0xffffff, 1.55);
key.position.set(4, 3, 8);
scene.add(key);
const fill = new THREE.DirectionalLight(0x9dc4ff, 0.45);
fill.position.set(-6, -4, 2);
scene.add(fill);
// Sky/ground hemisphere keeps large city models readable without washing out
// the vertex colours (which are already sRGB from the capture).
scene.add(new THREE.HemisphereLight(0xbfd4ee, 0x2a3442, 0.7));
scene.add(new THREE.AmbientLight(0xffffff, 1.0));

const camera = new THREE.PerspectiveCamera(56, 1, 0.05, 5000);
camera.up.set(0, 0, 1);
camera.position.set(4, -5, 3);

const renderer = new THREE.WebGLRenderer({ antialias: true, powerPreference: 'high-performance' });
renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, Math.max(1, cfg.pixelRatio)));
stage.insertBefore(renderer.domElement, stage.firstChild);

const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
controls.dampingFactor = 0.08;
controls.target.set(0, 0, 0);
controls.addEventListener('start', () => { userMovedCamera = true; });

function resize() {
  const w = stage.clientWidth || 1, h = stage.clientHeight || 1;
  renderer.setSize(w, h);
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
}
addEventListener('resize', resize);
resize();

// ---------------------------------------------------------------- state
let wire = !!cfg.wireframe;
let packets = 0, bytes = 0;
let appliedNs = 0;
let durationNs = null;
let paused = false, stepArmed = false, pending = [], needsResync = false;
let expectedSequence = null, decoderFailed = false;
let connState = '接続中…';
let seekRequest = null;
let ws = null, reconnectTries = 0, reconnectTimer = null;
let bufferedBytes = 0;
let evictedCount = 0, promoteCount = 0;

// Frame-complete presentation state. Validated packets wait in `inbox` and are
// applied inside the render tick, never mid-tick from the socket handler, so
// everything the presenter shows is a whole packet-boundary state.
let inbox = [], inboxHead = 0, inboxBytes = 0;
let dirty = true;                 // scene changed since the last present
let presentedFrames = 0;          // frames actually rendered by the presenter
let changedPackets = 0;           // applied packets that mutated the scene

const chunks = new Map();        // id -> record
const tombstones = new Map();    // id -> highest removed revision
const textures = new Map();      // id -> {rev, P, crop, bitmap}
const arenas = [];

// Arena capacity: never smaller than one protocol chunk, never larger than the
// configured cap, and sized from the recording's own vertex count so a 1,557
// triangle demo does not allocate a 224 MB arena.
const ARENA_CAP_V = Math.max(262144, Math.min(
  Math.max(500000, cfg.arenaVertices | 0),
  Math.ceil((cfg.expectedVertices | 0) / 3) || 262144));
// Live estimate per resident vertex (pos+col+nrm floats + 2 indices) and the
// real allocation per vertex of capacity (the index buffer is sized at 5x the
// vertex capacity, which is what this data's 5.6 indices/vertex needs).
const ARENA_BYTES_PER_V = 12 * 3 + 4 * 2;
const ARENA_INDEX_PER_V = 5;
const ARENA_ALLOC_PER_V = 12 * 3 + 4 * ARENA_INDEX_PER_V;
const budgetBytes = Math.max(0, (cfg.budgetMB | 0) * 1048576);
// Ceiling for packets waiting to be applied. Applied state lives in the GPU
// scene anyway, so the inbox must never add a second copy of the whole stream:
// past the cap the oldest packets are applied synchronously (still in order,
// still whole) to keep the buffer bounded.
const INBOX_BYTES_CAP = Math.max(96 * 1048576,
  budgetBytes ? Math.round(budgetBytes / 8) : 256 * 1048576);
// noRender / hidden pages present nothing, so pacing the apply would only
// stall the stream (hidden rAF runs at ~1 Hz): those states apply on arrival
// like the research kit does, and present when they become visible.
const noRenderActive = !!cfg.noRender;
// When the native engine enforces a budget, the viewer only honours explicit
// trim requests: two independent eviction policies fought each other and the
// viewer dropped chunks the engine had just admitted.
const nativeBudgetActive = (cfg.budgetMB | 0) > 0;

// ---------------------------------------------------------------- arena
class Arena {
  constructor(capV) {
    this.capV = capV;
    this.capI = capV * ARENA_INDEX_PER_V;
    this.pos = new Float32Array(capV * 3);
    this.col = new Float32Array(capV * 3);
    this.nrm = new Float32Array(capV * 3);
    this.idx = new Uint32Array(this.capI);
    const g = new THREE.BufferGeometry();
    this.posAttr = new THREE.BufferAttribute(this.pos, 3).setUsage(THREE.DynamicDrawUsage);
    this.colAttr = new THREE.BufferAttribute(this.col, 3).setUsage(THREE.DynamicDrawUsage);
    this.nrmAttr = new THREE.BufferAttribute(this.nrm, 3).setUsage(THREE.DynamicDrawUsage);
    this.idxAttr = new THREE.BufferAttribute(this.idx, 1).setUsage(THREE.DynamicDrawUsage);
    g.setAttribute('position', this.posAttr);
    g.setAttribute('color', this.colAttr);
    g.setAttribute('normal', this.nrmAttr);
    g.setIndex(this.idxAttr);
    g.setDrawRange(0, 0);
    this.geo = g;
    this.mat = new THREE.MeshStandardMaterial({
      vertexColors: true, roughness: 0.88, metalness: 0, side: THREE.DoubleSide, wireframe: wire,
    });
    this.mesh = new THREE.Mesh(g, this.mat);
    this.mesh.frustumCulled = false;
    scene.add(this.mesh);
    this.usedV = 0; this.usedI = 0;
    this.liveV = 0; this.liveI = 0;
    this.freeV = []; this.freeI = [];
  }

  get bytes() { return this.capV * 12 * 3 + this.capI * 4; }

  allocV(n) {
    // first fit
    for (let i = 0; i < this.freeV.length; i++) {
      const r = this.freeV[i];
      if (r.len >= n) {
        const off = r.off;
        if (r.len === n) this.freeV.splice(i, 1);
        else { r.off += n; r.len -= n; }
        return off;
      }
    }
    if (this.usedV + n > this.capV) return -1;
    const off = this.usedV;
    this.usedV += n;
    return off;
  }

  allocI(n) {
    for (let i = 0; i < this.freeI.length; i++) {
      const r = this.freeI[i];
      if (r.len >= n) {
        const off = r.off;
        if (r.len === n) this.freeI.splice(i, 1);
        else { r.off += n; r.len -= n; }
        return off;
      }
    }
    if (this.usedI + n > this.capI) return -1;
    const off = this.usedI;
    this.usedI += n;
    return off;
  }

  releaseV(off, len) { insertRange(this.freeV, off, len); this.liveV -= len; }
  releaseI(off, len) { insertRange(this.freeI, off, len); this.liveI -= len; }

  // Only the touched ranges are re-uploaded; a whole-arena upload per packet
  // would copy tens of megabytes to the GPU for every chunk.
  markV(off, len) {
    this.posAttr.addUpdateRange(off * 3, len * 3);
    this.colAttr.addUpdateRange(off * 3, len * 3);
    this.nrmAttr.addUpdateRange(off * 3, len * 3);
    this.posAttr.needsUpdate = true;
    this.colAttr.needsUpdate = true;
    this.nrmAttr.needsUpdate = true;
    this.geo.setDrawRange(0, this.usedI);
  }

  markI(off, len) {
    this.idxAttr.addUpdateRange(off, len);
    this.idxAttr.needsUpdate = true;
    this.geo.setDrawRange(0, this.usedI);
  }

  markAll() { this.markV(0, this.usedV); this.markI(0, this.usedI); }

  dispose() {
    scene.remove(this.mesh);
    this.geo.dispose();
    this.mat.dispose();
  }
}

function insertRange(list, off, len) {
  let i = 0;
  while (i < list.length && list[i].off < off) i++;
  list.splice(i, 0, { off, len });
  // coalesce neighbours so the free lists stay short
  for (let k = list.length - 1; k > 0; k--) {
    const a = list[k - 1], b = list[k];
    if (a.off + a.len === b.off) { a.len += b.len; list.splice(k, 1); }
  }
}

function reserve(nv, ni) {
  for (const a of arenas) {
    const v = a.allocV(nv);
    if (v < 0) continue;
    const i = a.allocI(ni);
    if (i >= 0) return { arena: a, vOff: v, iOff: i };
    a.freeV.push({ off: v, len: nv });   // roll the vertex take back (tail range)
    mergeFree(a.freeV);
  }
  const a = new Arena(ARENA_CAP_V);
  const v = a.allocV(nv), i = a.allocI(ni);
  if (v < 0 || i < 0) { a.dispose(); throw Error('Chunk larger than an arena'); }
  arenas.push(a);
  return { arena: a, vOff: v, iOff: i };
}

// ---------------------------------------------------------------- decode
const isLE = new Uint8Array(new Uint32Array([1]).buffer)[0] === 1;
const QUANT_MARKER = 0xFFFFFFFF;

function parseMesh(payload) {
  const d = new DataView(payload);
  if (d.byteLength < 8) throw Error('Mesh header too small');
  if (d.getUint32(0, true) !== QUANT_MARKER) {
    const n = d.getUint32(0, true), ni = d.getUint32(4, true);
    if (n > 400000 || ni > 1200000 || ni % 3 || payload.byteLength !== 8 + 12 * n + 4 * ni + 3 * n)
      throw Error('Invalid mesh sizes');
    const position = new Float32Array(n * 3), index = new Uint32Array(ni), rawcolors = new Uint8Array(n * 3);
    const p0 = 8, p1 = p0 + 12 * n, p2 = p1 + 4 * ni;
    if (isLE) {
      position.set(new Float32Array(payload.slice(p0, p1)));
      if (ni) index.set(new Uint32Array(payload.slice(p1, p2)));
      rawcolors.set(new Uint8Array(payload.slice(p2)));
    } else {
      for (let i = 0; i < n * 3; i++) position[i] = d.getFloat32(p0 + 4 * i, true);
      for (let i = 0; i < ni; i++) index[i] = d.getUint32(p1 + 4 * i, true);
      rawcolors.set(new Uint8Array(payload.slice(p2)), 0, n * 3);
    }
    return { n, ni, position, index, rawcolors };
  }
  if (d.byteLength < 44) throw Error('Quant header too small');
  const codec = d.getUint32(4, true), n = d.getUint32(8, true);
  if (codec !== 1 || n === 0 || n > 400000) throw Error('Invalid quant header');
  if (d.getUint16(38, true) !== 0 || d.getUint16(40, true) !== 0) throw Error('Invalid quant reserved');
  const indexBits = d.getUint16(36, true);
  if (indexBits !== 32 && indexBits !== 16) throw Error('Invalid quant index bits');
  if (indexBits === 16 && n >= 65536) throw Error('Quant index width too small');
  const origin = [d.getFloat32(12, true), d.getFloat32(16, true), d.getFloat32(20, true)];
  const extent = [d.getFloat32(24, true), d.getFloat32(28, true), d.getFloat32(32, true)];
  const dataOff = 44, isz = indexBits === 32 ? 4 : 2;
  const rest = payload.byteLength - dataOff - 6 * n - 3 * n;
  if (rest < 0 || rest % isz !== 0) throw Error('Quant payload length mismatch');
  const ni = rest / isz;
  if (ni % 3) throw Error('Invalid quant index count');
  const position = new Float32Array(n * 3), index = new Uint32Array(ni), rawcolors = new Uint8Array(n * 3);
  for (let i = 0; i < n * 3; i++) {
    const q = d.getUint16(dataOff + 2 * i, true);
    position[i] = origin[i % 3] + (q / 65535) * extent[i % 3];
  }
  const idxOff = dataOff + 6 * n;
  for (let i = 0; i < ni; i++) index[i] = indexBits === 32 ? d.getUint32(idxOff + 4 * i, true) : d.getUint16(idxOff + 2 * i, true);
  rawcolors.set(new Uint8Array(payload.slice(idxOff + isz * ni, idxOff + isz * ni + 3 * n)));
  return { n, ni, position, index, rawcolors };
}

// Scratch buffers reused across chunks: avoids one 100 KB allocation per packet.
let scratchN = new Float32Array(0);
function normalsFor(n) {
  if (scratchN.length < n * 3) scratchN = new Float32Array(Math.max(n * 3, scratchN.length * 2));
  return scratchN;
}

const srgbToLinear = (c) => (c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));

// Scene bounds drive the initial camera fit, the grid scale and the far plane.
const bounds = { min: [Infinity, Infinity, Infinity], max: [-Infinity, -Infinity, -Infinity], valid: false };

function growBounds(position, n) {
  for (let i = 0; i < n * 3; i += 3) {
    const x = position[i], y = position[i + 1], z = position[i + 2];
    if (x < bounds.min[0]) bounds.min[0] = x;
    if (y < bounds.min[1]) bounds.min[1] = y;
    if (z < bounds.min[2]) bounds.min[2] = z;
    if (x > bounds.max[0]) bounds.max[0] = x;
    if (y > bounds.max[1]) bounds.max[1] = y;
    if (z > bounds.max[2]) bounds.max[2] = z;
    bounds.valid = true;
  }
}

let userMovedCamera = false;
let lastFitRadius = 0;

function fitView(force) {
  if (!bounds.valid) return;
  const cx = (bounds.min[0] + bounds.max[0]) / 2;
  const cy = (bounds.min[1] + bounds.max[1]) / 2;
  const cz = (bounds.min[2] + bounds.max[2]) / 2;
  const sx = bounds.max[0] - bounds.min[0];
  const sy = bounds.max[1] - bounds.min[1];
  const sz = bounds.max[2] - bounds.min[2];
  const radius = Math.max(Math.hypot(sx, sy, sz) * 0.5, 0.25);
  // Re-fit while the stream fills in, but never yank the camera once the user
  // has touched it — unless they explicitly asked to reset.
  if (!force && userMovedCamera) return;
  if (!force && lastFitRadius > 0 && radius < lastFitRadius * 1.25) return;
  lastFitRadius = radius;

  const fov = THREE.MathUtils.degToRad(camera.fov);
  const distance = (radius / Math.sin(fov * 0.5)) * 1.05;
  const dir = new THREE.Vector3(0.55, -0.78, 0.42).normalize();
  controls.target.set(cx, cy, cz);
  camera.position.set(cx + dir.x * distance, cy + dir.y * distance, cz + dir.z * distance);
  camera.near = Math.max(0.01, radius / 2000);
  camera.far = radius * 40;
  camera.updateProjectionMatrix();
  controls.update();
  dirty = true;   // the camera jumped; the presenter must show the new view

  // One grid square ~ 1/8 of the scene, sitting on the model's floor.
  const span = Math.max(sx, sy, 1);
  grid.visible = !!cfg.grid;
  grid.position.set(cx, cy, bounds.min[2]);
  grid.scale.setScalar(Math.max(span / 8, 0.001));
}

// ---------------------------------------------------------------- chunk io
function insertChunk(id, rev, payload) {
  const { n, ni, position, index, rawcolors } = parseMesh(payload);
  for (let i = 0; i < ni; i++) if (index[i] >= n) throw Error('Index out of range');
  for (let i = 0; i < position.length; i++) if (!Number.isFinite(position[i])) throw Error('Non-finite geometry');

  // face-weighted vertex normals, computed once per chunk
  const nrm = normalsFor(n);
  for (let i = 0; i < n * 3; i++) nrm[i] = 0;
  for (let t = 0; t < ni; t += 3) {
    const a = index[t] * 3, b = index[t + 1] * 3, c = index[t + 2] * 3;
    const ux = position[b] - position[a], uy = position[b + 1] - position[a + 1], uz = position[b + 2] - position[a + 2];
    const vx = position[c] - position[a], vy = position[c + 1] - position[a + 1], vz = position[c + 2] - position[a + 2];
    const nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
    nrm[a] += nx; nrm[a + 1] += ny; nrm[a + 2] += nz;
    nrm[b] += nx; nrm[b + 1] += ny; nrm[b + 2] += nz;
    nrm[c] += nx; nrm[c + 1] += ny; nrm[c + 2] += nz;
  }
  for (let i = 0; i < n * 3; i += 3) {
    const x = nrm[i], y = nrm[i + 1], z = nrm[i + 2];
    const len = Math.hypot(x, y, z) || 1;
    nrm[i] = x / len; nrm[i + 1] = y / len; nrm[i + 2] = z / len;
  }

  growBounds(position, n);
  const slot = reserve(n, ni);
  const arena = slot.arena, vOff = slot.vOff, iOff = slot.iOff;

  arena.pos.set(position, vOff * 3);
  for (let i = 0, j = vOff * 3; i < n * 3; i++, j++) arena.col[j] = srgbToLinear(rawcolors[i] / 255);
  arena.nrm.set(nrm.subarray(0, n * 3), vOff * 3);
  for (let i = 0; i < ni; i++) arena.idx[iOff + i] = index[i] + vOff;
  arena.liveV += n; arena.liveI += ni;
  arena.markV(vOff, n); arena.markI(iOff, ni);

  chunks.set(id, { arena, vOff, vCount: n, iOff, iCount: ni, rev });
  liveTris += ni / 3;
  dirty = true;
  updateHud();
}

function removeChunk(id) {
  const rec = chunks.get(id);
  if (!rec) return;
  chunks.delete(id);
  if (rec.standalone) {
    scene.remove(rec.mesh);
    if (rec.mesh.material.map) rec.mesh.material.map.dispose();
    rec.mesh.geometry.dispose();
    rec.mesh.material.dispose();
  } else if (rec.arena) {
    // degenerate the freed triangles so nothing stale is drawn
    const a = rec.arena;
    for (let i = rec.iOff; i < rec.iOff + rec.iCount; i++) a.idx[i] = 0;
    a.markI(rec.iOff, rec.iCount);
    a.releaseV(rec.vOff, rec.vCount);   // releaseV/releaseI also file the range
    a.releaseI(rec.iOff, rec.iCount);
  }
  liveTris -= rec.iCount / 3;
  if (rec.standalone) standaloneBytes -= rec.vCount * 40 + rec.iCount * 4;
  const tex = textures.get(id);
  if (tex) {
    if (tex.bitmap) tex.bitmap.close();
    textures.delete(id);
  }
  dirty = true;
  updateHud();
}

function mergeFree(list) {
  list.sort((x, y) => x.off - y.off);
  for (let i = list.length - 1; i > 0; i--) {
    const a = list[i - 1], b = list[i];
    if (a.off + a.len === b.off) { a.len += b.len; list.splice(i, 1); }
  }
}

/** Compact one arena when more than half of its resident vertices are dead space. */
function maybeCompact() {
  for (const a of arenas) {
    if (a.liveV === 0) { a.freeV = []; a.usedV = 0; a.freeI = []; a.usedI = 0; a.geo.setDrawRange(0, 0); continue; }
    if (a.usedV < a.liveV * 1.6 + 4096) continue;
    const live = [];
    for (const rec of chunks.values()) if (!rec.standalone && rec.arena === a) live.push(rec);
    live.sort((x, y) => x.vOff - y.vOff);
    let wv = 0;
    for (const rec of live) {
      if (rec.vOff !== wv) {
        a.pos.copyWithin(wv * 3, rec.vOff * 3, (rec.vOff + rec.vCount) * 3);
        a.col.copyWithin(wv * 3, rec.vOff * 3, (rec.vOff + rec.vCount) * 3);
        a.nrm.copyWithin(wv * 3, rec.vOff * 3, (rec.vOff + rec.vCount) * 3);
      }
      rec.newVOff = wv;
      wv += rec.vCount;
    }
    let wi = 0;
    live.sort((x, y) => x.iOff - y.iOff);
    for (const rec of live) {
      const delta = rec.newVOff - rec.vOff;
      if (rec.iOff !== wi) a.idx.copyWithin(wi, rec.iOff, rec.iOff + rec.iCount);
      if (delta) for (let i = wi; i < wi + rec.iCount; i++) a.idx[i] += delta;
      rec.vOff = rec.newVOff;
      rec.iOff = wi;
      wi += rec.iCount;
    }
    a.usedV = wv; a.usedI = wi;
    a.freeV = []; a.freeI = [];
    a.markAll();
  }
}

// ---------------------------------------------------------------- textures
function checkTexture(payload) {
  const d = new DataView(payload);
  if (payload.byteLength < 128) throw Error('Texture header too small');
  if (d.getUint8(0) !== 1 || d.getUint8(1) || d.getUint8(2) || d.getUint8(3)) throw Error('Unknown texture codec');
  const w = d.getUint32(4, true), h = d.getUint32(8, true), pngBytes = d.getUint32(124, true);
  if (w < 1 || w > 4096 || h < 1 || h > 4096) throw Error('Invalid texture dimensions');
  if (payload.byteLength !== 128 + pngBytes) throw Error('Invalid texture payload length');
  const P = new Float64Array(12);
  for (let i = 0; i < 12; i++) { P[i] = d.getFloat64(12 + 8 * i, true); if (!Number.isFinite(P[i])) throw Error('Non-finite texture projection'); }
  const crop = [d.getUint32(108, true), d.getUint32(112, true), d.getUint32(116, true), d.getUint32(120, true)];
  if (crop[2] !== w || crop[3] !== h) throw Error('Texture crop mismatch');
  if (pngBytes < 8) throw Error('PNG stream too small');
  const png = new Uint8Array(payload, 128);
  for (let i = 0; i < 8; i++) if (png[i] !== [137, 80, 78, 71, 13, 10, 26, 10][i]) throw Error('Not a PNG stream');
  if (d.getUint32(136, false) !== 13 || d.getUint8(140) !== 73 || d.getUint8(141) !== 72 ||
      d.getUint8(142) !== 68 || d.getUint8(143) !== 82 ||
      d.getUint32(144, false) !== w || d.getUint32(148, false) !== h) throw Error('PNG dimensions mismatch');
  if (d.getUint8(152) !== 8 || d.getUint8(153) !== 2 || d.getUint8(156) !== 0)
    throw Error('Unsupported PNG IHDR');
  return { P, crop, pngBytes };
}

function uvFor(P, crop, positions) {
  const uv = new Float32Array(positions.length / 3 * 2);
  for (let i = 0, j = 0; i < positions.length; i += 3, j += 2) {
    let u = 0, v = 0;
    const z = P[8] * positions[i] + P[9] * positions[i + 1] + P[10] * positions[i + 2] + P[11];
    if (z > 0) {
      u = (P[0] * positions[i] + P[1] * positions[i + 1] + P[2] * positions[i + 2] + P[3]) / z;
      v = (P[4] * positions[i] + P[5] * positions[i + 1] + P[6] * positions[i + 2] + P[7]) / z;
      u = (u - crop[0]) / crop[2];
      v = (v - crop[1]) / crop[3];
      if (!Number.isFinite(u) || !Number.isFinite(v)) { u = 0; v = 0; }
    }
    uv[j] = u; uv[j + 1] = v;
  }
  return uv;
}

function bitmapTexture(bitmap) {
  const t = new THREE.Texture(bitmap);
  t.colorSpace = THREE.SRGBColorSpace;
  t.wrapS = t.wrapT = THREE.ClampToEdgeWrapping;
  t.magFilter = t.minFilter = THREE.NearestFilter;
  t.generateMipmaps = false;
  t.needsUpdate = true;
  return t;
}

/** Moves an arena-resident chunk into its own textured mesh (first op6 for it). */
function promoteToTextured(id, tex) {
  const rec = chunks.get(id);
  if (!rec || rec.standalone) return;
  const a = rec.arena;
  if (!a) return;
  const n = rec.vCount, ni = rec.iCount;
  const position = new Float32Array(n * 3), color = new Float32Array(n * 3), normal = new Float32Array(n * 3);
  position.set(a.pos.subarray(rec.vOff * 3, (rec.vOff + n) * 3));
  color.set(a.col.subarray(rec.vOff * 3, (rec.vOff + n) * 3));
  normal.set(a.nrm.subarray(rec.vOff * 3, (rec.vOff + n) * 3));
  const index = new Uint32Array(ni);
  for (let i = 0; i < ni; i++) index[i] = a.idx[rec.iOff + i] - rec.vOff;

  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.BufferAttribute(position, 3));
  geo.setAttribute('color', new THREE.BufferAttribute(color, 3));
  geo.setAttribute('normal', new THREE.BufferAttribute(normal, 3));
  geo.setIndex(new THREE.BufferAttribute(index, 1));
  geo.setAttribute('uv', new THREE.BufferAttribute(uvFor(tex.P, tex.crop, position), 2));
  const mat = new THREE.MeshStandardMaterial({
    map: bitmapTexture(tex.bitmap), roughness: 0.88, metalness: 0, side: THREE.DoubleSide, wireframe: wire,
  });
  const mesh = new THREE.Mesh(geo, mat);
  scene.add(mesh);

  for (let i = rec.iOff; i < rec.iOff + ni; i++) a.idx[i] = 0;
  a.markI(rec.iOff, ni);
  a.releaseV(rec.vOff, n);
  a.releaseI(rec.iOff, ni);

  standaloneBytes += n * 40 + ni * 4;
  chunks.set(id, { standalone: true, mesh, vCount: n, iCount: ni, rev: rec.rev });
  promoteCount++;
  dirty = true;
  updateHud();
}

function applyTexture(id, rev, payload, parsed) {
  if (rev <= (textures.get(id)?.rev ?? -1)) return false;
  const tex = { rev, P: parsed.P, crop: parsed.crop, bitmap: null };
  const prev = textures.get(id);
  if (prev && prev.bitmap) prev.bitmap.close();
  textures.set(id, tex);
  dirty = true;   // the projection record changed even before the bitmap lands
  // textureQuality < 1 asks the decoder for a smaller bitmap, which is the only
  // place the reduction is free (no extra downscale pass, less GPU memory).
  const q = Number(cfg.textureQuality);
  const decodeOptions = { colorSpaceConversion: 'none' };
  if (Number.isFinite(q) && q > 0.05 && q < 0.999) {
    decodeOptions.resizeWidth = Math.max(1, Math.round(tex.crop[2] * q));
    decodeOptions.resizeHeight = Math.max(1, Math.round(tex.crop[3] * q));
    decodeOptions.resizeQuality = 'low';
  }
  createImageBitmap(new Blob([payload.slice(128)], { type: 'image/png' }), decodeOptions)
    .then((bitmap) => {
      if (textures.get(id) !== tex) { bitmap.close(); return; }
      tex.bitmap = bitmap;
      const rec = chunks.get(id);
      if (rec && rec.rev === rev) promoteToTextured(id, tex);
      dirty = true;   // textured view is ready; the presenter shows it whole
      updateHud();
    })
    .catch((err) => { if (textures.get(id) === tex) textures.delete(id); protect(err instanceof Error ? err : Error('PNG decode failed')); });
  return true;
}

// ---------------------------------------------------------------- hud
let liveTris = 0;
let standaloneBytes = 0;

/// Live geometry (drops when ranges are released) — what the budget compares.
function residentBytes() {
  let b = standaloneBytes;
  for (const a of arenas) b += a.liveV * ARENA_BYTES_PER_V;
  return b;
}

/// Actually allocated GPU buffers, which is what the process really holds.
function allocatedBytes() {
  let b = standaloneBytes;
  for (const a of arenas) b += a.bytes;
  return b;
}

function triangles() { return liveTris; }

function updateHud() {
  set('chunks', chunks.size.toLocaleString());
  set('triangles', Math.round(liveTris).toLocaleString());
  set('mem_mb', (allocatedBytes() / 1048576).toFixed(0));
  set('tex', String(textures.size));
}

// ---------------------------------------------------------------- budget
function enforceBudget(force) {
  if (!budgetBytes) return;
  if (residentBytes() <= budgetBytes) return;
  const target = budgetBytes * (force ? 0.92 : 1.0);
  // Release oldest-inserted chunks first; Map iteration order is insertion order.
  while (residentBytes() > target && chunks.size > 0) {
    const first = chunks.keys().next();
    if (first.done) break;
    const id = first.value;
    const rec = chunks.get(id);
    const rev = rec?.rev ?? 0;
    removeChunk(id);
    tombstones.set(id, rev);
    evictedCount++;
    if (evictedCount % 256 === 0) maybeCompact();
  }
  maybeCompact();
  updateHud();
}

// ---------------------------------------------------------------- protocol
const crcTable = new Uint32Array(256);
for (let k = 0; k < 256; k++) {
  let x = k;
  for (let j = 0; j < 8; j++) x = (x & 1) ? (0xEDB88320 ^ (x >>> 1)) : (x >>> 1);
  crcTable[k] = x >>> 0;
}
function crc32(buf, count) {
  let crc = 0xFFFFFFFF;
  const bytes = new Uint8Array(buf, 0, count);
  for (const b of bytes) crc = crcTable[(crc ^ b) & 255] ^ (crc >>> 8);
  return (crc ^ 0xFFFFFFFF) >>> 0;
}

const names = { 1: 'HELLO', 2: 'SNAPSHOT_BEGIN', 3: 'CHUNK_ADD', 4: 'CHUNK_REPLACE', 5: 'CHUNK_REMOVE', 6: 'TEXTURE_UPDATE', 7: 'SNAPSHOT_END', 8: 'STATS', 9: 'RESYNC_REQUEST', 10: 'HEARTBEAT' };
const PENDING_CAP = 20000;

function status(text, kind) {
  set('status', localizeStatus(text));
  const bar = $('statusbar');
  if (bar) bar.className = kind || '';
}

function setStatusFromState() {
  if (decoderFailed) return;
  if (seekRequest !== null) status(`シーク中 → ${seekRequest.toFixed(3)} s`, 'warn');
  else if (paused) status('一時停止', 'warn');
  else status(connState, connState === '接続済み' ? '' : 'warn');
}

function clearScene() {
  for (const rec of chunks.values()) {
    if (rec.standalone) {
      scene.remove(rec.mesh);
      if (rec.mesh.material.map) rec.mesh.material.map.dispose();
      rec.mesh.geometry.dispose();
      rec.mesh.material.dispose();
    }
  }
  chunks.clear();
  for (const t of textures.values()) if (t.bitmap) t.bitmap.close();
  textures.clear();
  tombstones.clear();
  while (arenas.length) { arenas.pop().dispose(); }
  liveTris = 0;
  standaloneBytes = 0;
  bounds.min = [Infinity, Infinity, Infinity];
  bounds.max = [-Infinity, -Infinity, -Infinity];
  bounds.valid = false;
  lastFitRadius = 0;
  maybeCompact();
  dirty = true;
  updateHud();
}

function ingest(buf) {
  const d = new DataView(buf);
  if (d.byteLength < 48) throw Error('Short packet');
  if (String.fromCharCode(...new Uint8Array(buf, 0, 4)) !== 'S3DP' || d.getUint8(4) !== 1) throw Error('Packet magic/version');
  const op = d.getUint8(5), flags = d.getUint16(6, true);
  const sequence = d.getBigUint64(16, true), chunk = d.getBigUint64(24, true).toString();
  const rev = d.getUint32(32, true), size = d.getUint32(36, true);
  if ((flags & ~1) !== 0 || size > 16 * 1024 * 1024 || buf.byteLength !== 48 + size + ((flags & 1) ? 4 : 0)) throw Error('Packet bounds');
  if ((flags & 1) && crc32(buf, 48 + size) !== d.getUint32(48 + size, true)) throw Error('CRC mismatch');
  if (op < 1 || op > 10) throw Error('Unknown op ' + op);
  if (op === 2) { expectedSequence = sequence; seekRequest = null; }
  else if (expectedSequence !== null && sequence !== expectedSequence) throw Error('Sequence gap');
  const payload = buf.slice(48, 48 + size);
  let texd = null;
  if (op === 6) {
    if (chunk === '0') throw Error('Texture chunk must be positive');
    texd = checkTexture(payload);
  }
  return { op, sequence, chunk, rev, payload, ts: Number(d.getBigUint64(40, true)), tex: texd };
}

function protect(err) {
  connState = 'デコードエラー: ' + err.message;
  decoderFailed = true;
  status(connState, 'err');
  try { if (ws) ws.close(); } catch (_) {}
}

function applyPacket(p) {
  let changed = true;
  if (p.op === 2) {
    changed = chunks.size > 0 || arenas.length > 0 || textures.size > 0 || tombstones.size > 0;
    clearScene();
  }
  else if (p.op === 3 || p.op === 4) {
    const tomb = tombstones.get(p.chunk) ?? -1;
    const cur = chunks.get(p.chunk);
    if (p.rev <= Math.max(cur?.rev ?? -1, tomb)) return false;
    // A CHUNK_REPLACE supersedes the previous revision: free its arena ranges
    // first, otherwise the old triangles stay on screen and the arena grows
    // with every replace event (a 244 MB stream leaked 47 % extra geometry).
    if (cur) removeChunk(p.chunk);
    insertChunk(p.chunk, p.rev, p.payload);
    if (!nativeBudgetActive) enforceBudget(false);
  } else if (p.op === 5) {
    if (p.payload.byteLength) throw Error('Remove payload must be empty');
    const cur = chunks.get(p.chunk);
    if (p.rev <= Math.max(cur?.rev ?? -1, tombstones.get(p.chunk) ?? -1)) return false;
    removeChunk(p.chunk);
    tombstones.set(p.chunk, p.rev);
  } else if (p.op === 6) changed = applyTexture(p.chunk, p.rev, p.payload, p.tex);
  appliedNs = p.ts;
  set('time', (appliedNs / 1e9).toFixed(3) + ' s');
  if (p.op === 2) seekRequest = null;
  if (p.op === 7) fitView(false);
  setStatusFromState();
  return changed;
}

function applyTimed(p) {
  const changed = applyPacket(p);
  if (changed) changedPackets++;
  return changed;
}

/// Pops the next queued packet (or null). Keeps the ring compact so long
/// replays don't pay an O(n) shift per packet.
function takeInbox() {
  if (inboxHead >= inbox.length) return null;
  const p = inbox[inboxHead++];
  inboxBytes -= p.payload.byteLength + 48;
  if (inboxHead >= inbox.length) { inbox = []; inboxHead = 0; }
  else if (inboxHead > 4096) { inbox = inbox.slice(inboxHead); inboxHead = 0; }
  return p;
}

/// Applies queued packets in arrival order until the time budget runs out.
/// Returns how many packets were consumed. Every exit point is a packet
/// boundary, so the caller can present right after this and still be complete.
function drainInbox(budgetEnd) {
  let applied = 0;
  while (inboxHead < inbox.length) {
    if (budgetEnd !== Infinity && applied > 0 && performance.now() >= budgetEnd) break;
    const p = takeInbox();
    try { applyTimed(p); }
    catch (err) {
      // The packet is poisoned (sequence cannot continue past a bad frame):
      // drop the queue and surface the failure the same way onMessage would.
      inbox = []; inboxHead = 0; inboxBytes = 0;
      protect(err);
      return applied;
    }
    applied++;
  }
  return applied;
}

function onMessage(event) {
  try {
    if (typeof event.data === 'string') { control(event.data); return; }
    const p = ingest(event.data);
    expectedSequence = p.sequence + 1n;
    packets++;
    bytes += event.data.byteLength;
    set('packets', packets.toLocaleString());
    set('bytes', (bytes / 1024).toFixed(1) + ' KB');
    set('op', names[p.op] || ('Unknown op ' + p.op));
    if (p.op === 2) {
      // A snapshot re-anchors the timeline: queued packets from before it are
      // from a different state and must never be applied after the clear.
      pending = [];
      inbox = []; inboxHead = 0; inboxBytes = 0;
      dirty = true;
      setStatusFromState();
    }
    if (paused) {
      if (stepArmed) { stepArmed = false; applyTimed(p); return; }
      if (pending.length >= PENDING_CAP) { needsResync = true; return; }
      pending.push(p);
      return;
    }
    if (frameMode && !noRenderActive && !document.hidden) {
      // Buffer for the presenter. Past the byte cap the oldest packets are
      // applied right here (still whole, still in order) so the inbox never
      // becomes a second copy of the stream in JS memory. The catch-up is
      // bounded (32 ms) so a huge burst cannot hitch the page for seconds.
      inbox.push(p); inboxBytes += event.data.byteLength;
      if (inboxBytes > INBOX_BYTES_CAP) drainInbox(performance.now() + 32);
    } else {
      // Immediate mode, or a page that presents nothing (noRender / hidden
      // window): apply on arrival like the research kit. Pacing a hidden page
      // is pointless — WebKit throttles rAF to ~1 Hz, so an inbox tied to the
      // render tick would fill faster than it drains and packets would sit
      // unapplied until the window is shown. dirty is already set by the
      // mutators, so the first visible tick presents the current whole state.
      applyTimed(p);
    }
  } catch (err) { protect(err); }
}

function control(text) {
  let m = null;
  try { m = JSON.parse(text); } catch (_) { return; }
  if (!m || typeof m !== 'object') return;
  if (m.type === 'error') { /* surfaced by the native console */ }
}

function send(obj) {
  try { if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj)); } catch (_) {}
}

// ---------------------------------------------------------------- transport api
function setPaused(v) { paused = v; setStatusFromState(); }

/// Moves buffered packets into the apply queue (frame-complete mode keeps the
/// drain inside the render tick, so resuming cannot stall the page).
function queuePending() {
  for (const p of pending) {
    inbox.push(p);
    inboxBytes += p.payload.byteLength + 48;
  }
  const had = pending.length > 0;
  pending = [];
  stepArmed = false;
  return had;
}

function resumeNow() {
  if (needsResync) {
    send({ cmd: 'seek', t: appliedNs / 1e9 });
    pending = []; needsResync = false; expectedSequence = null;
    inbox = []; inboxHead = 0; inboxBytes = 0;
  } else if (frameMode) {
    dirty = dirty || queuePending();
  } else {
    for (const p of pending) applyTimed(p);
    pending = []; stepArmed = false;
  }
  setPaused(false);
  send({ cmd: 'resume' });
}

function togglePause() { if (paused) resumeNow(); else { setPaused(true); send({ cmd: 'pause' }); } }

function requestStep() {
  if (!paused) { setPaused(true); send({ cmd: 'pause' }); }
  if (pending.length) applyTimed(pending.shift());
  else if (inboxHead < inbox.length) applyTimed(takeInbox());  // one queued packet
  else stepArmed = true;
  send({ cmd: 'step' });
}

function requestSeek(t) {
  pending = []; stepArmed = false; expectedSequence = null;
  inbox = []; inboxHead = 0; inboxBytes = 0;
  seekRequest = t;
  setStatusFromState();
  if (!(ws && ws.readyState === 1)) { reconnectTries = 0; connect(); return; }
  send({ cmd: 'seek', t });
}

// ---------------------------------------------------------------- connection
function connect() {
  if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
  expectedSequence = null; decoderFailed = false; seekRequest = null;
  pending = []; needsResync = false; stepArmed = false; setPaused(false);
  inbox = []; inboxHead = 0; inboxBytes = 0;
  packets = 0; bytes = 0; appliedNs = 0; evictedCount = 0;
  presentedFrames = 0; changedPackets = 0;
  set('packets', '0'); set('bytes', '0 KB');
  connState = '接続中…';
  const sock = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`);
  sock.binaryType = 'arraybuffer';
  ws = sock;
  sock.onopen = () => { if (sock !== ws) return; reconnectTries = 0; connState = '接続済み'; setStatusFromState(); };
  sock.onclose = (ev) => {
    if (sock !== ws) return;
    if (decoderFailed) { setStatusFromState(); return; }
    if (ev.code === 1000 && ev.wasClean) {
      if (paused && pending.length && !needsResync) {
        if (frameMode) { dirty = dirty || queuePending(); setPaused(false); }
        else { for (const p of pending) applyTimed(p); pending = []; stepArmed = false; setPaused(false); }
      }
      connState = '完了';
      status('完了', '');
      return;
    }
    const maxRetries = cfg.autoReconnect ? Math.max(0, Math.min(20, cfg.reconnectAttempts | 0)) : 0;
    if (reconnectTries < maxRetries) {
      reconnectTries++;
      connState = `切断 — 再接続 (${reconnectTries}/${maxRetries})`;
      setStatusFromState();
      const backoff = Math.min(8000, 500 * Math.pow(2, reconnectTries - 1));
      reconnectTimer = setTimeout(connect, backoff);
    } else { connState = '切断'; status(connState, 'err'); }
  };
  sock.onerror = () => { if (sock !== ws) return; connState = '通信エラー'; setStatusFromState(); };
  sock.onmessage = (ev) => { if (sock !== ws) return; onMessage(ev); };
}

// ---------------------------------------------------------------- render loop
//
// Frame-complete presentation. Each tick:
//   1. drains queued packets up to the per-tick apply budget (every exit is a
//      packet boundary, so the scene is always a whole state here);
//   2. presents at most ONCE per tick, and only when something changed;
//   3. only then does the next tick start — a frame is on screen (submitted to
//      the compositor) before any further packet is applied.
// Under load the budget cuts the drain short and the intermediate states are
// never presented (dropped): the presenter shows the later, complete state
// instead of a torn one. Hidden pages keep applying (the stream must drain or
// the native send would stall) but present nothing.
let rafTimes = [];
let lastFrame = null;
function tick() {
  const now = performance.now();
  if (lastFrame !== null) set('frame_ms', (now - lastFrame).toFixed(2));
  lastFrame = now;
  rafTimes.push(now);
  if (rafTimes.length > 240) rafTimes.shift();
  // Never spend GPU time on a frame nobody can see: an occluded window makes
  // WebKit throttle rAF to ~1 Hz, and rendering into that throttled surface both
  // wastes power and starves the ingest path (the socket then backs up).
  try {
    const controlsMoved = controls.update();
    if (!frameMode) {
      // Legacy behaviour: packets were applied on arrival; draw what exists.
      if (!cfg.noRender && !document.hidden) { renderer.render(scene, camera); presentedFrames++; }
    } else {
      drainInbox(now + applyBudgetMs);
      if (!cfg.noRender && !document.hidden && (dirty || controlsMoved)) {
        renderer.render(scene, camera);
        dirty = false;
        presentedFrames++;
      }
      // dirty stays set when the present was skipped (hidden / noRender), so
      // the first visible tick shows the current complete state.
    }
  }
  catch (err) { if (!decoderFailed) { decoderFailed = true; status('描画エラー: ' + err.message, 'err'); } }
  requestAnimationFrame(tick);
}
requestAnimationFrame(tick);

// ---------------------------------------------------------------- telemetry
setInterval(() => {
  const now = performance.now();
  while (rafTimes.length && rafTimes[0] <= now - 1000) rafTimes.shift();
  set('fps', String(rafTimes.length));
  const info = renderer.info;
  set('draw_calls', info && info.render ? String(info.render.calls) : '0');
  set('geometries', info && info.memory ? String(info.memory.geometries) : '0');
  set('textures', info && info.memory ? String(info.memory.textures) : '0');
  set('programs', info && Array.isArray(info.programs) ? String(info.programs.length) : '0');
  if (frameMode) {
    set('presented', presentedFrames.toLocaleString());
    set('dropped', Math.max(0, changedPackets - presentedFrames).toLocaleString());
    set('backlog', String(inbox.length - inboxHead));
  }
  const bar = $('progressbar');
  if (bar && durationNs && packets) {
    const frac = Math.min(1, (appliedNs / 1e9) / (durationNs / 1e9));
    bar.style.width = (frac * 100).toFixed(1) + '%';
  }
}, 250);

// ---------------------------------------------------------------- native API
window.__s3dv = {
  toggleWireframe() {
    wire = !wire;
    for (const a of arenas) a.mat.wireframe = wire;
    for (const rec of chunks.values()) if (rec.standalone) rec.mesh.material.wireframe = wire;
    dirty = true;
  },
  resetView() {
    userMovedCamera = false;
    fitView(true);
  },
  pause: () => { setPaused(true); send({ cmd: 'pause' }); },
  resume: () => resumeNow(),
  step: () => requestStep(),
  seek: (t) => requestSeek(t),
  setSpeed: (r) => send({ cmd: 'speed', rate: r }),
  trimTo(mb) {
    if (!(mb > 0)) return;
    const target = mb * 1048576;
    let guard = chunks.size;
    while (residentBytes() > target && chunks.size && guard-- > 0) {
      const first = chunks.keys().next();
      if (first.done) break;
      const id = first.value;
      const rec = chunks.get(id);
      removeChunk(id);
      tombstones.set(id, rec?.rev ?? 0);
      evictedCount++;
    }
    maybeCompact();
    updateHud();
  },
  applyConfig(next) {
    if (!next) return;
    if (typeof next.wireframe === 'boolean' && next.wireframe !== wire) this.toggleWireframe();
    if (typeof next.grid === 'boolean') grid.visible = next.grid;
    if (next.presentation === 'frameComplete' || next.presentation === 'immediate') {
      const want = next.presentation !== 'immediate';
      if (want !== frameMode) {
        // Mode switches live. Leaving frame-complete flushes the queue so no
        // buffered packet is stranded; entering it just starts buffering.
        if (!want) drainInbox(Infinity);
        frameMode = want;
        dirty = true;
      }
    }
    if (Number.isFinite(next.applyBudgetMs)) {
      applyBudgetMs = Math.min(50, Math.max(1, next.applyBudgetMs | 0));
    }
    if (typeof next.hud === 'boolean') {
      const hud = $('hud'); if (hud) hud.classList.toggle('hidden', !next.hud);
    }
    if (Number.isFinite(next.pixelRatio)) {
      renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, Math.max(1, next.pixelRatio)));
      resize();
    }
  },
  // Forces GPU completion so the number is a real frame cost, not a queue depth.
  benchmark(frames = 20) {
    const gl = renderer.getContext();
    const t0 = performance.now();
    for (let i = 0; i < frames; i++) { controls.update(); renderer.render(scene, camera); gl.finish(); }
    return (performance.now() - t0) / frames;
  },
  // Synchronously applies up to maxPackets queued packets (autotest / CLI use:
  // a hidden page applies on arrival anyway, so this only matters when a visible
  // page ended its stream with a residual backlog — e.g. the socket closed
  // between ticks). Returns how many were applied. Still bounded so a caller
  // cannot wedge the page; repeating with the same argument drains the rest.
  flushInbox(maxPackets = 2000) {
    const cap = Math.max(1, maxPackets | 0);
    let applied = 0;
    while (inboxHead < inbox.length && applied < cap) {
      const p = takeInbox();
      try { applyTimed(p); }
      catch (err) { inbox = []; inboxHead = 0; inboxBytes = 0; protect(err); break; }
      applied++;
    }
    return applied;
  },
  documentHidden() { return { hidden: document.hidden, state: document.visibilityState }; },
  metrics() {
    return {
      chunks: chunks.size, triangles: Math.round(triangles()), evicted: evictedCount,
      arenaBytes: allocatedBytes(), liveBytes: residentBytes(),
      packets, promoted: promoteCount, textures: textures.size,
      presented: presentedFrames,
      dropped: frameMode ? Math.max(0, changedPackets - presentedFrames) : 0,
      backlog: frameMode ? (inbox.length - inboxHead) : 0,
      presentation: frameMode ? 'frameComplete' : 'immediate',
      applyBudgetMs,
    };
  },
};

// ---------------------------------------------------------------- boot
// Duration is best-effort; without it the native transport hides the timeline.
fetch('/metadata', { cache: 'no-store' })
  .then((r) => (r.ok ? r.json() : Promise.reject()))
  .then((m) => {
    if (m && Number.isFinite(m.duration_ns) && m.duration_ns > 0) durationNs = m.duration_ns;
  })
  .catch(() => {});
connect();
