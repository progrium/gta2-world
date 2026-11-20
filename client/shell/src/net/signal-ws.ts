// Signaller over the gta2-signal Worker (signal/): one WebSocket per page to
// a room. The host creates the room and stays connected for as long as it
// hosts; a peer connects, swaps SDP and ICE with the host, and closes its
// socket once its data channels are open.
//
// The promise from hostRoom/joinRoom resolves on the server's `welcome`, which
// carries the ICE servers (TURN credentials included when the Worker mints
// them), so `signaller.ice` is ready to pass to RTCPeerConnection.

import type { IceConfig, SignalMsg, SignalPeer, Signaller } from "./signal.ts";

/** Server -> client messages. */
type ServerMsg =
  | { type: "welcome"; role: "host" | "peer"; room: string; peer?: string; ice: IceConfig }
  | { type: "peer"; peer: string }
  | { type: "peer-left"; peer: string }
  | { type: "closed"; reason: string }
  | { type: "error"; reason: string }
  | { type: "pong" }
  | { type?: undefined; from: string; msg: SignalMsg };

/** The host pings so the Worker does not expire a quiet room. */
const PING_MS = 5 * 60 * 1000;
const CONNECT_TIMEOUT_MS = 10_000;

const httpBase = (base: string): string => base.replace(/\/+$/, "").replace(/^ws/, "http");
const wsBase = (base: string): string => httpBase(base).replace(/^http/, "ws");

type Event =
  | { k: "peer"; peer: string }
  | { k: "left"; peer: string }
  | { k: "msg"; from: string; msg: SignalMsg }
  | { k: "close"; reason: string };

class WsSignaller implements Signaller {
  readonly ice: IceConfig;
  readonly id: string;
  private ws: WebSocket;
  private ping: ReturnType<typeof setInterval> | null = null;
  private closeReason: string | null = null;
  private done = false;
  // Events that arrive before the page sets the matching handler are kept
  // and delivered when it does, so nothing is lost between resolve and setup.
  private pending: Event[] = [];
  private h: {
    peer: ((peer: SignalPeer) => void) | null;
    left: ((peer: SignalPeer) => void) | null;
    msg: ((from: SignalPeer, msg: SignalMsg) => void) | null;
    close: ((reason: string) => void) | null;
  } = { peer: null, left: null, msg: null, close: null };

  constructor(ws: WebSocket, welcome: Extract<ServerMsg, { type: "welcome" }>) {
    this.ws = ws;
    this.ice = welcome.ice;
    this.id = welcome.peer ?? "host";
    ws.onmessage = (e) => this.onData(e.data);
    ws.onclose = () => this.finish(this.closeReason ?? "signalling connection lost");
    if (welcome.role === "host") this.ping = setInterval(() => this.raw({ type: "ping" }), PING_MS);
  }

  get onPeer() { return this.h.peer; }
  set onPeer(f) { this.h.peer = f; this.flush(); }
  get onPeerLeft() { return this.h.left; }
  set onPeerLeft(f) { this.h.left = f; this.flush(); }
  get onMessage() { return this.h.msg; }
  set onMessage(f) { this.h.msg = f; this.flush(); }
  get onClose() { return this.h.close; }
  set onClose(f) { this.h.close = f; this.flush(); }

  send(to: SignalPeer, msg: SignalMsg): void {
    this.raw({ to, msg });
  }

  /** Leaves the room. A host closing ends the room for every peer. Does not call onClose. */
  close(): void {
    this.done = true;
    this.stop();
    this.ws.close(1000);
  }

  private raw(m: unknown): void {
    if (this.ws.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify(m));
  }

  private stop(): void {
    if (this.ping !== null) clearInterval(this.ping);
    this.ping = null;
  }

  private onData(data: unknown): void {
    let m: ServerMsg;
    try {
      m = JSON.parse(String(data));
    } catch {
      return;
    }
    switch (m.type) {
      case "peer":
        return this.emit({ k: "peer", peer: m.peer });
      case "peer-left":
        return this.emit({ k: "left", peer: m.peer });
      case "closed":
        this.closeReason = m.reason;
        return;
      case "error":
        console.warn(`signal: ${m.reason}`);
        return;
      case undefined:
        if (typeof m.from === "string") this.emit({ k: "msg", from: m.from, msg: m.msg });
        return;
    }
  }

  private finish(reason: string): void {
    this.stop();
    if (this.done) return;
    this.done = true;
    this.emit({ k: "close", reason });
  }

  private emit(e: Event): void {
    this.pending.push(e);
    this.flush();
  }

  private flush(): void {
    const keep: Event[] = [];
    for (const e of this.pending.splice(0)) {
      if (e.k === "peer" && this.h.peer) this.h.peer(e.peer);
      else if (e.k === "left" && this.h.left) this.h.left(e.peer);
      else if (e.k === "msg" && this.h.msg) this.h.msg(e.from, e.msg);
      else if (e.k === "close" && this.h.close) this.h.close(e.reason);
      else keep.push(e);
    }
    this.pending.push(...keep);
  }
}

function connect(url: string): Promise<WsSignaller> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    let reason = "could not reach the signalling service";
    const timer = setTimeout(() => {
      ws.close();
      reject(new Error("signalling service timed out"));
    }, CONNECT_TIMEOUT_MS);
    ws.onmessage = (e) => {
      let m: ServerMsg;
      try {
        m = JSON.parse(String(e.data));
      } catch {
        return;
      }
      if (m.type === "closed") reason = m.reason;
      else if (m.type === "welcome") {
        clearTimeout(timer);
        resolve(new WsSignaller(ws, m));
      }
    };
    ws.onclose = () => {
      clearTimeout(timer);
      reject(new Error(reason));
    };
  });
}

/** Creates a room on the signalling Worker at `base` (http(s) URL) and joins it as host. */
export async function hostRoom(base: string): Promise<{ room: string; signaller: Signaller }> {
  const res = await fetch(`${httpBase(base)}/rooms`, { method: "POST" });
  if (!res.ok) throw new Error(`signalling service: ${res.status}`);
  const { room } = (await res.json()) as { room: string };
  const signaller = await connect(`${wsBase(base)}/r/${room}?role=host`);
  return { room, signaller };
}

/** Joins `room` as a peer. Rejects with the server's reason (e.g. "room full", "no such room"). */
export async function joinRoom(base: string, room: string): Promise<Signaller> {
  if (!/^[a-z2-7]{8}$/.test(room)) throw new Error("bad room id");
  return connect(`${wsBase(base)}/r/${room}`);
}
