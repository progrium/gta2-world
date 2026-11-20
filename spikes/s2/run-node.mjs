// node run-node.mjs  — WASM replay check + bench under Node (V8, same engine as Chrome).
import { readFileSync } from 'node:fs';
import { instantiate, replay, bench, fmt } from './web/s2.js';

const dir = new URL('./web/', import.meta.url);
const ex = await instantiate(readFileSync(new URL('s2.wasm', dir)));
const inputs = new Uint8Array(readFileSync(new URL('replay/inputs.bin', dir)));
const hashes = new Uint8Array(readFileSync(new URL('replay/hashes.bin', dir)));
const r = replay(ex, inputs, hashes, console.log);
console.log('replay', JSON.stringify(r));
console.log(fmt(bench(ex, 16)));
console.log(fmt(bench(ex, 200)));
ex.s2_init(200);
for (let i = 0; i < 10000; i++) ex.s2_step_bots();
console.log('200-player 10000-tick final hash ' + BigInt.asUintN(64, ex.s2_hash()).toString(16).padStart(16, '0'));
if (!r.ok) process.exit(1);
