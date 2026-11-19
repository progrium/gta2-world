// CI golden replay under Node: node ci-replay-wasm.mjs <s2.wasm> <replay-dir> [expected-200p-hash]
// Replays the recorded 16-player inputs in WASM and compares hash() every tick
// against the recorded native hashes; optionally checks the 200-player bot run's
// final hash against the native one. Exits non-zero on any mismatch.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { instantiate, replay } from './web/s2.js';

const [wasmPath, dir, want200] = process.argv.slice(2);
if (!wasmPath || !dir) { console.error('usage: node ci-replay-wasm.mjs <s2.wasm> <replay-dir> [hash200]'); process.exit(2); }
const ex = await instantiate(readFileSync(wasmPath));
const inputs = new Uint8Array(readFileSync(join(dir, 'inputs.bin')));
const hashes = new Uint8Array(readFileSync(join(dir, 'hashes.bin')));
const r = replay(ex, inputs, hashes, console.log);
console.log('replay', JSON.stringify(r));
if (!r.ok) { console.error(`WASM hash mismatch at tick ${r.tick}: got ${r.got} want ${r.want}`); process.exit(1); }

ex.s2_init(200);
for (let i = 0; i < 10000; i++) ex.s2_step_bots();
const got200 = BigInt.asUintN(64, ex.s2_hash()).toString(16).padStart(16, '0');
console.log('200-player 10000-tick final hash ' + got200);
if (want200 && got200 !== want200) { console.error(`200-player hash mismatch: wasm ${got200} native ${want200}`); process.exit(1); }
console.log('WASM golden replay OK');
