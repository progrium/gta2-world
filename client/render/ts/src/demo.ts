// Demo page for the renderer: loads render-demo.wasm, a map and style
// (synthetic showcase, picked files, or ?gmp=&sty= URLs), runs the traffic
// stub or plays a .grec recording, and draws with the chase camera.
// The shell (workstream E) replaces all of this; only Renderer and the
// cameras are meant to be imported.

import { ChaseCamera, FreeCamera } from './camera.js';
import { INSTANCE_BYTES, Renderer, VERTEX_BYTES, CHUNK_BYTES } from './renderer.js';

const $ = (id: string) => document.getElementById(id)!;
const canvas = $('c') as HTMLCanvasElement;
const renderer = new Renderer(canvas);

type Exports = Record<string, any> & { memory: WebAssembly.Memory };
const { instance } = await WebAssembly.instantiateStreaming(fetch('render-demo.wasm'), {});
const W = instance.exports as Exports;
const u8 = (p: number, n: number) => new Uint8Array(W.memory.buffer, p, n);

function wasmError(): string {
  return new TextDecoder().decode(u8(W.errorPtr(), W.errorLen()));
}
function copyIn(bytes: Uint8Array): number {
  const p = W.alloc(bytes.length);
  if (!p) throw new Error('out of WASM memory');
  u8(p, bytes.length).set(bytes);
  return p;
}
function call(fn: (p: number, n: number, ...rest: any[]) => number, bytes: Uint8Array, ...rest: any[]): void {
  const p = copyIn(bytes);
  const rc = fn(p, bytes.length, ...rest);
  W.free(p, bytes.length);
  if (rc !== 0) throw new Error(wasmError());
}

const chase = new ChaseCamera();
const free = new FreeCamera();
let useFree = false;
let haveWorld = false;
let recordingTicks = 0;
let info: Record<string, unknown> = {};

async function load(gmp: Uint8Array, sty: Uint8Array, label: string, rec?: Uint8Array): Promise<void> {
  $('err').textContent = '';
  const t0 = performance.now();
  call(W.loadStyle, sty);
  const t1 = performance.now();
  call(W.loadMap, gmp, ($('lights') as HTMLInputElement).checked);
  const t2 = performance.now();

  const si = new Uint32Array(W.memory.buffer, W.styleInfo(), 18).slice();
  renderer.setStyle({
    tiles: u8(W.tilesPtr(), W.tilesLen()),
    spritePages: u8(W.spritePagesPtr(), W.spritePagesLen()),
    ppal: u8(W.ppalPtr(), W.ppalLen()),
    palx: new Uint16Array(W.memory.buffer, W.palxPtr(), 16384),
    spriteTable: new Uint16Array(W.memory.buffer, W.spriteTablePtr(), W.spriteTableRows() * 64 * 4),
    tilePaletteBase: si[4],
    spritePaletteBase: si[5],
  });
  renderer.setMap({
    vertices: u8(W.vertexPtr(), W.vertexCount() * VERTEX_BYTES),
    chunks: u8(W.chunkPtr(), W.chunkCount() * CHUNK_BYTES),
    anims: new Uint16Array(W.memory.buffer, W.animPtr(), W.animLen()),
  });
  const t3 = performance.now();

  if (rec) {
    const p = copyIn(rec); // the module keeps it
    if (W.loadRecording(p, rec.length) !== 0) throw new Error(wasmError());
    recordingTicks = W.recordingTicks();
  } else {
    recordingTicks = 0;
    const cars = +(new URLSearchParams(location.search).get('cars') ?? 40);
    const peds = +(new URLSearchParams(location.search).get('peds') ?? 100);
    if (W.stubStart(1, cars, peds) !== 0) throw new Error(wasmError());
  }
  haveWorld = true;
  chase.reset();
  tick = 0;
  acc = 0;

  const mi = new Uint32Array(W.memory.buffer, W.meshInfo(), 8);
  info = {
    label, styleParseMs: +(t1 - t0).toFixed(1), mapParseMeshMs: +(t2 - t1).toFixed(1), uploadMs: +(t3 - t2).toFixed(1),
    triangles: mi[0], hiddenFaces: mi[5], lights: mi[6], blockDefs: mi[7], sprites: si[2],
    tileLayers: si[0], spriteLayers: si[1], entities: recordingTicks ? `recording, ${recordingTicks} ticks` : 'traffic stub',
  };
  (window as any).__render.info = info;
  $('stats').textContent = Object.entries(info).map(([k, v]) => `${k}: ${v}`).join('\n');
  console.log('[render] loaded', JSON.stringify(info));
}

async function fetchBytes(url: string): Promise<Uint8Array> {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${url}: HTTP ${r.status}`);
  return new Uint8Array(await r.arrayBuffer());
}
async function guarded(f: () => Promise<void>): Promise<void> {
  try { await f(); } catch (e: any) { $('err').textContent = String(e?.message ?? e); console.error('[render]', e); }
}
const fileBytes = async (id: string) => {
  const f = ($(id) as HTMLInputElement).files?.[0];
  return f ? { name: f.name, bytes: new Uint8Array(await f.arrayBuffer()) } : null;
};

$('load').onclick = () => guarded(async () => {
  const g = await fileBytes('gmp'), s = await fileBytes('sty'), r = await fileBytes('rec');
  if (!g || !s) throw new Error('Pick both a .gmp and a .sty file.');
  await load(g.bytes, s.bytes, `${g.name} + ${s.name}`, r?.bytes);
});
$('demo').onclick = () => guarded(async () => {
  await load(await fetchBytes('fixtures/showcase.gmp'), await fetchBytes('fixtures/showcase.sty'), 'synthetic showcase');
});
$('toggle').onclick = () => { for (const id of ['help', 'stats']) $(id).classList.toggle('hide'); };

// ------------------------------------------------------------ input
const keys = new Set<string>();
addEventListener('keydown', (e) => {
  keys.add(e.code);
  if (e.code === 'KeyF') {
    useFree = !useFree;
    if (useFree) { const v = chase.view(); Object.assign(free, { x: v.eye[0], y: v.eye[1] + 6, z: v.eye[2], yaw: 0, pitch: -1.1 }); }
  }
  if (e.code === 'KeyN') {
    const night = renderer.lighting.ambient > 0.6;
    renderer.lighting = night ? { ambient: 0.35, lightGain: 1.0 } : { ambient: 1.0, lightGain: 0.35 };
  }
  if (e.code === 'KeyP') paused = !paused;
});
addEventListener('keyup', (e) => keys.delete(e.code));
addEventListener('blur', () => keys.clear());
canvas.addEventListener('click', () => { if (useFree) canvas.requestPointerLock?.(); });
addEventListener('mousemove', (e) => {
  if (!useFree || document.pointerLockElement !== canvas) return;
  free.yaw += e.movementX * 0.0025;
  free.pitch = Math.max(-Math.PI / 2 + 0.001, Math.min(0.5, free.pitch - e.movementY * 0.0025));
});

function moveFree(dt: number): void {
  const s = dt * 20 * (keys.has('ShiftLeft') ? 4 : 1);
  free.move((keys.has('KeyW') ? s : 0) - (keys.has('KeyS') ? s : 0), (keys.has('KeyD') ? s : 0) - (keys.has('KeyA') ? s : 0),
    (keys.has('Space') ? s : 0) - (keys.has('KeyC') ? s : 0));
}

// ------------------------------------------------------------ loop
const TICK = 1 / 30;
let tick = 0;
let acc = 0;
let paused = false;
let last = performance.now();
let frames = 0, fpsT = last;
let bench: { start: number; dur: number; times: number[] } | null = null;

function frame(now: number): void {
  const dt = Math.min(0.1, (now - last) / 1000);
  if (bench) bench.times.push(now - last);
  last = now;
  renderer.resize(canvas.clientWidth, canvas.clientHeight, devicePixelRatio || 1);

  let count = 0;
  if (haveWorld) {
    if (!paused) acc += dt;
    while (acc >= TICK) {
      acc -= TICK;
      if (recordingTicks) tick = (tick + 1) % recordingTicks;
      else { W.stubStep(); tick++; }
    }
    const alpha = acc / TICK;
    count = W.buildList(tick, alpha);
    const t = new Float32Array(W.memory.buffer, W.cameraTarget(tick, alpha, 0), 8);
    if (t[6] !== 0) chase.update({ x: t[0], y: t[1], z: t[2], speed: Math.hypot(t[4], t[5]) * 30 }, dt);
    else chase.update({ x: 128, y: 128, z: 2, speed: 0 }, dt);
  }
  if (useFree) moveFree(dt);
  const view = useFree ? free.view() : chase.view();
  const st = renderer.draw(view, haveWorld ? u8(W.instancePtr(), count * INSTANCE_BYTES) : null, count, now / 1000);

  frames++;
  if (now - fpsT >= 500) {
    const fps = (frames * 1000) / (now - fpsT);
    $('fps').textContent = `${fps.toFixed(1)} fps · ${canvas.width}x${canvas.height} · chunks ${st.chunksDrawn} · calls ${st.drawCalls} · tris ${st.triangles} · sprites ${st.sprites} · cam ${chase.height.toFixed(1)}`;
    (window as any).__render.fps = fps;
    frames = 0; fpsT = now;
  }
  if (bench && now - bench.start >= bench.dur * 1000) finishBench();
  requestAnimationFrame(frame);
}

function finishBench(): void {
  const a = bench!.times.slice(10).sort((x, y) => x - y);
  bench = null;
  const pct = (p: number) => a[Math.min(a.length - 1, Math.floor(a.length * p))];
  const avg = a.reduce((x, y) => x + y, 0) / a.length;
  const res = {
    frames: a.length, avgFps: +(1000 / avg).toFixed(1), medianMs: +pct(0.5).toFixed(2), p99Ms: +pct(0.99).toFixed(2),
    worstMs: +a[a.length - 1].toFixed(2), over17ms: a.filter((x) => x > 17.5).length, resolution: `${canvas.width}x${canvas.height}`,
  };
  (window as any).__render.bench = res;
  console.log('[render] bench', JSON.stringify(res));
  $('stats').textContent = `benchmark: ${JSON.stringify(res, null, 1)}\n\n` + $('stats').textContent;
}
function startBench(dur = 20): void { bench = { start: performance.now(), dur, times: [] }; }
$('bench').onclick = () => startBench();

(window as any).__render = { load, renderer, chase, free, startBench, W, tick: () => tick, info: null, fps: 0, bench: null, setFree: (v: boolean) => { useFree = v; } };

// ------------------------------------------------------------ boot
const params = new URLSearchParams(location.search);
if (params.get('gmp') && params.get('sty')) {
  guarded(async () => {
    const rec = params.get('rec') ? await fetchBytes(params.get('rec')!) : undefined;
    await load(await fetchBytes(params.get('gmp')!), await fetchBytes(params.get('sty')!), `${params.get('gmp')} + ${params.get('sty')}`, rec);
    if (params.has('night')) renderer.lighting = { ambient: 0.35, lightGain: 1.0 };
    if (params.has('bench')) startBench(+(params.get('bench') || 20));
  });
} else if (params.has('demo')) {
  ($('demo') as HTMLButtonElement).click();
}
requestAnimationFrame(frame);
