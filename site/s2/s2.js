// Spike S2 harness shared by the Node runner and the browser page.
// Runs: (1) 10,000-tick replay of recorded inputs, comparing hash() every tick
// against hashes recorded natively, with a save/step/load rewind every 100
// ticks; (2) step-time bench for the 16- and 200-player configs.

const now = () => performance.now();

export async function instantiate(wasmBytes) {
  const { instance } = await WebAssembly.instantiate(wasmBytes, {});
  return instance.exports;
}

export function replay(ex, inputs, hashes, log) {
  const players = 16;
  ex.s2_init(16);
  const mem = () => new Uint8Array(ex.memory.buffer);
  const want = new BigUint64Array(hashes.buffer, hashes.byteOffset, hashes.byteLength / 8);
  const ticks = inputs.byteLength / (players * 8);
  const mapHash = BigInt.asUintN(64, ex.s2_map_hash());
  log(`map hash ${mapHash.toString(16).padStart(16, '0')}`);
  if (BigInt.asUintN(64, ex.s2_hash()) !== want[0]) return { ok: false, tick: 0 };
  const ptr = ex.s2_input_ptr();
  const setInputs = (t) => mem().set(inputs.subarray(t * players * 8, (t + 1) * players * 8), ptr);
  let rewinds = 0;
  const t0 = now();
  for (let t = 0; t < ticks; t++) {
    if (t % 100 === 50 && t + 10 < ticks) {
      ex.s2_save();
      for (let k = 0; k < 10; k++) { setInputs(t + k); ex.s2_step_inputs(); }
      ex.s2_load();
      rewinds++;
    }
    setInputs(t);
    ex.s2_step_inputs();
    const h = BigInt.asUintN(64, ex.s2_hash());
    if (h !== want[t + 1]) {
      return { ok: false, tick: t + 1, got: h.toString(16), want: want[t + 1].toString(16) };
    }
  }
  const final = want[ticks].toString(16).padStart(16, '0');
  return { ok: true, ticks, rewinds, final, ms: now() - t0 };
}

function stats(times) {
  const s = Float64Array.from(times).sort();
  const mean = s.reduce((a, b) => a + b, 0) / s.length;
  return { mean, p50: s[s.length >> 1], p99: s[Math.floor(s.length * 0.99)], max: s[s.length - 1] };
}

// Browser timers are coarse (Firefox/Safari clamp performance.now to 0.1 ms or
// more without cross-origin isolation), so the per-tick mean is measured over
// batches of ticks; the per-tick distribution is reported too but is only
// meaningful where the timer is fine-grained.
export function bench(ex, cfg, ticks = 10000, batch = 100) {
  ex.s2_init(cfg);
  for (let i = 0; i < 300; i++) ex.s2_step_bots();
  const batches = [];
  const singles = [];
  for (let b = 0; b < ticks / batch; b++) {
    const t0 = now();
    for (let i = 0; i < batch; i++) ex.s2_step_bots();
    batches.push((now() - t0) / batch);
  }
  for (let i = 0; i < 2000; i++) {
    const t0 = now();
    ex.s2_step_bots();
    singles.push(now() - t0);
  }
  // Rewind cost: save, step 10, load (as a client correcting a misprediction).
  const reps = 500;
  let tReplay = 0, tSave = 0, tLoad = 0, tHash = 0;
  for (let r = 0; r < reps; r++) {
    let t0 = now(); ex.s2_save(); tSave += now() - t0;
    t0 = now();
    for (let k = 0; k < 10; k++) ex.s2_step_bots();
    tReplay += now() - t0;
    t0 = now(); ex.s2_load(); tLoad += now() - t0;
    t0 = now(); ex.s2_hash(); tHash += now() - t0;
  }
  const bm = stats(batches);
  return {
    cfg,
    state_bytes: ex.s2_state_size(),
    cars: ex.s2_counts(0), peds: ex.s2_counts(1), shots: ex.s2_counts(2),
    step_mean_ms: bm.mean,
    step_worst_batch_ms: bm.max,
    single: stats(singles),
    replay10_ms: tReplay / reps,
    save_ms: tSave / reps, load_ms: tLoad / reps, hash_ms: tHash / reps,
  };
}

export function fmt(r) {
  const f = (x) => x.toFixed(4);
  return `config ${r.cfg}: state ${r.state_bytes} B, cars ${r.cars} peds ${r.peds} shots ${r.shots}\n` +
    `  step mean ${f(r.step_mean_ms)} ms (worst 100-tick batch avg ${f(r.step_worst_batch_ms)})\n` +
    `  single-tick p50 ${f(r.single.p50)} p99 ${f(r.single.p99)} max ${f(r.single.max)} ms (timer-resolution limited)\n` +
    `  10-tick replay ${f(r.replay10_ms)} ms; save ${f(r.save_ms)} load ${f(r.load_ms)} hash ${f(r.hash_ms)} ms`;
}
