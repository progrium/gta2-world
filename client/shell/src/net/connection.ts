// I3 connection to a game server (interfaces/I3-wire-protocol.md).
// WebTransport first: datagrams for input and snapshots, one bidirectional
// stream of uvarint-framed messages for the rest. If it is missing or does
// not open within 3 s, the WebSocket fallback: one WS binary message is a
// channel byte (0 datagram, 1 stream) plus one message.
// Browser-hosted games add two links: "webrtc" (data channels `s` and `d` to
// the host's page, net/rtc.ts) and "loopback" (the host's own player, talking
// to the host Worker inside the same page, host/hostPeers.ts). Both send
// hello.transport 2 (WebRTC): the loopback is part of the WebRTC host, and
// I3 has no separate value for it.

import {
  type GameEvent,
  MAX_DATAGRAM,
  Msg,
  type PlayerInfo,
  PROTOCOL_VERSION,
  Reader,
  type Welcome,
  Writer,
  Transport,
  WsChannel,
  decodeEvent,
  decodePlayerInfo,
  decodeReject,
  decodeWelcome,
  encodeHello,
  readStreamFrames,
  streamFrame,
  wsWrap,
} from "../../../../interfaces/ts/src/wire.ts";
import { ABI_VERSION } from "../../../../interfaces/ts/src/abi.ts";
import { RtcPeer } from "./rtc.ts";
import type { Signaller } from "./signal.ts";

/** One end of an in-page link: the host page hands this to its own Connection. */
export interface LoopbackEnd {
  sendStream(msg: Uint8Array): void;
  sendDatagram(msg: Uint8Array): void;
  close(): void;
  onStream: ((msg: Uint8Array) => void) | null;
  onDatagram: ((msg: Uint8Array) => void) | null;
  onClose: ((reason: string) => void) | null;
}

export type TransportName = "auto" | "webtransport" | "websocket" | "webrtc" | "loopback";

export interface ConnectOptions {
  /** Server base URL: http(s)://host:port or ws(s)://host:port (its HTTP/WebSocket port). Unused by webrtc and loopback. */
  server?: string;
  /** "auto" tries WebTransport then WebSocket. "webrtc" needs `rtc` or `signaller`; "loopback" needs `loopback`. */
  transport?: TransportName;
  /** webrtc: a connection to the host page that is already open (the lobby opened it)... */
  rtc?: RtcPeer;
  /** ...or a peer-side signaller to open one with. */
  signaller?: Signaller;
  /** loopback: the host page's in-page end. */
  loopback?: LoopbackEnd;
  session: string;
  layoutHash: bigint;
  /** SHA-256 of the .gmp file, hex. */
  mapHash: string;
  name: string;
  resumeToken?: Uint8Array;
}

export interface ConnectionEvents {
  welcome(w: Welcome): void;
  /** Baseline (on the stream) or snapshot (datagram) body, from its type byte. */
  snapshot(body: Uint8Array, baseline: boolean): void;
  playerInfo(p: PlayerInfo): void;
  event(e: GameEvent): void;
  reject(code: number, message: string): void;
  closed(reason: string): void;
}

const hexBytes = (hex: string): Uint8Array => Uint8Array.from(hex.match(/../g)!.map((b) => parseInt(b, 16)));

export function wsUrl(server: string, session: string): string {
  const base = server.replace(/\/+$/, "").replace(/^http/, "ws");
  return `${base}/s/${encodeURIComponent(session)}/ws`;
}

interface Link {
  kind: "webtransport" | "websocket" | "webrtc" | "loopback";
  sendDatagram(msg: Uint8Array): void;
  sendStream(msg: Uint8Array): void;
  close(): void;
}

interface ServerConfig {
  wtPort: number;
  certHash?: string;
}

const httpBase = (server: string): string => server.replace(/\/+$/, "").replace(/^ws/, "http");

export class Connection {
  private link: Link | null = null;
  private closedOnce = false;
  private ev: ConnectionEvents;
  private o: ConnectOptions;
  welcome: Welcome | null = null;
  transport = "";
  bytesIn = 0;
  bytesOut = 0;

  constructor(o: ConnectOptions, ev: ConnectionEvents) {
    this.o = o;
    this.ev = ev;
    void this.open();
  }

  private hello(kind: number): Uint8Array {
    const w = new Writer(256);
    encodeHello(w, {
      protocol: PROTOCOL_VERSION,
      abi: ABI_VERSION,
      layoutHash: this.o.layoutHash,
      mapHash: hexBytes(this.o.mapHash),
      resumeToken: this.o.resumeToken ?? new Uint8Array(16),
      transport: kind,
      names: [this.o.name.slice(0, 32) || "player"],
    });
    return w.finish();
  }

  private async open(): Promise<void> {
    const want = this.o.transport ?? "auto";
    if (want === "webrtc" || want === "loopback") {
      try {
        this.link = want === "webrtc" ? await this.openWebRTC() : this.openLoopback();
        this.transport = want;
      } catch (e) {
        this.close(`${want === "webrtc" ? "WebRTC" : "loopback"} failed: ${(e as Error).message ?? e}`);
      }
      return;
    }
    if (want !== "websocket" && typeof WebTransport !== "undefined") {
      try {
        this.link = await this.openWebTransport();
        this.transport = "webtransport";
        return;
      } catch (e) {
        if (want === "webtransport") return this.close(`WebTransport failed: ${(e as Error).message ?? e}`);
        console.warn("[net] WebTransport unavailable, using WebSocket:", e);
      }
    }
    if (this.closedOnce) return;
    this.link = this.openWebSocket();
    this.transport = "websocket";
  }

  private async openWebRTC(): Promise<Link> {
    let rtc = this.o.rtc;
    if (!rtc) {
      if (!this.o.signaller) throw new Error("no signaller");
      rtc = await RtcPeer.connect(this.o.signaller);
    }
    const peer = rtc;
    if (this.closedOnce) {
      peer.close("closed");
      throw new Error("closed");
    }
    peer.onStream = (m) => {
      this.bytesIn += m.length;
      this.onStream(m);
    };
    peer.onDatagram = (m) => {
      this.bytesIn += m.length;
      this.onDatagram(m);
    };
    peer.onClose = (reason) => this.close(reason);
    const link: Link = {
      kind: "webrtc",
      // RtcPeer drops datagrams over min(1100, SCTP max) or when `d` is backed up.
      sendDatagram: (m) => {
        if (peer.sendDatagram(m)) this.bytesOut += m.length;
      },
      sendStream: (m) => {
        this.bytesOut += m.length;
        peer.sendStream(m);
      },
      close: () => peer.close("closed"),
    };
    link.sendStream(this.hello(Transport.webrtc));
    return link;
  }

  private openLoopback(): Link {
    const lb = this.o.loopback;
    if (!lb) throw new Error("no loopback link");
    lb.onStream = (m) => {
      this.bytesIn += m.length;
      this.onStream(m);
    };
    lb.onDatagram = (m) => {
      this.bytesIn += m.length;
      this.onDatagram(m);
    };
    lb.onClose = (reason) => this.close(reason);
    const link: Link = {
      kind: "loopback",
      sendDatagram: (m) => {
        if (m.length > MAX_DATAGRAM) return;
        this.bytesOut += m.length;
        lb.sendDatagram(m);
      },
      sendStream: (m) => {
        this.bytesOut += m.length;
        lb.sendStream(m);
      },
      close: () => lb.close(),
    };
    link.sendStream(this.hello(Transport.webrtc));
    return link;
  }

  private async openWebTransport(): Promise<Link> {
    const base = httpBase(this.o.server ?? "");
    const cfg = (await (await fetch(`${base}/config`)).json()) as ServerConfig;
    const host = new URL(base).hostname;
    const url = `https://${host}:${cfg.wtPort}/s/${encodeURIComponent(this.o.session)}`;
    const opts: WebTransportOptions = cfg.certHash
      ? { serverCertificateHashes: [{ algorithm: "sha-256", value: Uint8Array.from(atob(cfg.certHash), (c) => c.charCodeAt(0)) }] }
      : {};
    const wt = new WebTransport(url, opts);
    let timer = 0;
    await Promise.race([
      wt.ready,
      new Promise((_, rej) => {
        timer = setTimeout(() => rej(new Error("timeout")), 3000) as unknown as number;
      }),
    ]).finally(() => clearTimeout(timer));
    const stream = await wt.createBidirectionalStream();
    const sw = stream.writable.getWriter();
    const dw = wt.datagrams.writable.getWriter();
    const link: Link = {
      kind: "webtransport",
      sendDatagram: (m) => {
        this.bytesOut += m.length;
        dw.write(m).catch(() => {});
      },
      sendStream: (m) => {
        const f = streamFrame(m);
        this.bytesOut += f.length;
        sw.write(f).catch(() => {});
      },
      close: () => {
        try {
          wt.close();
        } catch {
          /* closed */
        }
      },
    };
    void (async () => {
      const r = wt.datagrams.readable.getReader();
      for (;;) {
        const { value, done } = await r.read();
        if (done) break;
        this.bytesIn += value.length;
        this.onDatagram(value);
      }
    })().catch(() => {});
    void (async () => {
      const r = stream.readable.getReader();
      let pending: Uint8Array = new Uint8Array(0);
      for (;;) {
        const { value, done } = await r.read();
        if (done) break;
        this.bytesIn += value.length;
        const joined = new Uint8Array(pending.length + value.length);
        joined.set(pending);
        joined.set(value, pending.length);
        const { bodies, used } = readStreamFrames(joined);
        pending = joined.slice(used);
        for (const b of bodies) this.onStream(b);
      }
      this.close("server closed the stream");
    })().catch((e) => this.close(`stream error: ${(e as Error).message ?? e}`));
    wt.closed.then(() => this.close("connection closed")).catch((e) => this.close(`connection lost: ${(e as Error).message ?? e}`));
    link.sendStream(this.hello(Transport.webtransport));
    return link;
  }

  private openWebSocket(): Link {
    const ws = new WebSocket(wsUrl(this.o.server ?? "", this.o.session));
    ws.binaryType = "arraybuffer";
    const send = (channel: number, msg: Uint8Array): void => {
      if (ws.readyState !== WebSocket.OPEN) return;
      const b = wsWrap(channel, msg);
      this.bytesOut += b.length;
      ws.send(b);
    };
    ws.onopen = () => send(WsChannel.stream, this.hello(Transport.websocket));
    ws.onmessage = (m) => {
      const b = new Uint8Array(m.data as ArrayBuffer);
      this.bytesIn += b.length;
      if (b.length < 2) return;
      if (b[0] === WsChannel.datagram) this.onDatagram(b.subarray(1));
      else this.onStream(b.subarray(1));
    };
    ws.onerror = () => this.close("connection error");
    ws.onclose = (e) => this.close(e.reason || `connection closed (${e.code})`);
    return {
      kind: "websocket",
      sendDatagram: (m) => send(WsChannel.datagram, m),
      sendStream: (m) => send(WsChannel.stream, m),
      close: () => {
        try {
          ws.close(1000);
        } catch {
          /* closed */
        }
      },
    };
  }

  /** An input datagram from the game module. */
  sendInput(msg: Uint8Array): void {
    this.link?.sendDatagram(msg);
  }

  private onDatagram(body: Uint8Array): void {
    if (body.length > 0 && body[0] === Msg.snapshot) this.ev.snapshot(body, false);
  }

  private onStream(body: Uint8Array): void {
    if (body.length === 0) return;
    const type = body[0]!;
    try {
      const r = new Reader(body);
      switch (type) {
        case Msg.welcome:
          this.welcome = decodeWelcome(r);
          this.ev.welcome(this.welcome);
          break;
        case Msg.baseline:
          this.ev.snapshot(body, true);
          break;
        case Msg.reject: {
          const j = decodeReject(r);
          this.ev.reject(j.code, j.message);
          this.close(j.message);
          break;
        }
        case Msg.playerInfo:
          this.ev.playerInfo(decodePlayerInfo(r));
          break;
        case Msg.event:
          this.ev.event(decodeEvent(r));
          break;
        case Msg.bye:
          this.close("server said bye");
          break;
        default:
          break;
      }
    } catch (e) {
      console.warn("[net] bad message", type, e);
    }
  }

  close(reason = "closed"): void {
    if (this.closedOnce) return;
    this.closedOnce = true;
    this.link?.close();
    this.ev.closed(reason);
  }
}
