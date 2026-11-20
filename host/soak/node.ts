// In-process run of host.wasm in Node on a virtual clock: N synthetic players
// joined at once, every message delivered instantly, T seconds of 30 Hz
// ticks as fast as the CPU allows. Checks the protocol end to end (welcome,
// baseline, snapshots, acked inputs, clean shutdown) and measures pure step
// and encode cost. Bundled and run by run.mjs (`node host/soak/run.mjs node`).

import { readFileSync, writeFileSync } from "node:fs";
import { HostModule, type HostStats, OUT_CLOSE, OUT_DATAGRAM, OUT_STREAM } from "../../client/shell/src/host/wasm.ts";
import { SynthPlayer } from "./players.ts";

export interface NodeRun {
  players: number;
  seconds: number;
  windows: HostStats[];
  ok: boolean;
  problems: string[];
  replayBytes: number;
  wallMs: number;
}

const hexBytes = (h: string): Uint8Array => Uint8Array.from(h.match(/../g)!.map((b) => parseInt(b, 16)));

export async function runNode(o: { wasm: string; map?: string; players: number; seconds: number; replayOut?: string; seed?: number; maxPlayers?: number }): Promise<NodeRun> {
  const stopwatch = (): number => performance.now() * 1e6;
  const host = await HostModule.instantiate(readFileSync(o.wasm), stopwatch, (lvl, line) => {
    if (lvl === "error" || lvl === "warn") console.error(`  host ${lvl}: ${line}`);
  });
  const map = o.map ? new Uint8Array(readFileSync(o.map)) : host.synthMap();
  const tickNs = 1e9 / 30;
  let now = 1e9;
  const info = host.start({ session: "soak", map, maxPlayers: o.maxPlayers ?? 0, seed: o.seed ?? 1234, record: !!o.replayOut, now, entropy: new Uint8Array(32).fill(9) });
  const mapHash = hexBytes(info.mapHash);
  const layoutHash = BigInt("0x" + info.layoutHash);

  const players = new Map<number, SynthPlayer>();
  const closed = new Set<number>();
  const route = (): void => host.drain((peer, kind, msg) => {
    const p = players.get(peer);
    if (!p) return;
    if (kind === OUT_STREAM) p.onStream(new Uint8Array(msg));
    else if (kind === OUT_DATAGRAM) p.onDatagram(new Uint8Array(msg));
    else if (kind === OUT_CLOSE) closed.add(peer);
  });
  for (let i = 1; i <= o.players; i++) {
    const peer = i;
    const p = new SynthPlayer(peer, mapHash, layoutHash, (kind, msg) => {
      if (kind === "stream") host.stream(peer, msg, now);
      else host.datagram(peer, msg, now);
    });
    players.set(peer, p);
    host.opened(peer, 2, now);
    p.hello();
    route();
  }

  const windows: HostStats[] = [];
  const t0 = performance.now();
  const ticks = o.seconds * 30;
  host.stats(now); // reset the window
  for (let k = 1; k <= ticks; k++) {
    now = 1e9 + k * tickNs;
    host.tick(now);
    route();
    for (const p of players.values()) p.tick();
    route();
    if (k % 30 === 0) windows.push(host.stats(now));
  }
  const wallMs = performance.now() - t0;

  const problems: string[] = [];
  const cap = o.maxPlayers || info.maxPlayers;
  let rejected = 0;
  for (const p of players.values()) {
    if (p.rejected && p.peer > cap) rejected++;
    else if (p.rejected) problems.push(`peer ${p.peer} rejected: ${p.rejected}`);
    else if (!p.welcomed || !p.haveBaseline) problems.push(`peer ${p.peer} never got welcome + baseline`);
    else if (p.snapshots < o.seconds * 15) problems.push(`peer ${p.peer} got only ${p.snapshots} snapshots`);
  }
  const over = Math.max(0, o.players - cap);
  if (rejected !== over) problems.push(`${rejected} over-capacity peer(s) rejected, expected ${over}`);
  if (closed.size !== over) problems.push(`${closed.size} peer(s) closed by the host, expected ${over}`);
  const last = windows[windows.length - 1];
  if (last && last.players !== o.players - over) problems.push(`host reports ${last.players} players`);
  for (const pe of last?.peers ?? []) if (pe.lost > 0) problems.push(`peer ${pe.peer}: ${pe.lost} snapshots unacked`);

  const replay = host.stop(now);
  let byes = 0;
  host.drain((_peer, kind, msg) => {
    if (kind === OUT_STREAM && new Uint8Array(msg)[0] === 0x0c) byes++;
  });
  if (byes !== o.players - over) problems.push(`stop sent ${byes} byes for ${o.players - over} players`);
  if (replay && o.replayOut) writeFileSync(o.replayOut, replay);
  return { players: o.players, seconds: o.seconds, windows, ok: problems.length === 0, problems, replayBytes: replay?.length ?? 0, wallMs };
}
