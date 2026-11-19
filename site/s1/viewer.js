// Throwaway S1 viewer: loads s1.wasm, hands it a .gmp and .sty, and draws
// the mesh it builds with WebGL2. Plain JS on purpose so it runs from any
// static file server with no build step.

const $ = (id) => document.getElementById(id);
const canvas = $('c');
const gl = canvas.getContext('webgl2', { antialias: false, powerPreference: 'high-performance' });
if (!gl) throw new Error('WebGL2 not available');

const UNIT = 64; // world units per block
const VERTEX_BYTES = 12;

// ---------------------------------------------------------------- WASM
const { instance } = await WebAssembly.instantiateStreaming(fetch('s1.wasm'), {});
const W = instance.exports;
const mem = () => new Uint8Array(W.memory.buffer);

function wasmError() {
  return new TextDecoder().decode(mem().slice(W.errorPtr(), W.errorPtr() + W.errorLen()));
}

function callWithBytes(fn, bytes) {
  const p = W.alloc(bytes.length);
  if (!p) throw new Error('out of WASM memory');
  mem().set(bytes, p);
  const rc = fn(p, bytes.length);
  W.free(p, bytes.length);
  if (rc !== 0) throw new Error(wasmError());
}

// ---------------------------------------------------------------- GL setup
const vs = `#version 300 es
in vec3 a_pos;
in vec2 a_uv;
in uint a_tile;
in uvec2 a_fs;
uniform mat4 u_mvp;
out vec2 v_uv;
flat out uint v_tile;
flat out uint v_flags;
out float v_shade;
void main() {
  // Map space is x east, y south, z up. GL space is x right, y up, z south.
  gl_Position = u_mvp * vec4(a_pos.x, a_pos.z, a_pos.y, 1.0);
  v_uv = a_uv;
  v_tile = a_tile;
  v_flags = a_fs.x;
  v_shade = float(a_fs.y) / 255.0;
}`;
const fs = `#version 300 es
precision highp float;
precision highp usampler2D;
uniform usampler2D u_atlas;
uniform sampler2D u_pal;
in vec2 v_uv;
flat in uint v_tile;
flat in uint v_flags;
in float v_shade;
out vec4 o;
void main() {
  ivec2 base = ivec2(int(v_tile % 32u), int(v_tile / 32u)) * 64;
  ivec2 p = clamp(ivec2(floor(v_uv)), ivec2(0), ivec2(63));
  uint idx = texelFetch(u_atlas, base + p, 0).r;
  // GTA2 transparency is binary: palette index 0 on a flat face is a hole.
  if ((v_flags & 1u) != 0u && idx == 0u) discard;
  vec4 c = texelFetch(u_pal, ivec2(int(idx), int(v_tile)), 0);
  o = vec4(c.rgb * v_shade, 1.0);
}`;

function shader(type, src) {
  const s = gl.createShader(type);
  gl.shaderSource(s, src);
  gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
  return s;
}
const prog = gl.createProgram();
gl.attachShader(prog, shader(gl.VERTEX_SHADER, vs));
gl.attachShader(prog, shader(gl.FRAGMENT_SHADER, fs));
gl.linkProgram(prog);
if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
const loc = (n) => gl.getAttribLocation(prog, n);
const u_mvp = gl.getUniformLocation(prog, 'u_mvp');

const vao = gl.createVertexArray();
const vbo = gl.createBuffer();
gl.bindVertexArray(vao);
gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
gl.enableVertexAttribArray(loc('a_pos'));
gl.vertexAttribPointer(loc('a_pos'), 3, gl.SHORT, false, VERTEX_BYTES, 0);
gl.enableVertexAttribArray(loc('a_uv'));
gl.vertexAttribPointer(loc('a_uv'), 2, gl.UNSIGNED_BYTE, false, VERTEX_BYTES, 6);
gl.enableVertexAttribArray(loc('a_tile'));
gl.vertexAttribIPointer(loc('a_tile'), 1, gl.UNSIGNED_SHORT, VERTEX_BYTES, 8);
gl.enableVertexAttribArray(loc('a_fs'));
gl.vertexAttribIPointer(loc('a_fs'), 2, gl.UNSIGNED_BYTE, VERTEX_BYTES, 10);
gl.bindVertexArray(null);

const atlasTex = gl.createTexture();
const palTex = gl.createTexture();
for (const t of [atlasTex, palTex]) {
  gl.bindTexture(gl.TEXTURE_2D, t);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
}
let vertexCount = 0;
let haveStyle = false;

// ---------------------------------------------------------------- loading
async function load(gmpBytes, styBytes, label) {
  $('err').textContent = '';
  const t0 = performance.now();
  callWithBytes(W.loadStyle, styBytes);
  const t1 = performance.now();
  callWithBytes(W.loadMap, gmpBytes);
  const t2 = performance.now();

  gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
  gl.bindTexture(gl.TEXTURE_2D, atlasTex);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8UI, 2048, 2048, 0, gl.RED_INTEGER, gl.UNSIGNED_BYTE,
    new Uint8Array(W.memory.buffer, W.atlasPtr(), 2048 * 2048));
  gl.bindTexture(gl.TEXTURE_2D, palTex);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, 256, 1024, 0, gl.RGBA, gl.UNSIGNED_BYTE,
    new Uint8Array(W.memory.buffer, W.palettePtr(), 256 * 1024 * 4));
  haveStyle = true;

  vertexCount = W.vertexCount();
  gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
  gl.bufferData(gl.ARRAY_BUFFER, new Uint8Array(W.memory.buffer, W.vertexPtr(), vertexCount * VERTEX_BYTES), gl.STATIC_DRAW);
  const t3 = performance.now();

  const s = new Uint32Array(W.memory.buffer, W.statsPtr(), 13);
  const hist = new Uint32Array(W.memory.buffer, W.slopeHistogramPtr(), 64);
  const used = [];
  hist.forEach((n, i) => { if (n) used.push(`${i}:${n}`); });
  const info = {
    label, styleParseMs: +(t1 - t0).toFixed(1), mapParseAndMeshMs: +(t2 - t1).toFixed(1), uploadMs: +(t3 - t2).toFixed(1),
    tiles: W.styleTileCount(), triangles: s[3], lids: s[0], sides: s[1], transparent: s[2], dummy1023: s[4],
    blockDefs: s[5], zones: s[6], lights: s[7], anims: s[8], compression: ['UMAP', 'CMAP', 'DMAP'][s[9]],
    version: s[10], unknownChunks: s[11], clampedColumns: s[12], slopeCodes: used.join(' '),
  };
  window.__s1.info = info;
  $('stats').textContent =
    `${label}\n${info.compression} v${info.version}, ${info.blockDefs} block defs, ${info.tiles} tiles\n` +
    `${info.triangles} triangles, ${info.transparent} transparent faces\n` +
    `parse: style ${info.styleParseMs} ms, map+mesh ${info.mapParseAndMeshMs} ms, upload ${info.uploadMs} ms\n` +
    `zones ${info.zones}, lights ${info.lights}, anims ${info.anims}, unknown chunks ${info.unknownChunks}\n` +
    `slope codes: ${info.slopeCodes}`;
  console.log('[s1] loaded', JSON.stringify(info));
}

async function fetchBytes(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${url}: HTTP ${r.status}`);
  return new Uint8Array(await r.arrayBuffer());
}

async function guarded(f) {
  try { await f(); } catch (e) { $('err').textContent = String(e.message || e); console.error('[s1]', e); }
}

$('load').onclick = () => guarded(async () => {
  const g = $('gmp').files[0], s = $('sty').files[0];
  if (!g || !s) throw new Error('Pick both a .gmp and a .sty file.');
  await load(new Uint8Array(await g.arrayBuffer()), new Uint8Array(await s.arrayBuffer()), `${g.name} + ${s.name}`);
  home();
});
$('demo').onclick = () => guarded(async () => {
  await load(await fetchBytes('fixtures/showcase.gmp'), await fetchBytes('fixtures/showcase.sty'), 'synthetic showcase');
  showcaseView();
});
$('toggle').onclick = () => { for (const id of ['help', 'stats']) $(id).classList.toggle('hide'); };

// ---------------------------------------------------------------- camera
// Camera lives in GL space: x east, y up, z south, in map units.
const cam = { x: 128 * UNIT, y: 30 * UNIT, z: 128 * UNIT, yaw: 0, pitch: -Math.PI / 2 + 0.01, speed: 12 * UNIT };
function home() { Object.assign(cam, { x: 128 * UNIT, y: 30 * UNIT, z: 140 * UNIT, yaw: 0, pitch: -1.2 }); }
function showcaseView() { Object.assign(cam, { x: 22 * UNIT, y: 14 * UNIT, z: 30 * UNIT, yaw: 0, pitch: -0.95 }); }
function topDown() { cam.pitch = -Math.PI / 2 + 0.001; }

const keys = new Set();
addEventListener('keydown', (e) => {
  keys.add(e.code);
  if (e.code === 'KeyT') topDown();
  const q = { Digit1: [64, 64], Digit2: [192, 64], Digit3: [64, 192], Digit4: [192, 192], Digit0: [128, 128] }[e.code];
  if (q) Object.assign(cam, { x: q[0] * UNIT, z: q[1] * UNIT, y: 24 * UNIT, pitch: -Math.PI / 2 + 0.001, yaw: 0 });
});
addEventListener('keyup', (e) => keys.delete(e.code));
addEventListener('blur', () => keys.clear());
canvas.addEventListener('click', () => canvas.requestPointerLock?.());
addEventListener('mousemove', (e) => {
  if (document.pointerLockElement !== canvas) return;
  cam.yaw -= e.movementX * 0.0025;
  cam.pitch = Math.max(-Math.PI / 2 + 0.001, Math.min(Math.PI / 2 - 0.001, cam.pitch - e.movementY * 0.0025));
});
addEventListener('wheel', (e) => { cam.speed = Math.max(UNIT, Math.min(200 * UNIT, cam.speed * (e.deltaY > 0 ? 0.8 : 1.25))); });

function forward() {
  return [-Math.sin(cam.yaw) * Math.cos(cam.pitch), Math.sin(cam.pitch), -Math.cos(cam.yaw) * Math.cos(cam.pitch)];
}

function updateCamera(dt) {
  const f = forward();
  const r = [Math.cos(cam.yaw), 0, -Math.sin(cam.yaw)];
  const s = cam.speed * dt * (keys.has('ShiftLeft') || keys.has('ShiftRight') ? 4 : 1);
  const mv = (v, k) => { cam.x += v[0] * k; cam.y += v[1] * k; cam.z += v[2] * k; };
  if (keys.has('KeyW')) mv(f, s);
  if (keys.has('KeyS')) mv(f, -s);
  if (keys.has('KeyD')) mv(r, s);
  if (keys.has('KeyA')) mv(r, -s);
  if (keys.has('Space')) cam.y += s;
  if (keys.has('KeyC')) cam.y -= s;
}

// ---------------------------------------------------------------- matrices
function perspective(fovy, aspect, near, far) {
  const f = 1 / Math.tan(fovy / 2), nf = 1 / (near - far);
  return [f / aspect, 0, 0, 0, 0, f, 0, 0, 0, 0, (far + near) * nf, -1, 0, 0, 2 * far * near * nf, 0];
}
function lookDir(eye, f) {
  // View matrix for a camera at `eye` looking along unit vector `f`, world up +y.
  // side = f x up, with up = (0, 1, 0).
  let s = [-f[2], 0, f[0]];
  const l = Math.hypot(...s) || 1;
  s = s.map((v) => v / l);
  const u = [s[1] * f[2] - s[2] * f[1], s[2] * f[0] - s[0] * f[2], s[0] * f[1] - s[1] * f[0]];
  const d = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  return [s[0], u[0], -f[0], 0, s[1], u[1], -f[1], 0, s[2], u[2], -f[2], 0, -d(s, eye), -d(u, eye), d(f, eye), 1];
}
function mul(a, b) {
  const o = new Array(16).fill(0);
  for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++) for (let k = 0; k < 4; k++) o[c * 4 + r] += a[k * 4 + r] * b[c * 4 + k];
  return o;
}

// ---------------------------------------------------------------- frame loop
const fpsLog = [];
let last = performance.now(), frames = 0, fpsT = last;
let bench = null;

function resize() {
  const dpr = Math.min(devicePixelRatio || 1, 2);
  const w = Math.floor(canvas.clientWidth * dpr), h = Math.floor(canvas.clientHeight * dpr);
  if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
}

function frame(now) {
  const dt = Math.min(0.1, (now - last) / 1000);
  if (bench) benchStep(now, now - last); else updateCamera(dt);
  last = now;
  resize();
  gl.viewport(0, 0, canvas.width, canvas.height);
  gl.clearColor(0.05, 0.06, 0.08, 1);
  gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
  if (vertexCount && haveStyle) {
    gl.enable(gl.DEPTH_TEST);
    gl.disable(gl.CULL_FACE);
    gl.useProgram(prog);
    const proj = perspective(1.0, canvas.width / canvas.height, 8, 600 * UNIT);
    gl.uniformMatrix4fv(u_mvp, false, mul(proj, lookDir([cam.x, cam.y, cam.z], forward())));
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, atlasTex);
    gl.uniform1i(gl.getUniformLocation(prog, 'u_atlas'), 0);
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, palTex);
    gl.uniform1i(gl.getUniformLocation(prog, 'u_pal'), 1);
    gl.bindVertexArray(vao);
    gl.drawArrays(gl.TRIANGLES, 0, vertexCount);
  }
  frames++;
  if (now - fpsT >= 500) {
    const fps = (frames * 1000) / (now - fpsT);
    $('fps').textContent = `${fps.toFixed(1)} fps · ${canvas.width}x${canvas.height}` + (bench ? ' · benchmarking' : '');
    window.__s1.fps = fps;
    frames = 0; fpsT = now;
  }
  requestAnimationFrame(frame);
}

// Scripted flight: a low, tilted pass over the whole map (worst case for
// overdraw), then a high top-down pass. Reports frame-time percentiles.
function benchStep(now, ft) {
  const t = (now - bench.start) / 1000;
  if (t > 0.5) bench.times.push(ft);
  const dur = bench.duration;
  if (t >= dur) {
    const a = bench.times.slice().sort((x, y) => x - y);
    const pct = (p) => a[Math.min(a.length - 1, Math.floor(a.length * p))];
    const avg = a.reduce((x, y) => x + y, 0) / a.length;
    const res = {
      frames: a.length, avgFps: +(1000 / avg).toFixed(1), medianMs: +pct(0.5).toFixed(2),
      p99Ms: +pct(0.99).toFixed(2), worstMs: +a[a.length - 1].toFixed(2),
      over17ms: a.filter((x) => x > 17.5).length, resolution: `${canvas.width}x${canvas.height}`,
    };
    window.__s1.bench = res;
    console.log('[s1] bench', JSON.stringify(res));
    $('stats').textContent = `benchmark: ${JSON.stringify(res, null, 1)}\n\n` + $('stats').textContent;
    bench = null;
    return;
  }
  const k = t / dur;
  const ang = k * Math.PI * 2;
  if (k < 0.6) {
    Object.assign(cam, { x: (128 + 90 * Math.cos(ang * 1.6)) * UNIT, z: (128 + 90 * Math.sin(ang * 1.6)) * UNIT, y: 12 * UNIT, yaw: -ang * 1.6, pitch: -0.45 });
  } else {
    Object.assign(cam, { x: (40 + 176 * ((k - 0.6) / 0.4)) * UNIT, z: 128 * UNIT, y: 26 * UNIT, yaw: 0, pitch: -Math.PI / 2 + 0.001 });
  }
}
function startBench(duration = 20) { bench = { start: performance.now(), times: [], duration }; }
$('bench').onclick = () => startBench();

window.__s1 = { load, startBench, cam, info: null, fps: 0, bench: null };

// ---------------------------------------------------------------- boot
const params = new URLSearchParams(location.search);
if (params.get('gmp') && params.get('sty')) {
  guarded(async () => {
    await load(await fetchBytes(params.get('gmp')), await fetchBytes(params.get('sty')), `${params.get('gmp')} + ${params.get('sty')}`);
    home();
    if (params.has('bench')) startBench(+params.get('bench') || 20);
  });
} else if (params.has('demo')) {
  $('demo').onclick();
}
requestAnimationFrame(frame);
