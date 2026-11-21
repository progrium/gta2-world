// Soak page: starts the real host Worker (client/shell/src/host/worker.ts,
// the same file the game ships) and connects N synthetic players to it
// through protocol.ts messages, as the page's transports would. Players run
// on this page's main thread at 30 Hz; the host runs on its own clock in the
// Worker. Results land in window.__soak for run.mjs.

import type { FromHost, ToHost } from "../../client/shell/src/host/protocol.ts";
import type { HostStats } from "../../client/shell/src/host/wasm.ts";
import { SynthPlayer } from "./players.ts";

interface Result {
  players: number;
  seconds: number;
  crossOriginIsolated: boolean;
  windows: HostStats[];
  problems: string[];
  replayBytes: number;
  inputLateMs: number[];
}

declare global {
  interface Window { __soak?: Result; __soakError?: string }
}

const q = new URLSearchParams(location.search);
const N = Number(q.get("players") ?? 4);
const SECONDS = Number(q.get("seconds") ?? 20);
const RECORD = q.get("record") === "1";
const hexBytes = (h: string): Uint8Array => Uint8Array.from(h.match(/../g)!.map((b) => parseInt(b, 16)));

async function main(): Promise<void> {
  const map = await (await fetch("./map.gmp")).arrayBuffer();
  const worker = new Worker(new URL("./host-worker.js", import.meta.url), { type: "module", name: "host" });
  const send = (m: ToHost, transfer: Transferable[] = []): void => worker.postMessage(m, transfer);
  const players = new Map<number, SynthPlayer>();
  const windows: HostStats[] = [];
  const problems: string[] = [];
  let stopping = false;
  let ready: ((v: Extract<FromHost, { t: "ready" }>) => void) | null = null;
  let stopped: ((v: Extract<FromHost, { t: "stopped" }>) => void) | null = null;

  worker.onmessage = (ev: MessageEvent<FromHost>) => {
    const m = ev.data;
    switch (m.t) {
      case "ready": ready?.(m); break;
      case "stream": players.get(m.peer)?.onStream(new Uint8Array(m.msg)); break;
      case "datagram": players.get(m.peer)?.onDatagram(new Uint8Array(m.msg)); break;
      case "close": if (!stopping) problems.push(`host closed peer ${m.peer}`); break;
      case "stats": windows.push(m as unknown as HostStats); break;
      case "stopped": stopped?.(m); break;
      case "error": problems.push(`host error: ${m.message}`); break;
    }
  };
  worker.onerror = (e) => problems.push(`worker error: ${e.message}`);

  const info = await new Promise<Extract<FromHost, { t: "ready" }>>((res) => {
    ready = res;
    send({ t: "start", session: "soak", map, maxPlayers: 16, seed: 1234, record: RECORD }, [map]);
  });
  const mapHash = hexBytes(info.mapHash);
  const layoutHash = BigInt("0x" + info.layoutHash);

  for (let peer = 1; peer <= N; peer++) {
    const p = new SynthPlayer(peer, mapHash, layoutHash, (kind, msg) => {
      const buf = msg.buffer.slice(msg.byteOffset, msg.byteOffset + msg.byteLength) as ArrayBuffer;
      send({ t: kind, peer, msg: buf }, [buf]);
    });
    players.set(peer, p);
    send({ t: "opened", peer, transport: 2 });
    p.hello();
  }

  // 30 Hz input clock on the main thread, catching up like a client would.
  const tickMs = 1000 / 30;
  const t0 = performance.now();
  let n = 0;
  const inputLateMs: number[] = [];
  await new Promise<void>((done) => {
    const step = (): void => {
      const now = performance.now();
      if (now - t0 >= SECONDS * 1000) return done();
      while ((n + 1) * tickMs <= now - t0) {
        n++;
        inputLateMs.push(now - t0 - n * tickMs);
        for (const p of players.values()) p.tick();
      }
      setTimeout(step, Math.max(0, (n + 1) * tickMs - (performance.now() - t0)));
    };
    step();
  });

  stopping = true;
  const st = await new Promise<Extract<FromHost, { t: "stopped" }>>((res) => {
    stopped = res;
    send({ t: "stop" });
  });
  for (const p of players.values()) {
    if (p.rejected) problems.push(`peer ${p.peer} rejected: ${p.rejected}`);
    else if (!p.haveBaseline) problems.push(`peer ${p.peer} never got a baseline`);
    else if (p.snapshots < SECONDS * 15) problems.push(`peer ${p.peer} got only ${p.snapshots} snapshots in ${SECONDS} s`);
  }
  worker.terminate();
  window.__soak = { players: N, seconds: SECONDS, crossOriginIsolated, windows, problems, replayBytes: st.replay?.byteLength ?? 0, inputLateMs };
}

main().catch((e) => {
  window.__soakError = String(e?.stack ?? e);
});
