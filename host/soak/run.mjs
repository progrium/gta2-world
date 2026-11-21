#!/usr/bin/env node
// Host soak. Build host.wasm first (cd host && zig build) and install the
// shell's npm deps (cd client/shell && npm ci), then:
//
//   node host/soak/run.mjs node    [--players 2,4,8,16] [--seconds 30] [--map FILE.gmp] [--replay-dir DIR]
//   node host/soak/run.mjs browser [--players 2,4,8,16] [--seconds 30] [--map FILE.gmp]
//   (both: --wasm FILE to test another build, e.g. -Dsim=stub)
//
// node:    host.wasm in-process on a virtual clock (pure compute cost, and a
//          protocol check; --replay-dir writes each run's .g2wr so
//          `gta2-server replay` can re-run it natively).
// browser: the real host Worker (client/shell/src/host/worker.ts) in headless
//          Chromium on its own real-time clock, synthetic players on the
//          page's main thread, cross-origin isolated (5 us timers).
//
// Without --map both use the server's synthetic city (no game data). With
// --map, the file is read from wherever you keep it and served from memory;
// nothing is copied into the repo.

import { mkdtempSync, readFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "../..");
const require = createRequire(join(repo, "client/shell/package.json"));
const esbuild = require("esbuild");

const args = process.argv.slice(2);
const mode = args[0];
const opt = (name, def) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : def;
};
const counts = opt("players", "2,4,8,16").split(",").map(Number);
const seconds = Number(opt("seconds", "30"));
const mapFile = opt("map", null);
const replayDir = opt("replay-dir", null);
const wasmPath = resolve(opt("wasm", join(repo, "host/zig-out/web/host.wasm")));
const out = mkdtempSync(join(tmpdir(), "host-soak-"));

const pct = (xs, p) => {
  if (!xs.length) return 0;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor((s.length * p) / 100))];
};
const median = (xs) => pct(xs, 50);
const max = (xs) => xs.reduce((a, b) => Math.max(a, b), 0);
const sum = (xs) => xs.reduce((a, b) => a + b, 0);

/** One table row from the 1-second stats windows (after a 3 s warm-up). */
function summarize(players, windows, extra = {}) {
  const w = windows.slice(3);
  const bps = w.flatMap((x) => x.peers.map((p) => p.txBps));
  return {
    players,
    windows: w.length,
    stepP50: median(w.map((x) => x.stepUsP50)),
    stepP99: median(w.map((x) => x.stepUsP99)),
    stepP99Worst: max(w.map((x) => x.stepUsP99)),
    stepMax: max(w.map((x) => x.stepUsMax)),
    encP50: median(w.map((x) => x.encodeUsP50)),
    encP99: median(w.map((x) => x.encodeUsP99)),
    encP99Worst: max(w.map((x) => x.encodeUsP99)),
    behind: sum(w.map((x) => x.behindTicks)),
    skipped: sum(w.map((x) => x.skippedTicks)),
    ticks: sum(w.map((x) => x.ticks)),
    txKbpsPerPeer: bps.length ? median(bps) * 8 / 1000 : 0,
    ...extra,
  };
}

const f1 = (v) => v.toFixed(1);
function table(rows, browser) {
  const head = browser
    ? "| players | step p50 us | step p99 us (median / worst 1 s) | step max us | encode p50 us | encode p99 us (median / worst) | ticks | behind ticks | skipped | input timer late p99 ms | down kbit/s per peer |"
    : "| players | step p50 us | step p99 us (median / worst 1 s) | step max us | encode p50 us | encode p99 us (median / worst) | ticks | wall time for the run |";
  const sep = head.replace(/[^|]+/g, "---");
  const lines = rows.map((r) => browser
    ? `| ${r.players} | ${f1(r.stepP50)} | ${f1(r.stepP99)} / ${f1(r.stepP99Worst)} | ${f1(r.stepMax)} | ${f1(r.encP50)} | ${f1(r.encP99)} / ${f1(r.encP99Worst)} | ${r.ticks} | ${r.behind} | ${r.skipped} | ${f1(r.inputLateP99)} | ${f1(r.txKbpsPerPeer)} |`
    : `| ${r.players} | ${f1(r.stepP50)} | ${f1(r.stepP99)} / ${f1(r.stepP99Worst)} | ${f1(r.stepMax)} | ${f1(r.encP50)} | ${f1(r.encP99)} / ${f1(r.encP99Worst)} | ${r.ticks} | ${(r.wallMs / 1000).toFixed(1)} s |`);
  return [head, sep, ...lines].join("\n");
}

async function bundle(entry, outfile, platform) {
  await esbuild.build({ entryPoints: [entry], bundle: true, format: "esm", target: "es2022", platform, outfile, logLevel: "warning" });
}

async function nodeMode() {
  const js = join(out, "node.mjs");
  await bundle(join(here, "node.ts"), js, "node");
  const { runNode } = await import(pathToFileURL(js).href);
  const rows = [];
  let failed = false;
  for (const n of counts) {
    const replayOut = replayDir ? join(replayDir, `soak-${n}p.g2wr`) : undefined;
    const r = await runNode({ wasm: wasmPath, map: mapFile ?? undefined, players: n, seconds, replayOut });
    if (!r.ok) {
      failed = true;
      console.error(`${n} players: ${r.problems.join("; ")}`);
    }
    rows.push(summarize(n, r.windows, { wallMs: r.wallMs }));
    console.error(`${n} players: ${r.ok ? "ok" : "PROBLEMS"}, ${r.windows.length} s simulated in ${(r.wallMs / 1000).toFixed(1)} s, replay ${r.replayBytes} bytes${replayOut ? " -> " + replayOut : ""}`);
  }
  // maxPlayers below the sim's slots: the extra player gets reject 4.
  const cap = await runNode({ wasm: wasmPath, map: mapFile ?? undefined, players: 3, seconds: 2, maxPlayers: 2 });
  console.error(`maxPlayers 2 with 3 players: ${cap.ok ? "ok, third rejected" : cap.problems.join("; ")}`);
  failed ||= !cap.ok;
  console.log(table(rows, false));
  if (failed) process.exit(1);
}

async function browserMode() {
  const { chromium } = require("playwright");
  await bundle(join(repo, "client/shell/src/host/worker.ts"), join(out, "host-worker.js"), "browser");
  await bundle(join(here, "page.ts"), join(out, "page.js"), "browser");
  let map;
  if (mapFile) map = readFileSync(mapFile);
  else {
    const js = join(out, "synth.mjs");
    await esbuild.build({ stdin: { contents: `export { HostModule } from ${JSON.stringify(join(repo, "client/shell/src/host/wasm.ts"))};`, resolveDir: here, loader: "ts" }, bundle: true, format: "esm", platform: "node", outfile: js, logLevel: "warning" });
    const { HostModule } = await import(pathToFileURL(js).href);
    map = (await HostModule.instantiate(readFileSync(wasmPath), () => 0)).synthMap();
  }
  const files = {
    "/soak.html": ["text/html", Buffer.from('<!doctype html><meta charset="utf-8"><title>host soak</title><script type="module" src="./page.js"></script>')],
    "/page.js": ["text/javascript", readFileSync(join(out, "page.js"))],
    "/host-worker.js": ["text/javascript", readFileSync(join(out, "host-worker.js"))],
    "/host.wasm": ["application/wasm", readFileSync(wasmPath)],
    "/map.gmp": ["application/octet-stream", map],
  };
  const server = createServer((req, res) => {
    const f = files[new URL(req.url, "http://x").pathname];
    if (!f) return res.writeHead(404).end();
    // Cross-origin isolation: performance.now() resolution 5 us instead of 100 us.
    res.writeHead(200, { "content-type": f[0], "cross-origin-opener-policy": "same-origin", "cross-origin-embedder-policy": "require-corp", "cache-control": "no-store" });
    res.end(f[1]);
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const port = server.address().port;
  const browser = await chromium.launch();
  console.error(`chromium ${browser.version()}`);
  const rows = [];
  let failed = false;
  try {
    for (const n of counts) {
      const page = await browser.newPage();
      page.on("console", (m) => { if (m.type() === "error" || m.type() === "warning") console.error(`  page: ${m.text()}`); });
      await page.goto(`http://127.0.0.1:${port}/soak.html?players=${n}&seconds=${seconds}&record=1`);
      await page.waitForFunction(() => window.__soak || window.__soakError, null, { timeout: (seconds + 60) * 1000, polling: 500 });
      const err = await page.evaluate(() => window.__soakError);
      if (err) throw new Error(err);
      const r = await page.evaluate(() => window.__soak);
      await page.close();
      if (r.problems.length) {
        failed = true;
        console.error(`${n} players: ${r.problems.join("; ")}`);
      }
      rows.push(summarize(n, r.windows, { inputLateP99: pct(r.inputLateMs, 99) }));
      console.error(`${n} players: ${r.problems.length ? "PROBLEMS" : "ok"}, ${r.windows.length} stats windows, crossOriginIsolated=${r.crossOriginIsolated}, replay ${r.replayBytes} bytes`);
    }
  } finally {
    await browser.close();
    server.close();
  }
  console.log(table(rows, true));
  if (failed) process.exit(1);
}

if (mode === "node") await nodeMode();
else if (mode === "browser") await browserMode();
else {
  console.error("usage: node host/soak/run.mjs node|browser [--players 2,4,8,16] [--seconds 30] [--map FILE.gmp] [--replay-dir DIR]");
  process.exit(2);
}
