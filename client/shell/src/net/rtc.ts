// WebRTC data channels for browser-hosted games (I3, WebRTC column).
//
// One RTCPeerConnection per joining player, three channels, all created by
// the joiner before its offer so one negotiation covers them:
//   s  ordered, reliable           I3 stream: one channel message = one I3 message
//   d  ordered:false, maxRetransmits:0   I3 datagrams, at most 1100 bytes
//   f  ordered, reliable           lobby / file transfer (outside I3)
// The joiner makes the offer; the host answers (host/hostPeers.ts).

import { PipeEnd } from "./pipe.ts";
import type { SignalMsg, Signaller } from "./signal.ts";

/** With same-browser signalling, how long WebRTC gets before the joiner switches to the BroadcastChannel pipe. */
export const PIPE_FALLBACK_MS = 3000;

export const MAX_DATAGRAM = 1100;
/** Above this many queued bytes on `d`, datagrams are dropped rather than queued. */
export const DATAGRAM_QUEUE_LIMIT = 64 * 1024;

export const CHANNELS = {
  s: { ordered: true } as RTCDataChannelInit,
  d: { ordered: false, maxRetransmits: 0 } as RTCDataChannelInit,
  f: { ordered: true } as RTCDataChannelInit,
};

/** Largest datagram this connection carries: 1100, or less if SCTP says so. */
export function datagramLimit(pc: RTCPeerConnection): number {
  const m = pc.sctp?.maxMessageSize;
  return m && m > 0 ? Math.min(MAX_DATAGRAM, m) : MAX_DATAGRAM;
}

/** Applies remote ICE candidates, holding them until the remote description is set. */
export class IceQueue {
  private pending: (RTCIceCandidateInit | null)[] = [];
  private ready = false;
  private pc: RTCPeerConnection;
  constructor(pc: RTCPeerConnection) {
    this.pc = pc;
  }
  add(c: RTCIceCandidateInit | null): void {
    if (!this.ready) this.pending.push(c);
    else this.apply(c);
  }
  flush(): void {
    this.ready = true;
    for (const c of this.pending.splice(0)) this.apply(c);
  }
  private apply(c: RTCIceCandidateInit | null): void {
    if (c === null) return; // end of candidates
    this.pc.addIceCandidate(c).catch((e) => console.warn("[rtc] candidate", e));
  }
}

const waitOpen = (ch: RTCDataChannel): Promise<void> =>
  ch.readyState === "open"
    ? Promise.resolve()
    : new Promise((resolve, reject) => {
        ch.addEventListener("open", () => resolve(), { once: true });
        ch.addEventListener("close", () => reject(new Error(`channel ${ch.label} closed`)), { once: true });
      });

/** Closes a channel once what is queued on it has gone out (or after `ms`). */
export function closeAfterFlush(ch: RTCDataChannel, ms = 2000): Promise<void> {
  return new Promise((resolve) => {
    const done = (): void => {
      clearTimeout(t);
      try {
        ch.close();
      } catch {
        /* closed */
      }
      resolve();
    };
    const t = setTimeout(done, ms);
    if (ch.readyState !== "open" || ch.bufferedAmount === 0) return done();
    ch.bufferedAmountLowThreshold = 0;
    ch.addEventListener("bufferedamountlow", done, { once: true });
  });
}

/** The joiner's end: a connected peer connection to the host page. */
export class RtcPeer {
  onStream: ((msg: Uint8Array) => void) | null = null;
  onDatagram: ((msg: Uint8Array) => void) | null = null;
  onClose: ((reason: string) => void) | null = null;
  maxDatagram = MAX_DATAGRAM;
  datagramsDropped = 0;
  private closed = false;
  readonly pc: RTCPeerConnection;
  readonly s: RTCDataChannel;
  readonly d: RTCDataChannel;
  /** The lobby's file channel. */
  readonly f: RTCDataChannel;

  private constructor(pc: RTCPeerConnection, s: RTCDataChannel, d: RTCDataChannel, f: RTCDataChannel) {
    this.pc = pc;
    this.s = s;
    this.d = d;
    this.f = f;
    this.maxDatagram = datagramLimit(pc);
    s.onmessage = (e) => this.onStream?.(new Uint8Array(e.data as ArrayBuffer));
    d.onmessage = (e) => {
      const b = new Uint8Array(e.data as ArrayBuffer);
      if (b.length <= MAX_DATAGRAM) this.onDatagram?.(b);
    };
    s.onclose = () => this.close("the host closed the connection");
    pc.onconnectionstatechange = () => {
      if (pc.connectionState === "failed" || pc.connectionState === "closed") this.close("connection to the host lost");
    };
  }

  /**
   * Opens a connection to the host through `sig` (peer side): creates the
   * three channels, offers, trickles ICE, and resolves once all are open.
   * Signalling is closed afterwards; it is not needed once the channels run.
   */
  static connect(sig: Signaller, timeoutMs = 20000, pipeAfterMs = PIPE_FALLBACK_MS): Promise<RtcPeer> {
    const pc = new RTCPeerConnection(sig.ice);
    const mk = (label: keyof typeof CHANNELS): RTCDataChannel => {
      const ch = pc.createDataChannel(label, CHANNELS[label]);
      ch.binaryType = "arraybuffer";
      return ch;
    };
    const s = mk("s");
    const d = mk("d");
    const f = mk("f");
    const ice = new IceQueue(pc);
    return new Promise<RtcPeer>((resolve, reject) => {
      let settled = false;
      let piped = false;
      const fail = (why: string): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        clearTimeout(fallback);
        pc.close();
        sig.close();
        reject(new Error(why));
      };
      const timer = setTimeout(() => fail("could not reach the host (timed out)"), timeoutMs);
      const finish = (peer: RtcPeer): void => {
        if (settled) return peer.close("cancelled");
        settled = true;
        clearTimeout(timer);
        clearTimeout(fallback);
        sig.onMessage = null;
        sig.onClose = null;
        sig.close();
        resolve(peer);
      };
      // Same-browser tabs: if WebRTC hasn't connected yet, carry the channels over BroadcastChannel.
      const usePipe = (): void => {
        if (settled || piped) return;
        piped = true;
        console.warn("[rtc] WebRTC did not connect; using the same-browser pipe");
        pc.close();
        const id = Array.from(crypto.getRandomValues(new Uint8Array(8)), (b) => b.toString(16).padStart(2, "0")).join("");
        const pipe = new PipeEnd(id);
        sig.send("host", { kind: "pipe", id });
        const chans = [pipe.s, pipe.d, pipe.f] as unknown as RTCDataChannel[];
        Promise.all(chans.map(waitOpen)).then(
          () => finish(new RtcPeer(pipe.pc, chans[0], chans[1], chans[2])),
          (e) => fail((e as Error).message),
        );
      };
      const fallback = sig.local ? setTimeout(usePipe, pipeAfterMs) : undefined;
      pc.onicecandidate = (e) => sig.send("host", { kind: "ice", candidate: e.candidate ? e.candidate.toJSON() : null });
      sig.onMessage = (_from, m: SignalMsg) => {
        if (m.kind === "answer") {
          pc.setRemoteDescription({ type: "answer", sdp: m.sdp })
            .then(() => ice.flush())
            .catch((e) => fail(`bad answer: ${(e as Error).message}`));
        } else if (m.kind === "ice") ice.add(m.candidate);
        else if (m.kind === "bye") fail(`the host refused: ${m.reason}`);
      };
      sig.onClose = (reason) => fail(reason);
      pc.createOffer()
        .then((o) => pc.setLocalDescription(o))
        .then(() => sig.send("host", { kind: "offer", sdp: pc.localDescription!.sdp }))
        .catch((e) => fail(`offer failed: ${(e as Error).message}`));
      Promise.all([waitOpen(s), waitOpen(d), waitOpen(f)]).then(
        () => {
          if (!piped) finish(new RtcPeer(pc, s, d, f));
        },
        (e) => {
          if (!piped) fail((e as Error).message);
        },
      );
    });
  }

  sendStream(msg: Uint8Array): void {
    if (this.s.readyState !== "open") return;
    this.s.send(msg as Uint8Array<ArrayBuffer>);
  }

  /** Drops the datagram if it is over the cap or the channel is backed up. */
  sendDatagram(msg: Uint8Array): boolean {
    if (this.d.readyState !== "open" || msg.length > this.maxDatagram || this.d.bufferedAmount > DATAGRAM_QUEUE_LIMIT) {
      this.datagramsDropped++;
      return false;
    }
    this.d.send(msg as Uint8Array<ArrayBuffer>);
    return true;
  }

  close(reason = "closed"): void {
    if (this.closed) return;
    this.closed = true;
    void closeAfterFlush(this.s, 500).then(() => this.pc.close());
    this.onClose?.(reason);
  }
}
