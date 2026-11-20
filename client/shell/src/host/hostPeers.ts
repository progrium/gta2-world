// The host page's side of a browser-hosted game. Owns the host Worker
// (protocol.ts), accepts joining players from a Signaller with one
// RTCPeerConnection each, and moves whole I3 messages between their data
// channels and the Worker:
//
//   channel `s` message  -> ToHost stream     FromHost stream   -> `s`
//   channel `d` message  -> ToHost datagram   FromHost datagram -> `d` (dropped if over the cap or backed up)
//   `s` closed / ICE failed / Worker close    -> ToHost closed
//
// Peers get numeric ids from 1. ToHost "opened" is sent just before a peer's
// first stream message (its hello), not when the channels open: a joiner may
// spend a while in the lobby on channel `f` downloading files first, and the
// session should not count it until it says hello.
//
// The host's own player uses loopback(): an in-page link to the Worker with
// no network, which Connection drives with transport "loopback".

import { type FileInfo, Limiter, MAX_TRANSFERS } from "../lobby/files.ts";
import { type HostFiles, LobbyHost, wrapDataChannel } from "../lobby/lobby.ts";
import type { LoopbackEnd } from "../net/connection.ts";
import { DATAGRAM_QUEUE_LIMIT, IceQueue, MAX_DATAGRAM, closeAfterFlush, datagramLimit } from "../net/rtc.ts";
import type { SignalMsg, SignalPeer, Signaller } from "../net/signal.ts";
import type { FromHost, PeerId, ToHost } from "./protocol.ts";

export interface HostWorkerLike {
  postMessage(m: ToHost, transfer: Transferable[]): void;
  onmessage: ((ev: MessageEvent<FromHost>) => void) | null;
  onerror: ((ev: ErrorEvent) => void) | null;
  terminate(): void;
}

/** The dist build's host Worker, or ?hostWorker=<same-origin path> (tests use a fake). */
export function createHostWorker(search: string = location.search): HostWorkerLike {
  const override = new URLSearchParams(search).get("hostWorker");
  const url = override ? new URL(override, location.href) : new URL("./host-worker.js", import.meta.url);
  if (url.origin !== location.origin) throw new Error("host worker must be same-origin");
  return new Worker(url, { type: "module", name: "host" }) as unknown as HostWorkerLike;
}

export type PeerState = "connecting" | "lobby" | "in game" | "closed";

export interface PeerView {
  id: PeerId;
  kind: "loopback" | "webrtc";
  state: PeerState;
  /** First name from the peer's hello, once it arrived. */
  name: string;
  /** hello.transport, once the hello arrived. */
  transport: number | null;
  lobby: LobbyHost | null;
  datagramsIn: number;
  datagramsOut: number;
  datagramsDropped: number;
}

interface Peer {
  view: PeerView;
  opened: boolean;
  closed: boolean;
  signal: SignalPeer | null;
  pc: RTCPeerConnection | null;
  s: RTCDataChannel | null;
  d: RTCDataChannel | null;
  maxDatagram: number;
  loop: LoopbackEnd | null;
  disconnectTimer: ReturnType<typeof setTimeout> | null;
}

export type StartOpts = Omit<Extract<ToHost, { t: "start" }>, "t">;
export type Ready = Extract<FromHost, { t: "ready" }>;
export type Stats = Extract<FromHost, { t: "stats" }>;

const copyBuffer = (m: Uint8Array): ArrayBuffer => m.slice().buffer as ArrayBuffer;

/** Name and transport from a hello, read without the full codec (magic and layout are the Worker's job). */
export function peekHello(b: Uint8Array): { name: string; transport: number } | null {
  // u8 type, u32 magic, u16 protocol, u16 abi, u64 layout, [32] map, [16] token, u8 transport, u8 n, str...
  const T = 1 + 4 + 2 + 2 + 8 + 32 + 16;
  if (b.length < T + 3 || b[0] !== 0x01) return null;
  const transport = b[T]!;
  const len = b[T + 2]!;
  if (len > 32 || len >= 0x80 || T + 3 + len > b.length) return { name: "", transport };
  let name = "";
  try {
    name = new TextDecoder("utf-8", { fatal: true }).decode(b.subarray(T + 3, T + 3 + len));
  } catch {
    /* not UTF-8 */
  }
  return { name, transport };
}

export interface HostPeersOptions {
  worker: HostWorkerLike;
  signaller: Signaller;
  /** The match's files and the share switch, for the lobby on channel `f`. */
  files: HostFiles;
  limiter?: Limiter;
  /** Ms a "disconnected" ICE state may last before the peer counts as gone. */
  disconnectGraceMs?: number;
}

export class HostPeers {
  onChange: (() => void) | null = null;
  onStats: ((s: Stats) => void) | null = null;
  onError: ((message: string) => void) | null = null;
  ready: Ready | null = null;
  lastStats: Stats | null = null;
  private peersById = new Map<PeerId, Peer>();
  private bySignal = new Map<SignalPeer, Peer>();
  private ice = new Map<SignalPeer, IceQueue>();
  private nextId = 1;
  private readyWait: { resolve: (r: Ready) => void; reject: (e: Error) => void } | null = null;
  private stopWait: ((replay?: ArrayBuffer) => void) | null = null;
  private stopped = false;
  private limiter: Limiter;
  private worker: HostWorkerLike;
  private sig: Signaller;
  private files: HostFiles;
  private grace: number;

  constructor(o: HostPeersOptions) {
    this.worker = o.worker;
    this.sig = o.signaller;
    this.files = o.files;
    this.limiter = o.limiter ?? new Limiter(MAX_TRANSFERS);
    this.grace = o.disconnectGraceMs ?? 5000;
    this.worker.onmessage = (ev) => this.fromWorker(ev.data);
    this.worker.onerror = (ev) => {
      const msg = `host worker failed: ${ev.message || "could not load host-worker.js"}`;
      this.readyWait?.reject(new Error(msg));
      this.readyWait = null;
      this.onError?.(msg);
    };
    this.sig.onMessage = (from, m) => this.onSignal(from, m);
    this.sig.onPeerLeft = (from) => {
      const p = this.bySignal.get(from);
      // Signalling may end once the channels run; only drop peers still connecting.
      if (p && p.view.state === "connecting") this.drop(p);
    };
    this.sig.onClose = (reason) => this.onError?.(`signalling closed: ${reason}`);
  }

  /** Starts the Worker's session; resolves on "ready". */
  start(o: StartOpts): Promise<Ready> {
    return new Promise<Ready>((resolve, reject) => {
      this.readyWait = { resolve, reject };
      this.worker.postMessage({ t: "start", ...o }, [o.map]);
    });
  }

  peers(): PeerView[] {
    return [...this.peersById.values()].map((p) => p.view);
  }

  private post(m: ToHost, transfer: Transferable[] = []): void {
    if (!this.stopped) this.worker.postMessage(m, transfer);
  }

  private newPeer(kind: PeerView["kind"], signal: SignalPeer | null): Peer {
    const p: Peer = {
      view: { id: this.nextId++, kind, state: "connecting", name: "", transport: null, lobby: null, datagramsIn: 0, datagramsOut: 0, datagramsDropped: 0 },
      opened: false,
      closed: false,
      signal,
      pc: null,
      s: null,
      d: null,
      maxDatagram: MAX_DATAGRAM,
      loop: null,
      disconnectTimer: null,
    };
    this.peersById.set(p.view.id, p);
    if (signal) this.bySignal.set(signal, p);
    this.onChange?.();
    return p;
  }

  // ------------------------------------------------------------ page -> Worker

  private streamIn(p: Peer, m: Uint8Array): void {
    if (p.closed) return;
    if (!p.opened) {
      p.opened = true;
      this.post({ t: "opened", peer: p.view.id, transport: 2 });
      const h = peekHello(m);
      if (h) {
        p.view.name = h.name;
        p.view.transport = h.transport;
      }
      p.view.state = "in game";
      this.onChange?.();
    }
    const buf = copyBuffer(m);
    this.post({ t: "stream", peer: p.view.id, msg: buf }, [buf]);
  }

  private datagramIn(p: Peer, m: Uint8Array): void {
    if (p.closed || !p.opened || m.length > MAX_DATAGRAM) return;
    p.view.datagramsIn++;
    const buf = copyBuffer(m);
    this.post({ t: "datagram", peer: p.view.id, msg: buf }, [buf]);
  }

  /** The peer is gone (channel closed, ICE failed, loopback closed, Worker closed it). */
  private drop(p: Peer, reason = "closed"): void {
    if (p.closed) return;
    p.closed = true;
    p.view.state = "closed";
    if (p.disconnectTimer) clearTimeout(p.disconnectTimer);
    if (p.opened) this.post({ t: "closed", peer: p.view.id });
    this.peersById.delete(p.view.id);
    if (p.signal) {
      this.bySignal.delete(p.signal);
      this.ice.delete(p.signal);
    }
    const pc = p.pc;
    if (pc && p.s) void closeAfterFlush(p.s).then(() => pc.close());
    else pc?.close();
    p.loop?.onClose?.(reason);
    this.onChange?.();
  }

  // ------------------------------------------------------------ Worker -> page

  private fromWorker(m: FromHost): void {
    switch (m.t) {
      case "ready":
        this.ready = m;
        this.readyWait?.resolve(m);
        this.readyWait = null;
        return;
      case "stream": {
        const p = this.peersById.get(m.peer);
        if (!p || p.closed) return;
        if (p.loop) p.loop.onStream?.(new Uint8Array(m.msg));
        else if (p.s?.readyState === "open") {
          try {
            p.s.send(m.msg);
          } catch (e) {
            console.warn("[host] stream send", e);
            this.drop(p, "send failed");
          }
        }
        return;
      }
      case "datagram": {
        const p = this.peersById.get(m.peer);
        if (!p || p.closed) return;
        if (p.loop) {
          p.view.datagramsOut++;
          p.loop.onDatagram?.(new Uint8Array(m.msg));
        } else if (p.d?.readyState === "open" && m.msg.byteLength <= p.maxDatagram && p.d.bufferedAmount <= DATAGRAM_QUEUE_LIMIT) {
          p.view.datagramsOut++;
          p.d.send(m.msg);
        } else p.view.datagramsDropped++;
        return;
      }
      case "close": {
        const p = this.peersById.get(m.peer);
        if (p) this.drop(p, "the host closed the connection");
        return;
      }
      case "stats":
        this.lastStats = m;
        this.onStats?.(m);
        return;
      case "stopped":
        this.stopWait?.(m.replay);
        this.stopWait = null;
        return;
      case "error":
        this.readyWait?.reject(new Error(m.message));
        this.readyWait = null;
        this.onError?.(m.message);
        return;
    }
  }

  // ------------------------------------------------------------------ loopback

  /** An in-page link for the host's own player. Pass it to Connection as { transport: "loopback", loopback }. */
  loopback(): LoopbackEnd {
    const p = this.newPeer("loopback", null);
    const end: LoopbackEnd = {
      onStream: null,
      onDatagram: null,
      onClose: null,
      sendStream: (m) => this.streamIn(p, m),
      sendDatagram: (m) => this.datagramIn(p, m),
      close: () => {
        p.loop = null; // the Connection closed it; don't call back into it
        this.drop(p);
      },
    };
    p.loop = end;
    return end;
  }

  // ------------------------------------------------------------------- WebRTC

  private onSignal(from: SignalPeer, m: SignalMsg): void {
    if (this.stopped) return;
    if (m.kind === "offer") {
      const old = this.bySignal.get(from);
      if (old) this.drop(old);
      void this.answer(from, m.sdp).catch((e) => {
        console.warn("[host] answer", e);
        const p = this.bySignal.get(from);
        if (p) this.drop(p);
      });
    } else if (m.kind === "ice") {
      let q = this.ice.get(from);
      if (!q) {
        const p = this.bySignal.get(from);
        if (!p?.pc) return;
        q = new IceQueue(p.pc);
        this.ice.set(from, q);
      }
      q.add(m.candidate);
    }
  }

  private async answer(from: SignalPeer, sdp: string): Promise<void> {
    const pc = new RTCPeerConnection(this.sig.ice);
    const p = this.newPeer("webrtc", from);
    p.pc = pc;
    const q = new IceQueue(pc);
    this.ice.set(from, q);
    pc.onicecandidate = (e) => this.sig.send(from, { kind: "ice", candidate: e.candidate ? e.candidate.toJSON() : null });
    pc.ondatachannel = (e) => {
      const ch = e.channel;
      ch.binaryType = "arraybuffer";
      if (ch.label === "s") {
        p.s = ch;
        ch.onmessage = (ev) => this.streamIn(p, new Uint8Array(ev.data as ArrayBuffer));
        ch.onclose = () => this.drop(p, "the player left");
      } else if (ch.label === "d") {
        p.d = ch;
        ch.onmessage = (ev) => this.datagramIn(p, new Uint8Array(ev.data as ArrayBuffer));
      } else if (ch.label === "f") {
        const start = (): void => {
          p.maxDatagram = datagramLimit(pc);
          const lobby = new LobbyHost(wrapDataChannel(ch), this.files, this.limiter);
          lobby.onChange = () => this.onChange?.();
          p.view.lobby = lobby;
          if (p.view.state === "connecting") p.view.state = "lobby";
          this.onChange?.();
        };
        if (ch.readyState === "open") start();
        else ch.addEventListener("open", start, { once: true });
      } else ch.close();
    };
    pc.onconnectionstatechange = () => {
      const st = pc.connectionState;
      if (st === "failed" || st === "closed") this.drop(p, "connection lost");
      else if (st === "disconnected") {
        p.disconnectTimer ??= setTimeout(() => {
          if (pc.connectionState === "disconnected") this.drop(p, "connection lost");
        }, this.grace);
      } else if (st === "connected" && p.disconnectTimer) {
        clearTimeout(p.disconnectTimer);
        p.disconnectTimer = null;
      }
    };
    await pc.setRemoteDescription({ type: "offer", sdp });
    q.flush();
    await pc.setLocalDescription(await pc.createAnswer());
    this.sig.send(from, { kind: "answer", sdp: pc.localDescription!.sdp });
  }

  /** Ends the session: the Worker says bye to everyone, then all links close. Resolves with the replay, if recorded. */
  async stop(): Promise<ArrayBuffer | undefined> {
    if (this.stopped) return undefined;
    const replay = await new Promise<ArrayBuffer | undefined>((resolve) => {
      const t = setTimeout(() => resolve(undefined), 2000);
      this.stopWait = (r) => {
        clearTimeout(t);
        resolve(r);
      };
      this.worker.postMessage({ t: "stop" }, []);
    });
    for (const p of [...this.peersById.values()]) this.drop(p, "the host ended the game");
    this.stopped = true;
    this.sig.close();
    this.worker.terminate();
    this.onChange?.();
    return replay;
  }
}

/** The files a joiner needs for a match: the map's .gmp and .sty. */
export function matchFiles(recs: { name: string; kind: FileInfo["kind"]; size: number; hash: string }[]): FileInfo[] {
  return recs.map((r) => ({ name: r.name, kind: r.kind, size: r.size, sha256: r.hash }));
}
