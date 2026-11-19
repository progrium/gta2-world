// Headless run of the S3 sandbox with a scripted drifting driver.
// Usage: node headless.mjs   (needs sim.wasm next to it)
import { readFileSync } from "node:fs";
import { instantiate, Sandbox, mulberry32 } from "./net.js";

const sim = instantiate(readFileSync(new URL("./sim.wasm", import.meta.url)));

function driver(seed) {
  const r = mulberry32(seed);
  let steer = 0, hb = 0, until = 0;
  return (t) => {
    if (t >= until) {
      const p = r();
      steer = p < 0.15 ? 0 : (r() < 0.5 ? -1 : 1) * 127;
      hb = r() < 0.3 ? 1 : 0;
      until = t + 300 + r() * 1200;
    }
    return { steer, throttle: 127, buttons: hb };
  };
}

function run(opts, localOnly, seconds = 120, seed = 7) {
  const sb = new Sandbox(sim, opts, 0, seed);
  if (localOnly) sb.setLocalActive(true);
  const drive = driver(seed);
  const frame = 1000 / 60;
  let prev = null, prevD = null;
  const jerks = [];
  let maxOffset = 0;
  for (let i = 1; i <= seconds * 60; i++) {
    const now = i * frame;
    const out = sb.frame(now, drive(now));
    const p = out.shown.own;
    if (prev) {
      const d = { x: p.x - prev.x, y: p.y - prev.y };
      if (prevD && now > 3000) jerks.push(Math.hypot(d.x - prevD.x, d.y - prevD.y));
      prevD = d;
    }
    prev = p;
    const o = sb.client.offset;
    if (!localOnly && now > 3000) maxOffset = Math.max(maxOffset, Math.hypot(o.x, o.y));
  }
  jerks.sort((a, b) => a - b);
  const q = (a, f) => (a.length ? a[Math.min(a.length - 1, Math.floor(a.length * f))] : 0);
  const st = sb.client.stats;
  const errs = st.errs.filter((e) => e.t > 3000).map((e) => e.e).sort((a, b) => a - b);
  return {
    jerkP99: q(jerks, 0.99).toFixed(2),
    jerkMax: q(jerks, 1).toFixed(2),
    jerkOver3: jerks.filter((j) => j > 3).length,
    corrections: errs.length,
    errP50: q(errs, 0.5).toFixed(2),
    errP95: q(errs, 0.95).toFixed(2),
    errMax: q(errs, 1).toFixed(2),
    maxShownOffset: maxOffset.toFixed(2),
    avgReplay: (st.replayTicks / Math.max(1, st.replays)).toFixed(1),
    srvMissing: sb.server.missing,
    lost: sb.up.dropped + "/" + sb.up.sent,
    hardResyncs: st.hardResyncs,
  };
}

const cases = [
  ["local reference, bot wander", {}, true],
  ["net 0ms/0/0%, bot off", { rttMs: 0, jitterMs: 0, lossPct: 0, botMode: "off" }, false],
  ["net 150ms/10/0%, bot off", { rttMs: 150, jitterMs: 10, lossPct: 0, botMode: "off" }, false],
  ["net 150ms/10/2%, bot off", { rttMs: 150, jitterMs: 10, lossPct: 2, botMode: "off" }, false],
  ["net 150ms/10/2%, bot wander", { rttMs: 150, jitterMs: 10, lossPct: 2 }, false],
  ["local reference, bot chase", { botMode: "chase" }, true],
  ["net 150ms/10/2%, bot chase", { rttMs: 150, jitterMs: 10, lossPct: 2, botMode: "chase" }, false],
  ["net 150ms/30/2%, bot chase, buf 1", { rttMs: 150, jitterMs: 30, lossPct: 2, botMode: "chase", bufferTicks: 1 }, false],
  ["net 150ms/10/2%, bot chase, no smoothing", { rttMs: 150, jitterMs: 10, lossPct: 2, botMode: "chase", smoothMs: 0 }, false],
  ["net 250ms/30/5%, bot chase", { rttMs: 250, jitterMs: 30, lossPct: 5, botMode: "chase" }, false],
];
const rows = cases.map(([name, o, l]) => ({ case: name, ...run(o, l) }));
console.table(rows);
