// Synthetic I3 players for the host soak: one client with one local player
// per peer. Sends hello on the stream, then at 30 Hz an input datagram with
// random steering (redundant frames back to the last acked tick, like
// server/src/bot.zig), acks every snapshot, and steers its clock from the
// server's slack_q. Encoded with interfaces/ts/src/wire.ts.

import {
  Msg, PROTOCOL_VERSION, Reader, Transport, Writer, MAX_REDUNDANCY,
  decodeReject, decodeSnapshotHeader, decodeWelcome, encodeHello, encodeInput,
} from "../../interfaces/ts/src/wire.ts";
import { ABI_VERSION } from "../../interfaces/ts/src/abi.ts";
import { Button, type Frame, neutralFrame, seqOf } from "../../interfaces/ts/src/input.ts";

export type Send = (kind: "stream" | "datagram", msg: Uint8Array) => void;

/** xorshift32, so runs are repeatable per player. */
function rng(seed: number): () => number {
  let s = seed >>> 0 || 1;
  return () => {
    s ^= s << 13; s >>>= 0;
    s ^= s >>> 17;
    s ^= s << 5; s >>>= 0;
    return s / 4294967296;
  };
}

export class SynthPlayer {
  slot = -1;
  welcomed = false;
  haveBaseline = false;
  rejected: string | null = null;
  snapshots = 0;
  inputsSent = 0;
  rttMs = 0;
  private bufferTicks = 2;
  private clientTick = 0;
  private nextGen = 0;
  private firstGen = 0;
  private inputAck = 0;
  private slack = 0;
  private ackSeq = 0;
  private ackBits = 0;
  private frames: Frame[] = new Array(64);
  private steer = 0;
  private rand: () => number;
  private t0 = performance.now();

  constructor(readonly peer: number, private mapHash: Uint8Array, private layoutHash: bigint, private send: Send) {
    this.rand = rng(peer * 7919 + 1);
  }

  private nowMs16(): number {
    return Math.floor(performance.now() - this.t0) & 0xffff;
  }

  hello(): void {
    const w = new Writer(512);
    encodeHello(w, {
      protocol: PROTOCOL_VERSION, abi: ABI_VERSION, layoutHash: this.layoutHash, mapHash: this.mapHash,
      resumeToken: new Uint8Array(16), transport: Transport.webrtc, names: [`synth${this.peer}`],
    });
    this.send("stream", w.finish());
  }

  onStream(msg: Uint8Array): void {
    switch (msg[0]) {
      case Msg.welcome: {
        const m = decodeWelcome(new Reader(msg));
        this.slot = m.slots[0];
        this.bufferTicks = m.inputBufferTicks;
        this.clientTick = m.serverTick + this.bufferTicks + 1;
        this.nextGen = this.firstGen = this.clientTick;
        this.welcomed = true;
        break;
      }
      case Msg.baseline:
        this.onSnapshot(msg);
        break;
      case Msg.reject:
        this.rejected = decodeReject(new Reader(msg)).message;
        break;
    }
  }

  onDatagram(msg: Uint8Array): void {
    if (msg[0] === Msg.snapshot) this.onSnapshot(msg);
  }

  private onSnapshot(msg: Uint8Array): void {
    const { header: h, baseline } = decodeSnapshotHeader(new Reader(msg));
    this.snapshots++;
    if (baseline) this.haveBaseline = true;
    if (this.ackBits === 0) {
      this.ackSeq = h.seq;
      this.ackBits = 1;
    } else {
      const d = (h.seq - this.ackSeq) & 0xffff;
      if (d > 0 && d < 0x8000) {
        this.ackBits = d >= 32 ? 1 : ((this.ackBits << d) | 1) >>> 0;
        this.ackSeq = h.seq;
      } else if (d !== 0) {
        const back = (this.ackSeq - h.seq) & 0xffff;
        if (back < 32) this.ackBits = (this.ackBits | (1 << back)) >>> 0;
      }
    }
    if (h.echoTime !== 0) this.rttMs = (this.nowMs16() - h.echoTime - h.holdMs) & 0xffff;
    for (const p of h.players) if (p.slot === this.slot) {
      this.inputAck = p.inputAck;
      this.slack = p.slackQ;
    }
    // Clock steering: keep slack near the server's buffer.
    const want = this.bufferTicks * 4;
    if (!baseline) {
      if (this.slack < want - 2) this.clientTick++;
      else if (this.slack > want + 6) this.clientTick--;
      if (this.clientTick - h.tick < 1) this.clientTick = h.tick + this.bufferTicks;
    }
  }

  /** One 30 Hz input tick: returns false until welcomed with a baseline. */
  tick(): boolean {
    if (this.rejected || !this.welcomed || !this.haveBaseline) return false;
    const t = this.clientTick++;
    while (t - this.nextGen >= 0) {
      const f = neutralFrame(seqOf(this.nextGen));
      // Random steering: a drifting wheel, mostly throttle, the odd button.
      this.steer = Math.max(-127, Math.min(127, this.steer + Math.round((this.rand() - 0.5) * 60)));
      f.steer = this.steer;
      f.throttle = this.rand() < 0.9 ? 110 : -60;
      if (this.rand() < 1 / 30) f.buttons |= Button.fire;
      if (this.rand() < 1 / 300) f.buttons |= Button.enterExit;
      if (this.rand() < 1 / 400) f.buttons |= Button.handbrakeJump;
      this.frames[this.nextGen % 64] = f;
      this.nextGen++;
    }
    const since = t - this.inputAck;
    const generated = t - this.firstGen + 1;
    const count = Math.max(1, Math.min(since, generated, MAX_REDUNDANCY));
    const frames: Frame[] = [];
    for (let j = t - count + 1; j <= t; j++) frames.push(this.frames[j % 64]);
    const w = new Writer(400);
    encodeInput(w, { ackSeq: this.ackSeq, ackBits: this.ackBits, sendTime: this.nowMs16(), players: [{ slot: this.slot, newestTick: t >>> 0, frames }] });
    this.send("datagram", w.finish());
    this.inputsSent++;
    return true;
  }
}
