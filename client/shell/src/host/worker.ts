// Host Worker: runs one game session of the native server (host.wasm, built
// from server/src by host/) inside the player's tab, so it can host a game
// for others. Implements protocol.ts: the page owns the transports (a
// loopback for the host's own player, WebRTC for the others) and forwards
// whole I3 messages; this Worker never sees a transport, so any value of
// `opened.transport` works the same.
//
// Time: the Worker's performance.now() in ns is passed into every call. The
// 30 Hz timer is setTimeout aimed at the module's next deadline; when the
// Worker wakes late the module catches up (up to five ticks in a burst, then
// skips ahead), exactly like gta2-server's timer, and stats report it as
// behindTicks.

/// <reference lib="webworker" />

import type { FromHost, ToHost } from "./protocol.ts";
import { HostModule, OUT_CLOSE, OUT_DATAGRAM, OUT_STREAM } from "./wasm.ts";

const post = (m: FromHost, transfer: Transferable[] = []): void => (self as unknown as Worker).postMessage(m, transfer);
const clock = (): number => performance.now() * 1e6;
const STATS_NS = 1e9;

let host: HostModule | null = null;
let loading: Promise<HostModule> | null = null;
let running = false;
let timer: ReturnType<typeof setTimeout> | undefined;
let lastStats = 0;
const queued: ToHost[] = [];

function fail(e: unknown): void {
  const message = e instanceof Error ? e.message : String(e);
  post({ t: "error", message });
}

function flush(): void {
  host?.drain((peer, kind, msg) => {
    if (kind === OUT_STREAM) post({ t: "stream", peer, msg }, [msg]);
    else if (kind === OUT_DATAGRAM) post({ t: "datagram", peer, msg }, [msg]);
    else if (kind === OUT_CLOSE) post({ t: "close", peer });
  });
}

function postStats(now: number): void {
  if (!host) return;
  const s = host.stats(now);
  // protocol.ts fields, plus the module's extras (stepUsMax, encodeUsP50, ...).
  post({ t: "stats", ...s });
}

function loop(): void {
  timer = undefined;
  if (!host || !running) return;
  try {
    let now = clock();
    host.tick(now);
    flush();
    now = clock();
    if (now - lastStats >= STATS_NS) {
      postStats(now);
      lastStats = now;
    }
    const delayMs = (host.nextDeadline() - clock()) / 1e6;
    timer = setTimeout(loop, Math.max(0, delayMs));
  } catch (e) {
    running = false;
    fail(e);
  }
}

async function load(): Promise<HostModule> {
  const url = new URL("./host.wasm", import.meta.url);
  // no-cache revalidates, so a new page never runs against a cached old module.
  const res = await fetch(url, { cache: "no-cache" });
  if (!res.ok) throw new Error(`host.wasm: HTTP ${res.status}`);
  return HostModule.instantiate(await res.arrayBuffer(), clock, (level, line) => {
    if (level === "error" || level === "warn") console.warn(`host: ${line}`);
  });
}

function handle(m: ToHost): void {
  if (m.t === "start") return void start(m);
  if (!host) {
    // Messages that race the module load wait for it.
    if (loading) queued.push(m);
    else fail(`host: "${m.t}" before "start"`);
    return;
  }
  const now = clock();
  switch (m.t) {
    case "opened":
      host.opened(m.peer, m.transport, now);
      break;
    case "stream":
      host.stream(m.peer, new Uint8Array(m.msg), now);
      break;
    case "datagram":
      host.datagram(m.peer, new Uint8Array(m.msg), now);
      break;
    case "closed":
      host.closed(m.peer, now);
      break;
    case "stop": {
      running = false;
      if (timer !== undefined) clearTimeout(timer);
      timer = undefined;
      const replay = host.stop(now);
      flush();
      if (replay) post({ t: "stopped", replay: replay.buffer as ArrayBuffer }, [replay.buffer as ArrayBuffer]);
      else post({ t: "stopped" });
      return;
    }
  }
  flush();
}

async function start(m: Extract<ToHost, { t: "start" }>): Promise<void> {
  if (host || loading) return fail("host: already started");
  try {
    loading = load();
    const h = await loading;
    const entropy = crypto.getRandomValues(new Uint8Array(32));
    const now = clock();
    const info = h.start({ session: m.session, map: new Uint8Array(m.map), maxPlayers: m.maxPlayers, seed: m.seed, record: m.record, now, entropy });
    host = h;
    running = true;
    lastStats = now;
    post({ t: "ready", mapHash: info.mapHash, layoutHash: info.layoutHash, maxPlayers: info.maxPlayers });
    for (const q of queued.splice(0)) handle(q);
    loop();
  } catch (e) {
    fail(e);
  } finally {
    loading = null;
  }
}

self.onmessage = (ev: MessageEvent<ToHost>) => {
  try {
    handle(ev.data);
  } catch (e) {
    fail(e);
  }
};
