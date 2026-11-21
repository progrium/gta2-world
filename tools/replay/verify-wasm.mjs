// Golden replay under WASM:
//   node verify-wasm.mjs <replay.wasm> <golden-dir> [native-hash200] [--bench]
// A one-player recording (golden-sp) runs the single-player configuration
// with the script built into the module.
// Replays inputs.bin (frames and commands) and compares hash() every tick
// with the natively recorded hashes.bin, with a save/run-ahead/load rewind
// every 100 ticks. Optionally checks a 200-bot run's final hash against the
// native one, and times the 16-player step. Exits non-zero on any mismatch.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const args = process.argv.slice(2);
const bench = args.includes('--bench');
const [wasmPath, dir, want200] = args.filter((a) => a !== '--bench');
if (!wasmPath || !dir) { console.error('usage: node verify-wasm.mjs <replay.wasm> <dir> [hash200] [--bench]'); process.exit(2); }
const { instance } = await WebAssembly.instantiate(readFileSync(wasmPath), {});
const ex = instance.exports;
const hex = (v) => BigInt.asUintN(64, v).toString(16).padStart(16, '0');

const inputs = new Uint8Array(readFileSync(join(dir, 'inputs.bin')));
const hb = new Uint8Array(readFileSync(join(dir, 'hashes.bin')));
const want = new BigUint64Array(hb.buffer, hb.byteOffset, hb.byteLength / 8);
const dv = new DataView(inputs.buffer, inputs.byteOffset, inputs.byteLength);
if (String.fromCharCode(...inputs.subarray(0, 4)) !== 'G2RP' || dv.getUint32(4, true) !== 1) { console.error('bad replay header'); process.exit(1); }
const seed = dv.getBigUint64(8, true);
const players = dv.getUint32(16, true);
const ticks = dv.getUint32(20, true);
const gridHash = dv.getBigUint64(24, true);

ex.rp_init(players === 1 ? 1 : 16, Number(seed & 0xffffffffn), Number(seed >> 32n));
if (BigInt.asUintN(64, ex.rp_grid_hash()) !== gridHash) { console.error('replay recorded on a different map'); process.exit(1); }
if (BigInt.asUintN(64, ex.rp_hash()) !== want[0]) { console.error(`mismatch at init: ${hex(ex.rp_hash())} vs ${hex(want[0])}`); process.exit(1); }

// Index the ticks: offset of each tick's record.
const offs = new Array(ticks);
let p = 32;
for (let t = 0; t < ticks; t++) { offs[t] = p; p += 1 + inputs[p] * 8 + players * 8; }
const mem = () => new Uint8Array(ex.memory.buffer);
const framesPtr = ex.rp_frames_ptr();
const cmdsPtr = ex.rp_cmds_ptr();
function stepTick(t) {
  const o = offs[t];
  const n = inputs[o];
  const m = mem();
  m.set(inputs.subarray(o + 1, o + 1 + n * 8), cmdsPtr);
  m.set(inputs.subarray(o + 1 + n * 8, o + 1 + n * 8 + players * 8), framesPtr);
  ex.rp_step(n);
}
let rewinds = 0;
const t0 = performance.now();
for (let t = 0; t < ticks; t++) {
  if (t % 100 === 50 && t + 10 < ticks) {
    ex.rp_save();
    for (let k = 0; k < 10; k++) stepTick(t + k);
    ex.rp_load();
    rewinds++;
  }
  stepTick(t);
  const h = BigInt.asUintN(64, ex.rp_hash());
  if (h !== want[t + 1]) { console.error(`WASM hash mismatch at tick ${t + 1}: got ${hex(h)} want ${hex(want[t + 1])}`); process.exit(1); }
}
console.log(`WASM replay OK: ${ticks} ticks, ${rewinds} rewinds, final ${hex(want[ticks])}, ${(performance.now() - t0).toFixed(0)} ms`);

if (want200) {
  ex.rp_init(200, Number(0x6A25EEDn & 0xffffffffn), 0);
  for (let i = 0; i < 10000; i++) ex.rp_step_bots();
  const got = hex(ex.rp_hash());
  console.log(`200-player 10000-tick final hash ${got}`);
  if (got !== want200) { console.error(`200-player hash mismatch: wasm ${got} native ${want200}`); process.exit(1); }
}

if (bench) {
  ex.rp_init(16, Number(0x6A25EEDn & 0xffffffffn), 0);
  for (let i = 0; i < 300; i++) ex.rp_step_bots();
  const n = 5000;
  const b0 = performance.now();
  for (let i = 0; i < n; i++) ex.rp_step_bots();
  const per = (performance.now() - b0) / n;
  ex.rp_save();
  const r0 = performance.now();
  for (let r = 0; r < 200; r++) { ex.rp_save(); for (let k = 0; k < 10; k++) ex.rp_step_bots(); ex.rp_load(); }
  const rep = (performance.now() - r0) / 200;
  console.log(`WASM dm16 step (bots included): ${per.toFixed(4)} ms; save + 10-tick replay + load: ${rep.toFixed(4)} ms`);
}
console.log('WASM golden replay OK');
