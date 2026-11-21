// Contract between the page and the browser host Worker (host/ WASM build of
// server/src's session code). The Worker plays the role of the native
// server's Manager behind net.zig's Hub: the page owns the transports (a
// loopback for the host's own player, one RTCPeerConnection per remote
// player) and forwards whole I3 messages; the Worker never sees WebRTC.
//
// Every byte payload is a whole I3 message starting with its type byte,
// exactly as Link.sendDatagram / Link.sendStream carry it in server/src/net.zig.
// Payloads are transferred (postMessage transfer list), never copied twice.

export type PeerId = number;

/** I3 hello.transport values (interfaces/ts/src/wire.ts Transport). */
export type TransportKind = 0 | 1 | 2;

/** Page -> Worker. */
export type ToHost =
  /** Load the sim on this map and start the 30 Hz tick. Sent once. */
  | {
      t: "start";
      session: string;
      map: ArrayBuffer;
      maxPlayers: number;
      seed: number;
      record: boolean;
      /** The .sty and optional .gci for the car models; without a style, the sim's one default model. */
      cars?: { style: ArrayBuffer; gci: ArrayBuffer | null };
    }
  /** A transport connected. Mirrors Hub.opened. `peer` is chosen by the page, unique per host. */
  | { t: "opened"; peer: PeerId; transport: TransportKind }
  /** Mirrors Hub.stream: one reliable I3 message from the peer. */
  | { t: "stream"; peer: PeerId; msg: ArrayBuffer }
  /** Mirrors Hub.datagram: one unreliable I3 message from the peer. */
  | { t: "datagram"; peer: PeerId; msg: ArrayBuffer }
  /** Mirrors Hub.closed. */
  | { t: "closed"; peer: PeerId }
  /** End the session: send bye(3) to everyone, then reply "stopped". */
  | { t: "stop" };

/** Worker -> page. */
export type FromHost =
  /** The sim is loaded and ticking; peers may be opened. */
  | { t: "ready"; mapHash: string; layoutHash: string; maxPlayers: number; cars: number; carsHash: string }
  /** Mirrors Link.sendStream. */
  | { t: "stream"; peer: PeerId; msg: ArrayBuffer }
  /** Mirrors Link.sendDatagram. The page may drop it. */
  | { t: "datagram"; peer: PeerId; msg: ArrayBuffer }
  /** Mirrors Link.close: flush what was queued for this peer, then close it. */
  | { t: "close"; peer: PeerId }
  /** About once a second: tick timing and per-peer traffic, for the host UI and the soak. */
  | { t: "stats"; tick: number; stepUsP50: number; stepUsP99: number; encodeUsP99: number; behindTicks: number;
      peers: { peer: PeerId; slots: number[]; rttMs: number; txBps: number; rxBps: number }[] }
  /** Reply to "stop". `replay` is the .g2wr bytes when start.record was set. */
  | { t: "stopped"; replay?: ArrayBuffer }
  | { t: "error"; message: string };

/** Largest I3 datagram a WebRTC link carries (I3: 1100 bytes of payload). */
export const WEBRTC_MAX_DATAGRAM = 1100;
