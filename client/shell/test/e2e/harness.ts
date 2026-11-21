// Browser test harness (bundled by rtc.e2e.mjs): drives the real modules
// (BroadcastChannel signalling, HostPeers, RtcPeer, Connection, the lobby
// and the asset store) without the game screen. Files are random bytes.

import { AssetStore } from "../../src/assets/store.ts";
import { HostPeers, type HostWorkerLike, createHostWorker } from "../../src/host/hostPeers.ts";
import type { ToHost } from "../../src/host/protocol.ts";
import { joinStore } from "../../src/lobby/assets.ts";
import { type FileInfo, sha256Hex } from "../../src/lobby/files.ts";
import { type HostFiles, LobbyJoin, wrapDataChannel } from "../../src/lobby/lobby.ts";
import { Connection, type ConnectOptions, type ConnectionEvents } from "../../src/net/connection.ts";
import { RtcPeer } from "../../src/net/rtc.ts";
import { joinHash } from "../../src/net/signal.ts";
import { createSignaller, newRoom } from "../../src/net/signaller.ts";

const store = new AssetStore(new URL("../dist/worker.js", location.href));

const random = (n: number): Uint8Array => {
  const b = new Uint8Array(n);
  for (let o = 0; o < n; o += 65536) crypto.getRandomValues(b.subarray(o, Math.min(n, o + 65536)));
  return b;
};

/** Wraps the Worker so the test can see every ToHost message. */
function logged(w: HostWorkerLike, log: { t: string; peer?: number; transport?: number; size?: number }[]): HostWorkerLike {
  return {
    postMessage: (m: ToHost, tr: Transferable[]) => {
      log.push({ t: m.t, peer: "peer" in m ? m.peer : undefined, transport: m.t === "opened" ? m.transport : undefined, size: "msg" in m ? m.msg.byteLength : undefined });
      w.postMessage(m, tr);
    },
    get onmessage() {
      return w.onmessage;
    },
    set onmessage(f) {
      w.onmessage = f;
    },
    get onerror() {
      return w.onerror;
    },
    set onerror(f) {
      w.onerror = f;
    },
    terminate: () => w.terminate(),
  };
}

function connect(o: ConnectOptions): Promise<{ conn: Connection; welcome: Promise<unknown>; snapshots: Uint8Array[]; closed: Promise<string> }> {
  const snapshots: Uint8Array[] = [];
  let onWelcome!: (w: unknown) => void;
  let onClosed!: (r: string) => void;
  const welcome = new Promise((r) => (onWelcome = r));
  const closed = new Promise<string>((r) => (onClosed = r));
  const ev: ConnectionEvents = {
    welcome: (w) => onWelcome(w),
    snapshot: (b) => snapshots.push(b.slice()),
    playerInfo: () => {},
    event: () => {},
    reject: () => {},
    closed: (r) => onClosed(r),
  };
  return Promise.resolve({ conn: new Connection(o, ev), welcome, snapshots, closed });
}

const until = async (f: () => boolean, ms = 5000): Promise<void> => {
  const t0 = performance.now();
  while (!f()) {
    if (performance.now() - t0 > ms) throw new Error("timed out");
    await new Promise((r) => setTimeout(r, 20));
  }
};

async function datagramRoundTrip(conn: Connection, snapshots: Uint8Array[], size: number): Promise<boolean> {
  const before = snapshots.length;
  const msg = random(size);
  msg[0] = 0x10;
  conn.sendInput(msg);
  try {
    await until(() => snapshots.length > before, 3000);
  } catch {
    return false;
  }
  const got = snapshots[snapshots.length - 1]!;
  return got[0] === 0x20 && got.length === msg.length && got.subarray(1).every((x, i) => x === msg[i + 1]);
}

const w = window as unknown as Record<string, unknown>;

let host: { peers: HostPeers; log: { t: string; peer?: number; transport?: number; size?: number }[]; files: { info: FileInfo; data: Uint8Array }[]; share: boolean } | null = null;

w.e2e = {
  /** Page A: host with in-memory random files, plus a loopback client. */
  async host(share: boolean, sizes: [number, number] = [300_000, 70_001]) {
    const room = newRoom();
    const files = await Promise.all(
      (["e2etest.gmp", "e2etest.sty"] as const).map(async (name, i) => {
        const data = random(sizes[i]!);
        const kind = name.endsWith("gmp") ? "gmp" : "sty";
        return { info: { name, kind, size: data.length, sha256: await sha256Hex(data) } as FileInfo, data };
      }),
    );
    const hf: HostFiles = { mapHash: files[0]!.info.sha256, description: "E2E map", files: files.map((f) => f.info), share: () => host!.share, read: async (sha) => files.find((f) => f.info.sha256 === sha)!.data };
    const log: { t: string; peer?: number; transport?: number; size?: number }[] = [];
    const worker = logged(createHostWorker(), log);
    const sig = await createSignaller("host", room);
    const peers = new HostPeers({ worker, signaller: sig, files: hf, disconnectGraceMs: 1000 });
    host = { peers, log, files, share };
    const ready = await peers.start({ session: room, map: files[0]!.data.slice().buffer, maxPlayers: 16, seed: 1, record: false });
    // The host's own player over the loopback.
    const lb = await connect({ transport: "loopback", loopback: peers.loopback(), session: room, layoutHash: 1n, mapHash: files[0]!.info.sha256, name: "host" });
    await lb.welcome;
    const loopRtt = await datagramRoundTrip(lb.conn, lb.snapshots, 200);
    w.__loop = lb;
    return { room, hash: joinHash(room, files[0]!.info.sha256), mapHash: files[0]!.info.sha256, ready, loopTransport: lb.conn.transport, loopRtt, files: files.map((f) => f.info) };
  },
  hostLog: () => host!.log,
  hostPeers: () => host!.peers.peers().map((p) => ({ id: p.id, kind: p.kind, state: p.state, name: p.name, transport: p.transport, lobby: p.lobby?.state ?? null, dIn: p.datagramsIn, dOut: p.datagramsOut })),
  setShare: (s: boolean) => (host!.share = s),
  async stopHost() {
    await host!.peers.stop();
    return host!.log.filter((l) => l.t === "closed").length;
  },

  /** Page B: join `room`, fetch files through the lobby, play over WebRTC. */
  async join(room: string, mapHash12: string, mapHash: string) {
    await store.load();
    const t0 = performance.now();
    const sig = await createSignaller("peer", room);
    console.log("[e2e] signalling");
    const rtc = await RtcPeer.connect(sig);
    console.log("[e2e] channels open");
    const channels = { s: rtc.s.readyState, d: rtc.d.readyState, f: rtc.f.readyState, dOrdered: rtc.d.ordered, dRetransmits: rtc.d.maxRetransmits, maxDatagram: rtc.maxDatagram };
    const lobby = new LobbyJoin(wrapDataChannel(rtc.f), joinStore(store));
    let progressEvents = 0;
    lobby.onProgress = () => progressEvents++;
    let lobbyResult: unknown;
    try {
      const r = await lobby.run(mapHash12);
      lobbyResult = { ok: true, downloaded: r.downloaded };
    } catch (e) {
      rtc.close("lobby failed");
      return { channels, lobby: { ok: false, error: (e as Error).message } };
    }
    // Check the store kept them: a fresh load, then read (which re-checks the SHA-256).
    console.log("[e2e] lobby done");
    const fresh = new AssetStore(new URL("../dist/worker.js", location.href));
    await fresh.load();
    const stored = await Promise.all(
      fresh.manifest.files.filter((f) => f.path.startsWith("shared/")).map(async (f) => ({ path: f.path, hash: f.hash, size: f.size, readBack: await sha256Hex(await fresh.read(f.hash)) })),
    );
    const c = await connect({ transport: "webrtc", rtc, session: room, layoutHash: 1n, mapHash, name: "joiner" });
    console.log("[e2e] store checked");
    const welcome = await c.welcome;
    console.log("[e2e] welcome");
    const rtt = await datagramRoundTrip(c.conn, c.snapshots, 290);
    const dropBefore = rtc.datagramsDropped;
    c.conn.sendInput(random(1200)); // over the 1100-byte cap: dropped
    const capped = rtc.datagramsDropped === dropBefore + 1;
    w.__join = { c, rtc };
    return { channels, lobby: lobbyResult, progressEvents, stored, welcome, transport: c.conn.transport, rtt, capped, ms: Math.round(performance.now() - t0) };
  },
  leave() {
    (w.__join as { c: { conn: Connection } }).c.conn.close("leaving");
  },
  async clearStore() {
    await store.clear();
  },
};
w.e2eReady = true;
