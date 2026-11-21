// BroadcastChannel signalling (signal.ts contract) for tabs of one browser on
// one machine: dev and tests. The room name is the channel name. No server is
// involved, so the ICE config is empty (host candidates only) unless the
// caller passes STUN servers.
//
// On the channel every message is an envelope:
//   { from, to, type: "join" | "present" | "leave" | "close" | "msg", msg? }
// `from`/`to` are "host", "*" (everyone) or a peer id. A peer announces itself
// with "join" and repeats it until the host answers "present"; until then its
// outgoing messages wait in a queue, so an offer is never lost to a host tab
// that is still loading.

import type { IceConfig, SignalMsg, SignalPeer, Signaller } from "./signal.ts";

interface Envelope {
  from: string;
  to: string;
  type: "join" | "present" | "leave" | "close" | "msg";
  msg?: SignalMsg;
  reason?: string;
}

const HOST = "host";
const JOIN_RETRY_MS = 500;

/** A channel the signaller can use; BroadcastChannel by default (tests pass a fake). */
export interface BcLike {
  postMessage(m: unknown): void;
  onmessage: ((ev: MessageEvent) => void) | null;
  close(): void;
}

export interface BcOptions {
  ice?: IceConfig;
  /** For tests: a factory for the channel. */
  channel?: (name: string) => BcLike;
}

const channelName = (room: string): string => `gta2-signal/${room}`;
const randomId = (): string => Array.from(crypto.getRandomValues(new Uint8Array(6)), (b) => b.toString(16).padStart(2, "0")).join("");

export class BcSignaller implements Signaller {
  onPeer: ((peer: SignalPeer) => void) | null = null;
  onPeerLeft: ((peer: SignalPeer) => void) | null = null;
  onMessage: ((from: SignalPeer, msg: SignalMsg) => void) | null = null;
  onClose: ((reason: string) => void) | null = null;
  readonly ice: IceConfig;
  readonly local = true;
  readonly id: string;
  private bc: BcLike;
  private isHost: boolean;
  private peers = new Set<string>();
  private hostSeen = false;
  private queue: Envelope[] = [];
  private timer: ReturnType<typeof setInterval> | null = null;
  private closed = false;

  private constructor(room: string, isHost: boolean, o: BcOptions) {
    this.isHost = isHost;
    this.id = isHost ? HOST : randomId();
    this.ice = o.ice ?? { iceServers: [] };
    this.bc = (o.channel ?? ((n) => new BroadcastChannel(n) as unknown as BcLike))(channelName(room));
    this.bc.onmessage = (ev) => this.receive(ev.data as Envelope);
  }

  /** The host side of a room. Tells waiting peers it is here. */
  static host(room: string, o: BcOptions = {}): BcSignaller {
    const s = new BcSignaller(room, true, o);
    s.post({ from: HOST, to: "*", type: "present" });
    return s;
  }

  /** A joining peer. */
  static peer(room: string, o: BcOptions = {}): BcSignaller {
    const s = new BcSignaller(room, false, o);
    const join = (): void => s.post({ from: s.id, to: HOST, type: "join" });
    join();
    s.timer = setInterval(() => (s.hostSeen ? s.stopTimer() : join()), JOIN_RETRY_MS);
    return s;
  }

  private stopTimer(): void {
    if (this.timer !== null) clearInterval(this.timer);
    this.timer = null;
  }

  private post(e: Envelope): void {
    if (this.closed) return;
    try {
      this.bc.postMessage(e);
    } catch {
      /* channel closed */
    }
  }

  private receive(e: Envelope): void {
    if (this.closed || !e || typeof e !== "object" || typeof e.from !== "string") return;
    if (e.to !== this.id && e.to !== "*") return;
    if (this.isHost) {
      if (e.from === HOST) return; // another host tab in the same room: ignore it
      switch (e.type) {
        case "join":
          this.post({ from: HOST, to: e.from, type: "present" });
          if (!this.peers.has(e.from)) {
            this.peers.add(e.from);
            this.onPeer?.(e.from);
          }
          break;
        case "leave":
          if (this.peers.delete(e.from)) this.onPeerLeft?.(e.from);
          break;
        case "msg":
          if (!this.peers.has(e.from)) {
            this.peers.add(e.from);
            this.onPeer?.(e.from);
          }
          if (e.msg) this.onMessage?.(e.from, e.msg);
          break;
      }
      return;
    }
    if (e.from !== HOST) return;
    switch (e.type) {
      case "present":
        if (!this.hostSeen) {
          this.hostSeen = true;
          this.stopTimer();
          for (const q of this.queue.splice(0)) this.post(q);
        }
        // A host that reloaded announces itself to "*": join again.
        if (e.to === "*") this.post({ from: this.id, to: HOST, type: "join" });
        break;
      case "msg":
        if (e.msg) this.onMessage?.(HOST, e.msg);
        break;
      case "close":
        this.shutdown(e.reason ?? "the host closed the room");
        break;
    }
  }

  send(to: SignalPeer, msg: SignalMsg): void {
    const e: Envelope = { from: this.id, to: this.isHost ? to : HOST, type: "msg", msg };
    if (!this.isHost && !this.hostSeen) this.queue.push(e);
    else this.post(e);
  }

  private shutdown(reason: string): void {
    if (this.closed) return;
    this.closed = true;
    this.stopTimer();
    try {
      this.bc.close();
    } catch {
      /* closed */
    }
    this.onClose?.(reason);
  }

  close(): void {
    if (this.closed) return;
    if (this.isHost) this.post({ from: HOST, to: "*", type: "close", reason: "the host closed the room" });
    else this.post({ from: this.id, to: HOST, type: "leave" });
    this.closed = true;
    this.stopTimer();
    try {
      this.bc.close();
    } catch {
      /* closed */
    }
  }
}
