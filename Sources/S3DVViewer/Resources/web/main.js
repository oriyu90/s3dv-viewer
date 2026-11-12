import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

const $ = (id) => document.getElementById(id);
const root=$('stage');
const scene = new THREE.Scene(); scene.background=new THREE.Color(0x101827);
scene.add(new THREE.GridHelper(8,16,0x5e7d9f,0x24364b).rotateX(Math.PI/2));
const light=new THREE.DirectionalLight(0xffffff,1.25);light.position.set(4,3,8);scene.add(light);scene.add(new THREE.AmbientLight(0xffffff,0.65));
const camera=new THREE.PerspectiveCamera(56,1,0.05,300);camera.up.set(0,0,1);
camera.position.set(4,-5,3);
const renderer=new THREE.WebGLRenderer({antialias:true});renderer.setPixelRatio(Math.min(window.devicePixelRatio||1,2));
root.insertBefore(renderer.domElement,root.firstChild);
const controls=new OrbitControls(camera,renderer.domElement);controls.enableDamping=true;controls.target.set(0,0,0);
function resize(){const w=root.clientWidth,h=root.clientHeight; renderer.setSize(w,h);camera.aspect=w/h;camera.updateProjectionMatrix()}
addEventListener('resize',resize);resize();
// Runtime Metrics group (web/aside): measured proxies only — the browser reports no OS CPU/GPU usage. Guarded DOM refs: the same bundle runs natively (WKWebView) where the document may differ.
const rt={raf:[],lastFrame:null,apply:[],t0:performance.now(),p0:0,b0:0,
 el:Object.fromEntries(['fps','frame_ms','apply_ms','pkt_s','kib_s','draw_calls','geometries','textures','programs','heap_mb','wsbuf'].map(id=>[id,$(id)])),
 put(id,v){const e=this.el[id];if(e)e.textContent=v}}; // ids mirror web/index.html (Runtime Metrics group)
function rtSample(ms){const a=rt.apply;if(a.push(ms),a.length>128)a.shift(); // moving average of the last 128 packets (decode+apply live; apply-only on replay)
 if(a.length)rt.put('apply_ms',(a.reduce((s,x)=>s+x,0)/a.length).toFixed(2)+' ms')}
function rtReset(){rt.raf.length=0;rt.apply.length=0;rt.t0=performance.now();rt.p0=packets;rt.b0=bytes;rt.put('pkt_s','—');rt.put('kib_s','—')} // audit minor-4: clear the previous connection's rate display too
function tick(){const tf=performance.now(); // Runtime Metrics: every rAF is a sample; only frame_ms writes DOM per frame
 if(rt.lastFrame!==null)rt.put('frame_ms',(tf-rt.lastFrame).toFixed(2)+' ms');
 rt.lastFrame=tf;rt.raf.push(tf);if(rt.raf.length>240)rt.raf.shift(); // 1 s rolling window at reasonable frame rates (capped array)
 try{controls.update();renderer.render(scene,camera)}catch(err){if(!decoderFailed){decoderFailed=true;$('status').textContent='Render error: '+err.message}}requestAnimationFrame(tick)}tick(); // a render failure must not kill the rAF chain (protect covers decode; status covers the renderer)
let registry=new Map(),tombstones=new Map(),textures=new Map(),wire=false,bytes=0,packets=0; // textures: per-chunk projected texture cache, keyed by chunk id (docs/14 §2.3)
function destroy(mesh){scene.remove(mesh);if(mesh.material.map)mesh.material.map.dispose();mesh.geometry.dispose();mesh.material.dispose()} // no shared materials: the texture belongs to exactly one mesh
function clear(){for(const item of registry.values())destroy(item.mesh);registry.clear();for(const tex of textures.values())if(tex.bitmap)tex.bitmap.close();textures.clear();tombstones.clear();refresh()}
function refresh(){let tris=0,texn=0;for(const item of registry.values())tris+=item.mesh.geometry.index.count/3;for(const tex of textures.values())if(tex.bitmap)texn++;
$('chunks').textContent=registry.size;$('triangles').textContent=tris.toLocaleString();$('tex').textContent=texn;}
const isLE=(new Uint8Array(new Uint32Array([1]).buffer))[0]===1; // used for bulk mesh decode
const QUANT_MARKER=0xFFFFFFFF; // W8/T-801 marker: raw vertex_count is capped at 400000
function parseMesh(payload){ // decode raw f32 mesh or QUANT_MESH_U16 (audit B2: clients rejected quantized recordings)
const d=new DataView(payload);if(d.byteLength<8)throw Error('Mesh header too small');
if(d.getUint32(0,true)!==QUANT_MARKER){
 const n=d.getUint32(0,true),ni=d.getUint32(4,true);
 if(n>400000||ni>1200000||ni%3||payload.byteLength!==8+12*n+4*ni+3*n)throw Error('Invalid mesh sizes');
 const position=new Float32Array(n*3),index=new Uint32Array(ni),rawcolors=new Uint8Array(n*3);
 const p0=8,p1=p0+12*n,p2=p1+4*ni;
 if(isLE){position.set(new Float32Array(payload.slice(p0,p1)));if(ni)index.set(new Uint32Array(payload.slice(p1,p2)));rawcolors.set(new Uint8Array(payload.slice(p2)))}
 else{for(let i=0;i<n*3;i++)position[i]=d.getFloat32(p0+4*i,true);for(let i=0;i<ni;i++)index[i]=d.getUint32(p1+4*i,true);rawcolors.set(new Uint8Array(payload.slice(p2)),0,n*3)}
 return{n,ni,position,index,rawcolors};
}
if(d.byteLength<44)throw Error('Quant header too small');
const codec=d.getUint32(4,true),n=d.getUint32(8,true);
if(codec!==1||n===0||n>400000)throw Error('Invalid quant header');
if(d.getUint16(38,true)!==0||d.getUint16(40,true)!==0)throw Error('Invalid quant reserved');
const indexBits=d.getUint16(36,true);
if(indexBits!==32&&indexBits!==16)throw Error('Invalid quant index bits');
if(indexBits===16&&n>=65536)throw Error('Quant index width too small');
const origin=[d.getFloat32(12,true),d.getFloat32(16,true),d.getFloat32(20,true)];
const extent=[d.getFloat32(24,true),d.getFloat32(28,true),d.getFloat32(32,true)];
const dataOff=44,isz=indexBits===32?4:2;
const rest=payload.byteLength-dataOff-6*n-3*n;
if(rest<0||rest%isz!==0)throw Error('Quant payload length mismatch');
const ni=rest/isz;if(ni%3)throw Error('Invalid quant index count');
const position=new Float32Array(n*3),index=new Uint32Array(ni),rawcolors=new Uint8Array(n*3);
for(let i=0;i<n*3;i++){const q=d.getUint16(dataOff+2*i,true);position[i]=origin[i%3]+(q/65535)*extent[i%3]}
const idxOff=dataOff+6*n;
for(let i=0;i<ni;i++)index[i]=indexBits===32?d.getUint32(idxOff+4*i,true):d.getUint16(idxOff+2*i,true);
rawcolors.set(new Uint8Array(payload.slice(idxOff+isz*ni,idxOff+isz*ni+3*n)));
return{n,ni,position,index,rawcolors};}
function checkMesh(payload){const r=parseMesh(payload);return[r.n,r.ni]}
function addMesh(id,rev,payload){const existing=registry.get(id);
const oldRev=Math.max(existing?.rev??-1,tombstones.get(id)??-1);
if(rev<=oldRev)return;
const{n,ni,position,index,rawcolors}=parseMesh(payload);
for(let i=0;i<index.length;i++)if(index[i]>=n)throw Error('Index out of range');
for(let i=0;i<position.length;i++)if(!Number.isFinite(position[i]))throw Error('Non-finite geometry');
// The wire stores sRGB bytes; three.js vertex colors are linear-sRGB since r152.
const colors=new Float32Array(n*3);
for(let i=0;i<n*3;i++){const c=rawcolors[i]/255;colors[i]=c<=0.04045?c/12.92:Math.pow((c+0.055)/1.055,2.4);}
const geo=new THREE.BufferGeometry();geo.setAttribute('position',new THREE.BufferAttribute(position,3));
geo.setAttribute('color',new THREE.BufferAttribute(colors,3));geo.setIndex(new THREE.BufferAttribute(index,1));geo.computeVertexNormals();
const tex=textures.get(id); // a decoded texture for this exact revision rides in on creation, otherwise the in-flight decode paints this mesh on resolve
let material;
if(tex&&tex.rev===rev&&tex.bitmap){geo.setAttribute('uv',new THREE.BufferAttribute(uvAttr(tex.P,tex.crop,position),2));
 material=new THREE.MeshStandardMaterial({map:bitmapTexture(tex.bitmap),roughness:.85,metalness:0,side:THREE.DoubleSide,wireframe:wire})}
else material=new THREE.MeshStandardMaterial({vertexColors:true,roughness:.85,metalness:0,side:THREE.DoubleSide,wireframe:wire});
const mesh=new THREE.Mesh(geo,material);
if(existing)destroy(existing.mesh);
scene.add(mesh);registry.set(id,{rev,mesh});tombstones.delete(id);refresh();}
function rmMesh(id,rev,payload){if(payload&&payload.byteLength)throw Error('Remove payload must be empty'); // mirrors the reducer's reject
const current=registry.get(id);if(rev<=Math.max(current?.rev??-1,tombstones.get(id)??-1))return;
if(current)destroy(current.mesh);registry.delete(id);const tex=textures.get(id); // the chunk and its projected texture leave together (docs/14 §2.3)
if(tex){if(tex.bitmap)tex.bitmap.close();textures.delete(id)}tombstones.set(id,rev);refresh();}
function uvAttr(P,crop,position){ // projected UVs: uv=((u/z-crop_x0)/crop_w,(v/z-crop_y0)/crop_h) for P·X=(u,v,z) (docs/14 §1)
 const uv=new Float32Array(position.length/3*2);
 for(let i=0,j=0;i<position.length;i+=3,j+=2){let u=0,v=0;
  const z=P[8]*position[i]+P[9]*position[i+1]+P[10]*position[i+2]+P[11];
  if(z>0){u=(P[0]*position[i]+P[1]*position[i+1]+P[2]*position[i+2]+P[3])/z,v=(P[4]*position[i]+P[5]*position[i+1]+P[6]*position[i+2]+P[7])/z;
   u=(u-crop[0])/crop[2];v=(v-crop[1])/crop[3];
   if(!Number.isFinite(u)||!Number.isFinite(v)||Math.abs(u)>3.4e38||Math.abs(v)>3.4e38){u=0;v=0}} // degenerate/overflowing projection pins the vertex to the corner texel (float32-safe)
  // a vertex with z<=0 projects behind the camera: mid-process by definition, its texture is undefined and the UV collapses to (0,0)
  uv[j]=u;uv[j+1]=v}
 return uv}
function bitmapTexture(bitmap){const t=new THREE.Texture(bitmap);t.colorSpace=THREE.SRGBColorSpace;t.wrapS=t.wrapT=THREE.ClampToEdgeWrapping;t.magFilter=t.minFilter=THREE.NearestFilter;t.generateMipmaps=false;t.needsUpdate=true;return t} // docs/14 §1 sampler: nearest + clamp, sRGB bytes
function textureMesh(entry,tex){ // paint the persistent mesh only while its revision still equals the texture revision; never shared material
 if(!entry||entry.rev!==tex.rev||entry.mesh.material.map)return;
 entry.mesh.geometry.setAttribute('uv',new THREE.BufferAttribute(uvAttr(tex.P,tex.crop,entry.mesh.geometry.getAttribute('position').array),2));
 const old=entry.mesh.material;
 const t3=bitmapTexture(tex.bitmap);
 entry.mesh.material=new THREE.MeshStandardMaterial({map:t3,roughness:.85,metalness:0,side:THREE.DoubleSide,wireframe:wire});if(old.map)old.map.dispose();old.dispose(); // vertex-color material is gone forever (docs/04 §6 recovery; the map guard is a safety no-op here)
 tex.tex3d=t3;} // keep the bitmap↔THREE.Texture link so a later replacement can free them in a safe order (closes after the owner stops referencing it)
function checkTexture(payload){ // op 6 wire validation before decode; rejects what the Python decode_texture rejects (docs/14 §1: no CRC, self-validation ends here)
 const d=new DataView(payload);if(payload.byteLength<128)throw Error('Texture header too small');
 if(d.getUint8(0)!==1||d.getUint8(1)||d.getUint8(2)||d.getUint8(3))throw Error('Unknown texture codec');
 const w=d.getUint32(4,true),h=d.getUint32(8,true),pngBytes=d.getUint32(124,true);
 if(w<1||w>4096||h<1||h>4096)throw Error('Invalid texture dimensions');
 if(payload.byteLength!==128+pngBytes)throw Error('Invalid texture payload length');
 const P=new Float64Array(12);for(let i=0;i<12;i++){P[i]=d.getFloat64(12+8*i,true);if(!Number.isFinite(P[i]))throw Error('Non-finite texture projection')}
 const crop=[d.getUint32(108,true),d.getUint32(112,true),d.getUint32(116,true),d.getUint32(120,true)];
 if(crop[2]!==w||crop[3]!==h)throw Error('Texture crop mismatch');
 if(pngBytes<8)throw Error('PNG stream too small');
 const png=new Uint8Array(payload,128);
 for(let i=0;i<8;i++)if(png[i]!==[137,80,78,71,13,10,26,10][i])throw Error('Not a PNG stream'); // PNG signature sniff
 if(d.getUint32(136,false)!==13||d.getUint8(140)!==73||d.getUint8(141)!==72||d.getUint8(142)!==68||d.getUint8(143)!==82||d.getUint32(144,false)!==w||d.getUint32(148,false)!==h)throw Error('PNG dimensions mismatch'); // IHDR length/tag/BE dims
 if(d.getUint8(152)!==8||d.getUint8(153)!==2||d.getUint8(156)!==0)throw Error('Unsupported PNG IHDR (offsets 24/25/28: bit depth 8, color type 2, interlace 0 required)'); // 8-bit RGB non-interlaced: offsets are payload-relative (PNG bytes 24/25/28), matching s3dv.texture exactly; filter byte (27) is deliberately unchecked like the Python decoder
 return{P,crop,pngBytes}}
function applyTexture(id,rev,payload,parsed){ // op 6: structurally validated at ingest; the texture revision series is independent of the mesh series (docs/14 §2.3)
 if(rev<=(textures.get(id)?.rev??-1))return; // stale texture revision for this chunk: dropped like the reducer's reject (the cmp series is independent, so tombstones are irrelevant here)
 const tex={rev,P:parsed.P,crop:parsed.crop,bitmap:null,tex3d:null,pending:null,pngBytes:parsed.pngBytes};
 const prev=textures.get(id); // superseded entry; release only when nothing can re-upload it (docs/04 §6)
 if(prev&&prev.bitmap&&prev.bitmap!==tex.bitmap&&!prev.tex3d)prev.bitmap.close(); // never painted: immediate release is safe
 textures.set(id,tex);
 tex.pending=createImageBitmap(new Blob([payload.slice(128)],{type:'image/png'}),{colorSpaceConversion:'none'}) // asynchronous PNG walk of the exact payload bytes; no color juggling keeps pixels identical to the Python decoder
 .then(bitmap=>{if(textures.get(id)!==tex)return bitmap.close(); // superseded meanwhile (REMOVE/restart/replace): release the obsolete decode
  tex.bitmap=bitmap;tex.pending=null;textureMesh(registry.get(id),tex);
  if(prev&&prev.tex3d){const e=registry.get(id);
   if(!e||e.mesh.material.map!==prev.tex3d){prev.tex3d.dispose();prev.bitmap.close()}} // the old material no longer references it, so the GL texture is gone before the bitmap detaches (a still-painted owner keeps the bitmap alive until its own replace/destroy frees it)
  refresh()})
 .catch(err=>{
  if(textures.get(id)===tex){textures.delete(id);tex.pending=null;refresh()} // corrupt PNG: reaches protect like any other decode error
  protect(err instanceof Error?err:Error('PNG decode failed'))})} // protect closes and never re-loops (decoder failure parity)
const crcTable = new Uint32Array(256);
for(let k=0;k<256;k++){let x=k;for(let j=0;j<8;j++)x=(x&1)?(0xEDB88320^(x>>>1)):(x>>>1);crcTable[k]=x>>>0;}
function crc32(buf,count){let crc=0xFFFFFFFF,bytes=new Uint8Array(buf,0,count);
 for(const b of bytes)crc=crcTable[(crc^b)&255]^(crc>>>8);return(crc^0xFFFFFFFF)>>>0;}
const names={1:'HELLO',2:'SNAPSHOT_BEGIN',3:'CHUNK_ADD',4:'CHUNK_REPLACE',5:'CHUNK_REMOVE',6:'TEXTURE_UPDATE',7:'SNAPSHOT_END',8:'STATS',9:'RESYNC_REQUEST',10:'HEARTBEAT'};
const PENDING_CAP=20000; // buffered validation-passing packets while paused
let ws=null,expectedSequence=null,paused=false,pending=[],needsResync=false,dropped=0,stepArmed=false;
let durationNs=null,seekRequest=null,seekAdvancing=false,decoderFailed=false;
let connState='Connecting…',reconnectTries=0,reconnectTimer=null;
function setStatus(){let s=connState;
if(seekRequest!==null)s=seekAdvancing&&connState==='Connected'
 ?`Seek requested → ${seekRequest.toFixed(3)} s (stream still advancing)`
 :`Seeking → ${seekRequest.toFixed(3)} s`;
else if(paused&&connState==='Connected')s='Paused';
$('status').textContent=s;}
function syncClock(){const s=lastAppliedNs()/1e9;
$('clock').textContent=`${s.toFixed(3)} / ${durationNs!==null?(durationNs/1e9).toFixed(3)+' s':'—'}`;
if(durationNs!==null)$('timeline').value=String(Math.min(s,durationNs/1e9));}
let appliedNs=0;
const lastAppliedNs=()=>appliedNs;
function applyPacket(p){ // mutates the scene from an already-validated packet
 if(p.op===2)clear();else if(p.op===3||p.op===4)addMesh(p.chunk,p.rev,p.payload);
 else if(p.op===5)rmMesh(p.chunk,p.rev,p.payload);
 else if(p.op===6)applyTexture(p.chunk,p.rev,p.payload,p.tex); // TEXTURE_UPDATE first use (docs/14 §2.3): pause buffer and clean-close tail flush ride the same no-loss path
 appliedNs=p.ts;
 if(p.op===2)seekRequest=null; // the next SNAPSHOT_BEGIN proves the re-anchor happened
 else if(seekRequest!==null)seekAdvancing=true; // server is not seeking: keep the degrade status honest
 $('time').textContent=(appliedNs/1e9).toFixed(3)+' s';syncClock();setStatus();}
function ingest(buf){ // header/CRC/sequence validation; THROWS on any violation (never skipped)
 const d=new DataView(buf);if(d.byteLength<48)throw Error('Short packet');
 if(String.fromCharCode(...new Uint8Array(buf,0,4))!=='S3DP'||d.getUint8(4)!==1)throw Error('Packet magic/version');
 const op=d.getUint8(5),flags=d.getUint16(6,true),sequence=d.getBigUint64(16,true),chunk=d.getBigUint64(24,true).toString(),rev=d.getUint32(32,true),size=d.getUint32(36,true);
 if((flags&~1)!==0||size>16*1024*1024||buf.byteLength!==48+size+((flags&1)?4:0))throw Error('Packet bounds');
 if((flags&1)&&crc32(buf,48+size)!==d.getUint32(48+size,true))throw Error('CRC mismatch');
 if(op<1||op>10)throw Error('Unknown op '+op); // decode parity with s3dv.protocol (docs/07 §7 unexpected op)
 if(op===2){expectedSequence=sequence;seekRequest=null;seekAdvancing=false} // resync boundary: a BEGIN proves the re-anchor (seek/waiting state resolved at ingest, even while paused)
 else if(expectedSequence!==null&&sequence!==expectedSequence)throw Error('Sequence gap');
 let payload=buf.slice(48,48+size),texd=null;
 if(op===6){if(chunk==='0')throw Error('Texture chunk must be positive'); // docs/14 §1: chunk_id>0 mandatory
  texd=checkTexture(payload)} // full pre-decode typing/validation before any walk (docs/14 §2.3: throw → protect, Python decoder parity)
 return{op,sequence,chunk,rev,payload,ts:Number(d.getBigUint64(40,true)),tex:texd}}
function protect(err){connState='Decode error: '+err.message;decoderFailed=true;setStatus();
 try{if(ws)ws.close()}catch(_){/* the socket dies protecting the viewer */}}
function onMessage(event){const tm=performance.now();try{
 if(typeof event.data==='string'){control(event.data);return;}
 const p=ingest(event.data); // validates and re-anchors on SNAPSHOT_BEGIN
 expectedSequence=p.sequence+1n;
 packets++;bytes+=event.data.byteLength;
 $('packets').textContent=packets.toLocaleString();$('bytes').textContent=(bytes/1024).toFixed(1)+' KB';
 $('op').textContent=names[p.op]||('Unknown op '+p.op);
 if(p.op===2){pending=[];setStatus()} // spec: a begin clears any pending local buffer (stale pre-seek frames); status re-evaluated even while paused
 if(paused){
  if(stepArmed){stepArmed=false;applyPacket(p);rtSample(performance.now()-tm);return} // `.` requested exactly this packet (decode+apply measured)
  if(pending.length>=PENDING_CAP){needsResync=true;dropped++;return;} // cap: local replay impossible
  pending.push(p);return;}
 applyPacket(p);rtSample(performance.now()-tm); // decode+apply of a live packet
}catch(err){protect(err)}}
function applyTimed(p){const t=performance.now();applyPacket(p);rtSample(performance.now()-t)} // reachable replay: the decode already happened, only the application is measured
function control(text){ // text frames are server acks/errors only; never treated as binary
 let m=null;try{m=JSON.parse(text)}catch(_){return}
 if(!m||typeof m!=='object'||(m.type!=='ok'&&m.type!=='error'))return;
 // Command-tolerant UI: acks need no action (don't rely on server honouring).
}
function send(obj){try{if(ws&&ws.readyState===1)ws.send(JSON.stringify(obj))}catch(_){/* degradation only */}}
function setPaused(v){paused=v;$('pause').textContent=v?'Play':'Pause';$('step').disabled=!v;setStatus()}
function togglePause(){if(paused)resumeNow();else{setPaused(true);send({cmd:'pause'})}} // ack not required (command-ignorant servers exist)
function resumeNow(){
 if(needsResync){ // the buffer overflowed while paused: re-send from a snapshot instead
  send({cmd:'seek',t:appliedNs/1e9});pending=[];needsResync=false;expectedSequence=null;
 }else{for(const p of pending)applyTimed(p);pending=[];stepArmed=false;} // no loss/no duplication
 setPaused(false);send({cmd:'resume'});}
function requestStep(){ // only while paused (button disabled otherwise)
 if(!paused)return;
 if(pending.length)applyTimed(pending.shift());else stepArmed=true;
 send({cmd:'step'});}
function requestSeek(t){
 pending=[];stepArmed=false;expectedSequence=null;seekRequest=t;seekAdvancing=false;
 setStatus();
 if(!(ws&&ws.readyState===1)){reconnectTries=0;connect();return} // after end: fresh replay from the start
 send({cmd:'seek',t:t});}
const clampSeek=t=>Math.min(Math.max(0,t),durationNs/1e9);
$('pause').onclick=togglePause;
$('step').onclick=requestStep;
$('speed').onchange=()=>send({cmd:'speed',rate:+$('speed').value});
$('timeline').addEventListener('change',()=>{if(durationNs!==null)requestSeek(parseFloat($('timeline').value))});
$('restart').onclick=()=>{ // deliberate replay from the beginning also used after end-of-stream
 if(reconnectTimer){clearTimeout(reconnectTimer);reconnectTimer=null}
 reconnectTries=0;connect()};
addEventListener('keydown',(ev)=>{
 if(ev.repeat)return;
 const tag=ev.target&&ev.target.tagName;
 if(tag==='BUTTON'||tag==='SELECT')return; // focused controls keep native activation
 if(ev.key===' '){ev.preventDefault();togglePause()}
 else if(ev.key==='.'){ev.preventDefault();requestStep()}
 else if(ev.key==='ArrowLeft'&&durationNs!==null){ev.preventDefault();requestSeek(clampSeek(appliedNs/1e9-1))}
 else if(ev.key==='ArrowRight'&&durationNs!==null){ev.preventDefault();requestSeek(clampSeek(appliedNs/1e9+1))}});
$('wire').onclick=()=>{wire=!wire;for(const obj of registry.values())obj.mesh.material.wireframe=wire;$('wire').textContent=wire?'Solid':'Wireframe'};
$('reset').onclick=()=>{camera.position.set(4,-5,3);controls.target.set(0,0,0);controls.update()};
function connect(){ // one fresh connection: baseline reset, WS events guarded against stale sockets
 if(reconnectTimer){clearTimeout(reconnectTimer);reconnectTimer=null}
 expectedSequence=null;decoderFailed=false;seekRequest=null;seekAdvancing=false;
 pending=[];needsResync=false;dropped=0;stepArmed=false;setPaused(false);
  rtReset(); // Runtime Metrics windows restart with the connection (rates must not spike on a fresh socket)
 connState='Connecting…';setStatus();
 const sock=new WebSocket(`${location.protocol==='https:'?'wss':'ws'}://${location.host}/ws`);sock.binaryType='arraybuffer';ws=sock;
 sock.onopen=()=>{if(sock!==ws)return;reconnectTries=0;connState='Connected';setStatus()};
 sock.onclose=(ev)=>{if(sock!==ws)return; // events of a replaced socket are irrelevant
  if(decoderFailed){setStatus();return} // corrupt packet: protect, never re-loop into it
  if(ev.code===1000&&ev.wasClean){ // stream finished; no auto reconnect
   if(paused&&pending.length&&!needsResync){for(const p of pending)applyTimed(p);pending=[];stepArmed=false;setPaused(false)} // lossless: nothing more will arrive, so the buffered tail must apply (docs/04 §6)
   connState='Completed';setStatus();return}
  if(reconnectTries<3){reconnectTries++;connState=`Disconnected — reconnecting (${reconnectTries}/3)…`;setStatus();
   reconnectTimer=setTimeout(connect,[500,1000,2000][reconnectTries-1])}
  else{connState='Disconnected';setStatus()}};
 sock.onerror=()=>{if(sock!==ws)return;connState='Network error';setStatus()};
 sock.onmessage=ev=>{if(sock!==ws)return;onMessage(ev)};} // stale-socket guard: a replaced socket (mid-replay Restart) must never double-ingest (W6 audit med-1)
connect();
// Duration is best-effort: without it (native app today) the timeline stays disabled.
fetch('/metadata',{cache:'no-store'}).then(r=>r.ok?r.json():Promise.reject()).then(m=>{
 if(m&&Number.isFinite(m.duration_ns)&&m.duration_ns>0){durationNs=m.duration_ns;
 $('timeline').max=(durationNs/1e9).toFixed(3);$('timeline').disabled=false}
 syncClock()}).catch(()=>{syncClock()});
// Runtime Metrics refresh at ~4 Hz: rate windows and renderer.info are coalesced here — no per-packet or per-frame DOM writes beyond frame_ms (cheap and safe even when the aside is hidden)
setInterval(()=>{
 while(rt.raf.length&&rt.raf[0]<=performance.now()-1000)rt.raf.shift();
 rt.put('fps',rt.raf.length);
 const now=performance.now(),dt=(now-rt.t0)/1000;
 if(dt>=1){rt.put('pkt_s',((packets-rt.p0)/dt).toFixed(1)+' pkt/s');rt.put('kib_s',(((bytes-rt.b0)/dt)/1024).toFixed(1)+' KB/s');rt.p0=packets;rt.b0=bytes;rt.t0=now}
 const info=renderer.info; // WebGL render-time proxies; memory/programs fields can be undefined depending on the backend
 rt.put('draw_calls',info&&info.render&&Number.isFinite(info.render.calls)?String(info.render.calls):'—');
 rt.put('geometries',info&&info.memory&&Number.isFinite(info.memory.geometries)?String(info.memory.geometries):'—');
 rt.put('textures',info&&info.memory&&Number.isFinite(info.memory.textures)?String(info.memory.textures):'—');
 rt.put('programs',info&&Array.isArray(info.programs)?String(info.programs.length):'—');
 const heap=performance.memory?performance.memory.usedJSHeapSize:NaN; // Chromium-only API; honest fallback elsewhere
 rt.put('heap_mb',Number.isFinite(heap)?(heap/1048576).toFixed(2)+' MB':'unavailable');
 rt.put('wsbuf',ws&&Number.isFinite(ws.bufferedAmount)?String(ws.bufferedAmount):'0'); // 0 is a value too — displayed on purpose
},250);
