// Browser test for browser-hosted games: two pages in one Chromium context,
// page A hosts (fake host Worker), page B joins over BroadcastChannel
// signalling and WebRTC data channels.
//
//   node test/e2e/rtc.e2e.mjs        (from client/shell; needs npm ci and Playwright)
//
// Builds the shell and the harness into a temp folder, serves it on
// 127.0.0.1 (a secure context, for OPFS and crypto.subtle), and checks:
//   - channels s, d (unordered, no retransmits) and f open
//   - the host Worker sees opened + hello with transport 2, for the joiner and the loopback
//   - a datagram round trip on WebRTC and on the loopback; a 1200-byte datagram is dropped
//   - the lobby sends a random-bytes file pair with SHA-256 checks, the joiner
//     keeps them in its asset store (read back and re-hashed)
//   - with sharing off the joiner is told which file is missing
//   - a peer leaving reaches the Worker as "closed"
//   - UI: Host a game -> join link -> join screen in the second page
// With dist/host-worker.js present it also checks that the real Worker answers "start".

import { build } from "esbuild";
import { createServer } from "node:http";
import { cpSync, existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";
import assert from "node:assert/strict";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright");

const here = dirname(fileURLToPath(import.meta.url));
const shell = join(here, "..", "..");
const root = mkdtempSync(join(tmpdir(), "gta2-e2e-"));
mkdirSync(join(root, "dist"));
mkdirSync(join(root, "e2e"));

// --- build -------------------------------------------------------------------
const common = { bundle: true, format: "esm", target: "es2022", logLevel: "warning" };
await build({ ...common, entryPoints: [join(shell, "src/main.ts"), join(shell, "src/assets/worker.ts")], outdir: join(root, "dist"), entryNames: "[name]" });
await build({ ...common, entryPoints: { harness: join(here, "harness.ts"), "fake-host-worker": join(here, "fakeHostWorker.ts") }, outdir: join(root, "e2e") });
cpSync(join(shell, "index.html"), join(root, "index.html"));
cpSync(join(shell, "styles.css"), join(root, "styles.css"));
writeFileSync(join(root, "e2e/index.html"), `<!doctype html><meta charset="utf-8"><title>e2e</title><script type="module" src="harness.js"></script>`);
const realHost = join(shell, "dist/host-worker.js");
if (existsSync(realHost)) cpSync(realHost, join(root, "dist/host-worker.js"));
for (const f of ["dist/game.wasm"]) if (existsSync(join(shell, f))) cpSync(join(shell, f), join(root, f));

// --- serve -------------------------------------------------------------------
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".wasm": "application/wasm", ".map": "application/json" };
const server = createServer((req, res) => {
  const path = normalize(decodeURIComponent(new URL(req.url, "http://x").pathname)).replace(/^\/+/, "") || "index.html";
  const file = join(root, path);
  if (!file.startsWith(root) || !existsSync(file)) {
    res.writeHead(404).end();
    return;
  }
  res.writeHead(200, { "content-type": types[extname(file)] ?? "application/octet-stream" }).end(readFileSync(file));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;

// --- run ---------------------------------------------------------------------
const browser = await chromium.launch();
const ctx = await browser.newContext();
const log = (m) => console.log(m);
let failures = 0;
const step = async (name, f) => {
  try {
    await f();
    log(`ok   ${name}`);
  } catch (e) {
    failures++;
    log(`FAIL ${name}\n     ${e?.stack ?? e}`);
  }
};

try {
  const fake = "hostWorker=/e2e/fake-host-worker.js";
  const a = await ctx.newPage();
  const b = await ctx.newPage();
  for (const [n, p] of [["A", a], ["B", b]]) p.on("console", (m) => (process.env.E2E_DEBUG || m.type() === "error") && log(`  [${n}] ${m.text()}`));
  await a.goto(`${base}/e2e/index.html?${fake}`);
  await b.goto(`${base}/e2e/index.html`);
  await a.waitForFunction(() => window.e2eReady);
  await b.waitForFunction(() => window.e2eReady);
  await b.evaluate(() => window.e2e.clearStore());

  let hosted;
  await step("host starts the Worker and its loopback player connects", async () => {
    hosted = await a.evaluate(() => window.e2e.host(true));
    assert.equal(hosted.ready.t, "ready");
    assert.equal(hosted.loopTransport, "loopback");
    assert.equal(hosted.loopRtt, true, "loopback datagram round trip");
    assert.match(hosted.hash, /^#join\/[a-z2-7]{8}\.[0-9a-f]{12}$/);
  });

  let joined;
  await step("joiner connects over WebRTC, downloads and verifies files, plays", async () => {
    const [, room, h12] = /^#join\/([a-z2-7]{8})\.([0-9a-f]{12})$/.exec(hosted.hash);
    joined = await b.evaluate(([r, h, m]) => window.e2e.join(r, h, m), [room, h12, hosted.mapHash]);
    log(`     joined in ${joined.ms} ms`);
    assert.deepEqual(
      { s: joined.channels.s, d: joined.channels.d, f: joined.channels.f, ordered: joined.channels.dOrdered, rt: joined.channels.dRetransmits },
      { s: "open", d: "open", f: "open", ordered: false, rt: 0 },
    );
    assert.ok(joined.channels.maxDatagram <= 1100);
    assert.equal(joined.lobby.ok, true, JSON.stringify(joined.lobby));
    assert.equal(joined.lobby.downloaded.length, 2);
    assert.ok(joined.progressEvents >= Math.ceil((300_000 + 70_001) / 16384), "progress per 16 KB chunk");
    for (const f of hosted.files) {
      const s = joined.stored.find((x) => x.hash === f.sha256);
      assert.ok(s, `${f.name} kept in the asset store`);
      assert.equal(s.size, f.size);
      assert.equal(s.readBack, f.sha256, "bytes read back from the store hash to the SHA-256");
    }
    assert.equal(joined.transport, "webrtc");
    assert.equal(joined.welcome.configName, "fake t2", "the Worker decoded hello.transport 2");
    assert.equal(joined.rtt, true, "datagram round trip over channel d");
    assert.equal(joined.capped, true, "a datagram over 1100 bytes is dropped");
  });

  await step("host Worker saw opened + hello with transport 2 for both players", async () => {
    const hl = await a.evaluate(() => window.e2e.hostLog());
    const opened = hl.filter((l) => l.t === "opened");
    assert.equal(opened.length, 2);
    assert.ok(opened.every((o) => o.transport === 2));
    const peers = await a.evaluate(() => window.e2e.hostPeers());
    const remote = peers.find((p) => p.kind === "webrtc");
    assert.ok(remote, JSON.stringify(peers));
    assert.equal(remote.transport, 2, "hello.transport");
    assert.equal(remote.name, "joiner");
    assert.equal(remote.state, "in game");
    assert.equal(remote.lobby, "ready");
    assert.ok(remote.dIn >= 1 && remote.dOut >= 1);
    assert.ok(hl.some((l) => l.t === "datagram" && l.peer === remote.id));
    assert.ok(!hl.some((l) => l.t === "datagram" && l.size > 1100), "no datagram over the cap reached the Worker");
  });

  await step("a peer leaving reaches the Worker as closed", async () => {
    const id = (await a.evaluate(() => window.e2e.hostPeers())).find((p) => p.kind === "webrtc").id;
    await b.evaluate(() => window.e2e.leave());
    await a.waitForFunction((pid) => window.e2e.hostLog().some((l) => l.t === "closed" && l.peer === pid), id, { timeout: 10000 });
  });

  await step("host stop closes the loopback too", async () => {
    const closed = await a.evaluate(() => window.e2e.stopHost());
    assert.equal(closed, 2);
  });

  await step("sharing off: the joiner is told which file is missing", async () => {
    await a.reload();
    await a.waitForFunction(() => window.e2eReady);
    const h2 = await a.evaluate(() => window.e2e.host(false, [20_000, 10_000]));
    const [, room, h12] = /^#join\/([a-z2-7]{8})\.([0-9a-f]{12})$/.exec(h2.hash);
    const j2 = await b.evaluate(([r, h, m]) => window.e2e.join(r, h, m), [room, h12, h2.mapHash]);
    assert.equal(j2.lobby.ok, false);
    assert.match(j2.lobby.error, /not sharing/);
    assert.match(j2.lobby.error, /e2etest\.gmp and e2etest\.sty/);
    await a.evaluate(() => window.e2e.stopHost());
  });

  await step("UI: host a game, open the join link in another tab", async () => {
    // Synthetic containers (valid headers, random chunk bytes) so the map list offers them.
    const container = (magic, chunk, n) => {
      const body = Buffer.alloc(n);
      for (let i = 0; i < n; i++) body[i] = (i * 2654435761) >>> 24;
      const head = Buffer.alloc(14);
      head.write(magic, 0, "latin1");
      head.writeUInt16LE(500, 4);
      head.write(chunk, 6, "latin1");
      head.writeUInt32LE(n, 10);
      return Buffer.concat([head, body]);
    };
    const ua = await ctx.newPage();
    ua.on("console", (m) => m.type() === "error" && log(`  [UI-A] ${m.text()}`));
    await ua.goto(`${base}/index.html?${fake}`);
    await ua.locator("input[type=file][accept]").setInputFiles([
      { name: "uitest.gmp", mimeType: "application/octet-stream", buffer: container("GBMP", "UMAP", 5000) },
      { name: "uitest.sty", mimeType: "application/octet-stream", buffer: container("GBST", "PALX", 3000) },
    ]);
    await ua.locator("button.host-game").click();
    await ua.locator("select.mapsel").selectOption({ label: "uitest (uitest.gmp)" });
    await ua.locator("input.share").check();
    await ua.locator("button.start").click();
    const link = await ua.locator("input.joinlink").inputValue({ timeout: 10000 });
    assert.match(link, /#join\/[a-z2-7]{8}\.[0-9a-f]{12}$/);
    const ub = await ctx.newPage();
    ub.on("console", (m) => m.type() === "error" && log(`  [UI-B] ${m.text()}`));
    await ub.goto(link);
    // Same context, same OPFS: the joiner already has the files, so the lobby goes straight to the game.
    await ub.locator(".join").waitFor({ timeout: 5000 }).catch(() => {});
    await ua.waitForFunction(() => [...document.querySelectorAll(".peers li")].some((li) => /files ready|in game/.test(li.textContent ?? "")), null, { timeout: 15000 });
    await ub.waitForFunction(() => !document.querySelector(".join") || /Starting/.test(document.querySelector(".join-status")?.textContent ?? ""), null, { timeout: 15000 });
    await ua.locator("button.stop").click();
    await ua.locator("button.start").waitFor({ timeout: 5000 });
  });

  if (existsSync(realHost)) {
    await step("real dist/host-worker.js answers start (ready or error, not silence)", async () => {
      const p = await ctx.newPage();
      await p.goto(`${base}/e2e/index.html?hostWorker=/dist/host-worker.js`);
      await p.waitForFunction(() => window.e2eReady);
      const r = await p.evaluate(() => Promise.race([window.e2e.host(true, [4000, 4000]).then((x) => `ready ${x.ready.mapHash}`, (e) => `error ${e.message}`), new Promise((r) => setTimeout(() => r("timed out"), 20000))]));
      log(`     real worker: ${r}`);
      assert.match(r, /^(ready|error) /);
      assert.doesNotMatch(r, /timed out/);
    });
  } else log("skip real host worker (no dist/host-worker.js)");
} finally {
  await browser.close();
  server.close();
  rmSync(root, { recursive: true, force: true });
}
console.log(failures ? `\n${failures} failed` : "\nall passed");
process.exit(failures ? 1 : 0);
