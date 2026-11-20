// One browser-hosted game, from "Start hosting" to "Stop": the room, the
// signaller, the host Worker and the peers. Lives across screens, so the
// host can go into the game and back to the host panel.

import type { AssetStore, MapChoice } from "../assets/store.ts";
import { hostFiles } from "../lobby/assets.ts";
import type { LoopbackEnd } from "../net/connection.ts";
import { joinHash } from "../net/signal.ts";
import { createSignaller, newRoom } from "../net/signaller.ts";
import { HostPeers, type HostWorkerLike, type PeerView, type Ready, createHostWorker } from "./hostPeers.ts";

export const HOST_MAX_PLAYERS = 16;

export class HostSession {
  share: boolean;
  readonly map: MapChoice;
  readonly room: string;
  peers: HostPeers | null = null;
  ready: Ready | null = null;
  error = "";
  private listeners = new Set<() => void>();

  private constructor(map: MapChoice, share: boolean, room: string) {
    this.map = map;
    this.share = share;
    this.room = room;
  }

  /** Opens the room and starts the host Worker on `map`. */
  static async start(store: AssetStore, map: MapChoice, share: boolean, worker?: HostWorkerLike): Promise<HostSession> {
    const s = new HostSession(map, share, newRoom());
    const sig = await createSignaller("host", s.room);
    let w: HostWorkerLike;
    try {
      w = worker ?? createHostWorker();
    } catch (e) {
      sig.close();
      throw e;
    }
    const peers = new HostPeers({ worker: w, signaller: sig, files: hostFiles(store, map, () => s.share) });
    s.peers = peers;
    peers.onChange = () => s.emit();
    peers.onStats = () => s.emit();
    peers.onError = (m) => {
      s.error = m;
      s.emit();
    };
    try {
      const gmp = await store.read(map.gmpRecord.hash);
      s.ready = await withTimeout(
        peers.start({ session: s.room, map: gmp, maxPlayers: HOST_MAX_PLAYERS, seed: (Math.random() * 0x7fffffff) >>> 0, record: false }),
        15000,
        "the host worker did not start (is dist/host-worker.js built?)",
      );
    } catch (e) {
      await peers.stop().catch(() => {});
      throw e;
    }
    if (s.ready.mapHash && s.ready.mapHash !== map.gmpRecord.hash) console.warn("[host] worker map hash differs", s.ready.mapHash, map.gmpRecord.hash);
    return s;
  }

  /** The link to send to other players. Keeps the page's query (e.g. ?signal=). */
  link(): string {
    return `${location.origin}${location.pathname}${location.search}${joinHash(this.room, this.map.gmpRecord.hash)}`;
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
