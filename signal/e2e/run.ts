// End-to-end: `wrangler dev` runs the Worker locally, a static server serves
// a page bundled from e2e/page.ts (which uses client/shell/src/net/signal-ws.ts),
// and two Playwright Chromium pages connect a WebRTC data channel through it.
// Needs playwright with Chromium (preinstalled here; elsewhere `npm i playwright`).
//
//   npm run e2e

import { spawn, type ChildProcess } from "node:child_process";
import { createServer } from "node:http";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const here = fileURLToPath(new URL(".", import.meta.url));
const root = fileURLToPath(new URL("..", import.meta.url));
const WORKER_PORT = 8787 + Math.floor(Math.random() * 500);
const workerBase = `http://localhost:${WORKER_PORT}`;

const { chromium } = createRequire(import.meta.url)("playwright");

const bundle = await build({
  entryPoints: [`${here}page.ts`],
  bundle: true,
  format: "esm",
  target: "es2022",
  write: false,
});
const js = bundle.outputFiles[0].text;
const html = `<!doctype html><meta charset="utf-8"><title>signal e2e</title><script type="module">${js}</script>`;
const pageServer = createServer((_req, res) => {
  res.writeHead(200, { "Content-Type": "text/html" });
  res.end(html);
});
await new Promise<void>((r) => pageServer.listen(0, "127.0.0.1", r));
const pagePort = (pageServer.address() as { port: number }).port;
const pageUrl = `http://localhost:${pagePort}/`;

let wrangler: ChildProcess | null = spawn(
  "npx",
  ["wrangler", "dev", "--port", String(WORKER_PORT), "--ip", "127.0.0.1", "--var", "ALLOW_LOCALHOST:true"],
  { cwd: root, env: { ...process.env, WRANGLER_SEND_METRICS: "false", CI: "1" }, stdio: ["ignore", "pipe", "pipe"], detached: true },
);
let wranglerLog = "";
wrangler.stdout!.on("data", (d) => (wranglerLog += d));
wrangler.stderr!.on("data", (d) => (wranglerLog += d));

const stopAll = () => {
  pageServer.close();
  if (wrangler?.pid) {
    try {
      process.kill(-wrangler.pid, "SIGTERM");
    } catch {
      // gone
    }
  }
  wrangler = null;
};

let ok = false;
try {
  // Wait for the Worker.
  const t0 = Date.now();
  for (;;) {
    try {
      if ((await fetch(workerBase)).ok) break;
    } catch {
      // not up yet
    }
    if (Date.now() - t0 > 60_000) throw new Error(`wrangler dev did not start:\n${wranglerLog}`);
    await new Promise((r) => setTimeout(r, 300));
  }

  const browser = await chromium.launch({
    // Two pages in one browser: keep host candidates as plain IPs.
    args: ["--disable-features=WebRtcHideLocalIpsWithMdns"],
  });
  try {
    const hostPage = await browser.newPage();
    const peerPage = await browser.newPage();
    const peer2Page = await browser.newPage();
    for (const [name, p] of [["host", hostPage], ["peer", peerPage], ["peer2", peer2Page]] as const) {
      p.on("console", (m: { text(): string }) => console.log(`[${name}] ${m.text()}`));
      p.on("pageerror", (e: Error) => console.log(`[${name}] page error: ${e.message}`));
      await p.goto(pageUrl);
    }

    const room: string = await hostPage.evaluate((b: string) => (window as any).runHost(b), workerBase);
    const peerLog: string[] = await peerPage.evaluate(
      ([b, r]: string[]) => Promise.race([(window as any).runPeer(b, r), new Promise((_, rej) => setTimeout(() => rej(new Error("peer timed out")), 20_000))]),
      [workerBase, room],
    );
    const hostLog: string[] = await hostPage.evaluate(() =>
      Promise.race([(window as any).hostDone(), new Promise((_, rej) => setTimeout(() => rej(new Error("host timed out")), 20_000))]),
    );
    const dataOk = peerLog.includes('peer: got "hello from host"') && hostLog.includes('host: got "hello from peer"');
    const leftOk = hostLog.some((l) => l.includes("left signalling"));

    // Host leaving closes the room for a connected peer, and later joins are refused.
    await peer2Page.evaluate(([b, r]: string[]) => (window as any).joinAndStay(b, r), [workerBase, room]);
    await hostPage.evaluate(() => (window as any).closeHost());
    const reason: string = await peer2Page.evaluate(() => (window as any).closedReason());
    const late: string = await peer2Page.evaluate(([b, r]: string[]) => (window as any).tryJoin(b, r), [workerBase, room]);

    console.log(`data channel message both ways: ${dataOk}`);
    console.log(`host saw peer leave signalling: ${leftOk}`);
    console.log(`second peer told on host leave: "${reason}"`);
    console.log(`join after host left: "${late}"`);
    ok = dataOk && leftOk && reason === "host left" && late === "no such room";
  } finally {
    await browser.close();
  }
} catch (e) {
  console.error(e);
} finally {
  stopAll();
}
console.log(ok ? "E2E PASS" : "E2E FAIL");
process.exit(ok ? 0 : 1);
