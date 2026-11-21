// One browser-hosted game, from "Start hosting" to "Stop": the room, the
// signaller, the host Worker and the peers. Lives across screens, so the
// host can go into the game and back to the host panel.

import type { AssetStore, MapChoice } from "../assets/store.ts";
import { carInfoRecord, hostFiles } from "../lobby/assets.ts";
import type { LoopbackEnd } from "../net/connection.ts";
import { joinHash } from "../net/signal.ts";
import { openSignaller, newRoom } from "../net/signaller.ts";
import { HostPeers, type HostWorkerLike, type PeerView, type Ready, createHostWorker } from "./hostPeers.ts";

export const HOST_MAX_PLAYERS = 16;

export class HostSession {
  share: boolean;
  readonly map: MapChoice;
  /** SHA-256 of the .gci the cars are built from (null: style only). Every player uses the same one. */
  gciHash: string | null = null;
  /** The room has police on (the dmp16 sim); fixed for the game. */
  readonly police: boolean;
  room: string;
  peers: HostPeers | null = null;
  ready: Ready | null = null;
  error = "";
  private listeners = new Set<() => void>();

  private constructor(map: MapChoice, share: boolean, room: string, police: boolean) {
    this.map = map;
    this.police = police;
    this.share = share;
    this.room = room;
  }

  /** Opens the room and starts the host Worker on `map`. */
  static async start(store: AssetStore, map: MapChoice, share: boolean, worker?: HostWorkerLike, police = false): Promise<HostSession> {
    const s = new HostSession(map, share, newRoom(), police);
    const gciRec = carInfoRecord(store);
    s.gciHash = gciRec?.hash ?? null;
    const opened = await openSignaller("host", s.room);
    s.room = opened.room;
    const sig = opened.signaller;
    let w: HostWorkerLike;
    try {
      w = worker ?? createHostWorker();
    } catch (e) {
      sig.close();
      throw e;
    }
    const peers = new HostPeers({ worker: w, signaller: sig, files: hostFiles(store, map, () => s.share, gciRec) });
    s.peers = peers;
    peers.onChange = () => s.emit();
    peers.onStats = () => s.emit();
    peers.onError = (m) => {
      s.error = m;
      s.emit();
    };
    try {
      const [gmp, style, gci, script] = await Promise.all([
        store.read(map.gmpRecord.hash),
        store.read(map.styRecord.hash),
        gciRec ? store.read(gciRec.hash) : null,
        map.scrRecord ? store.read(map.scrRecord.hash) : null,
      ]);
      s.ready = await withTimeout(
        peers.start({ session: s.room, map: gmp, maxPlayers: HOST_MAX_PLAYERS, seed: (Math.random() * 0x7fffffff) >>> 0, record: false, police, cars: { style, gci }, script }),
        15000,
        "the host worker did not start (is dist/host-worker.js built?)",
      );
    } catch (e) {
      await peers.stop().catch(() => {});
      throw e;
    }
    console.info(`[host] ${s.ready.cars} car models (hash ${s.ready.carsHash}) from ${map.styRecord.name}${gciRec ? ` and ${gciRec.name}` : " (no .gci, default handling)"}`);
    if (s.ready.mapHash && s.ready.mapHash !== map.gmpRecord.hash) console.warn("[host] worker map hash differs", s.ready.mapHash, map.gmpRecord.hash);
    return s;
  }

  /** The link to send to other players. Keeps the page's query (e.g. ?signal=). */
  link(): string {
    return `${location.origin}${location.pathname}${location.search}${joinHash(this.room, this.map.gmpRecord.hash, this.police)}`;
  }

  list(): PeerView[] {
    return this.peers?.peers() ?? [];
  }

  /** The host's own player: an in-page link to the Worker. */
  loopback(): LoopbackEnd {
    return this.peers!.loopback();
  }

  on(f: () => void): () => void {
    this.listeners.add(f);
    return () => this.listeners.delete(f);
  }

  emit(): void {
    for (const f of this.listeners) f();
  }

  async stop(): Promise<void> {
    await this.peers?.stop();
    this.peers = null;
    this.emit();
    this.listeners.clear();
  }
}

function withTimeout<T>(p: Promise<T>, ms: number, msg: string): Promise<T> {
  let t: ReturnType<typeof setTimeout>;
  return Promise.race([p, new Promise<T>((_, rej) => (t = setTimeout(() => rej(new Error(msg)), ms)))]).finally(() => clearTimeout(t));
}
