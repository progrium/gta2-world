// I3. Wire protocol: message ids, framing and codecs.
// Frozen interface. Spec: interfaces/I3-wire-protocol.md. Twin of zig/src/wire.zig.
// Snapshot record payloads for sim-owned components are decoded in
// client/wasm (Zig); this file decodes headers and the frozen components.

import type { FieldSchema } from "./abi.js";
import { type Frame, FRAME_SIZE, decodeFrame, encodeFrame, seqOf } from "./input.js";

export const PROTOCOL_VERSION = 1;
export const MAGIC = 0x31573247; // "G2W1" little-endian
export const MAX_DATAGRAM = 1100;
export const MAX_STREAM_MESSAGE = 1 << 20;
export const MAX_REDUNDANCY = 8;
export const MAX_LOCAL_PLAYERS = 4;
export const MAX_BASE_AGE = 63;
export const MAX_NAME_LEN = 32;
export const MAX_CHAT_LEN = 200;
export const HANDLE_PLAYER_ROW_BASE = 15 << 12;

export const Msg = {
  hello: 0x01, welcome: 0x02, reject: 0x03, baseline: 0x04, addLocal: 0x05, localAdded: 0x06,
  removeLocal: 0x07, chat: 0x08, chatFrom: 0x09, event: 0x0a, playerInfo: 0x0b, bye: 0x0c,
  input: 0x10, snapshot: 0x20,
} as const;
export const isDatagram = (type: number): boolean => type >= 0x10;

export const WsChannel = { datagram: 0, stream: 1 } as const;
export const Transport = { webtransport: 0, websocket: 1, webrtc: 2 } as const;
export const RejectCode = {
  protocolMismatch: 1, layoutMismatch: 2, mapMismatch: 3, sessionFull: 4,
  sessionNotFound: 5, badMessage: 6, shuttingDown: 7, resumeExpired: 8,
} as const;
export const ByeReason = { leaving: 0, timeout: 1, kicked: 2, shuttingDown: 3 } as const;
export const EventKind = {
  kill: 1, playerJoined: 2, playerLeft: 3, explosion: 4, roundEnd: 5, pickup: 6,
  // Single player, reserved 2026-11-20 (W0 of docs/plan-notes.md).
  message: 7, brief: 8, wanted: 9, wasted: 10, busted: 11, missionStart: 12, missionPass: 13,
  missionFail: 14, phoneRing: 15, siren: 16, gameOver: 17, levelComplete: 18, policeVoice: 19, respray: 20,
} as const;
export const RecordOp = { update: 0, create: 1, remove: 2 } as const;

export class WireError extends Error {}

const enc = new TextEncoder();
const dec = new TextDecoder("utf-8", { fatal: true });

export class Writer {
  private buf: Uint8Array;
  private dv: DataView;
  pos = 0;
  constructor(capacity = MAX_DATAGRAM) {
    this.buf = new Uint8Array(capacity);
    this.dv = new DataView(this.buf.buffer);
  }
  private need(n: number): void {
    if (this.pos + n > this.buf.length) throw new WireError("overflow");
  }
  u8(v: number): void { this.need(1); this.dv.setUint8(this.pos, v); this.pos += 1; }
  i8(v: number): void { this.need(1); this.dv.setInt8(this.pos, v); this.pos += 1; }
  u16(v: number): void { this.need(2); this.dv.setUint16(this.pos, v, true); this.pos += 2; }
  u32(v: number): void { this.need(4); this.dv.setUint32(this.pos, v >>> 0, true); this.pos += 4; }
  u64(v: bigint): void { this.need(8); this.dv.setBigUint64(this.pos, v, true); this.pos += 8; }
  bytes(b: Uint8Array): void { this.need(b.length); this.buf.set(b, this.pos); this.pos += b.length; }
  uvarint(v: number): void {
    if (!Number.isSafeInteger(v) || v < 0) throw new WireError("uvarint range");
    while (v >= 0x80) { this.u8((v % 0x80) | 0x80); v = Math.floor(v / 0x80); }
    this.u8(v);
  }
  svarint(v: number): void { this.uvarint(zigzag(v)); }
  str(s: string, max: number): void {
    const b = enc.encode(s);
    if (b.length > max) throw new WireError("string too long");
    this.uvarint(b.length);
    this.bytes(b);
  }
  frame(f: Frame): void { this.need(FRAME_SIZE); encodeFrame(f, this.dv, this.pos); this.pos += FRAME_SIZE; }
  finish(): Uint8Array { return this.buf.slice(0, this.pos); }
}

export class Reader {
  private dv: DataView;
  pos = 0;
  readonly buf: Uint8Array;
  constructor(buf: Uint8Array) {
    this.buf = buf;
    this.dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  }
  done(): boolean { return this.pos === this.buf.length; }
  private need(n: number): void {
    if (this.pos + n > this.buf.length) throw new WireError("truncated");
  }
  u8(): number { this.need(1); return this.dv.getUint8(this.pos++); }
  i8(): number { this.need(1); return this.dv.getInt8(this.pos++); }
  u16(): number { this.need(2); const v = this.dv.getUint16(this.pos, true); this.pos += 2; return v; }
  u32(): number { this.need(4); const v = this.dv.getUint32(this.pos, true); this.pos += 4; return v; }
  u64(): bigint { this.need(8); const v = this.dv.getBigUint64(this.pos, true); this.pos += 8; return v; }
  bytes(n: number): Uint8Array { this.need(n); const b = this.buf.subarray(this.pos, this.pos + n); this.pos += n; return b; }
  uvarint(): number {
    let v = 0, mul = 1;
    for (let i = 0; i < 8; i++) {
      const b = this.u8();
      v += (b & 0x7f) * mul;
      if (!(b & 0x80)) {
        if (!Number.isSafeInteger(v)) throw new WireError("uvarint range");
        return v;
      }
      mul *= 0x80;
    }
    throw new WireError("uvarint too long");
  }
  svarint(): number { return unzigzag(this.uvarint()); }
  str(max: number): string {
    const n = this.uvarint();
    if (n > max) throw new WireError("string too long");
    return dec.decode(this.bytes(n));
  }
  frame(): Frame { this.need(FRAME_SIZE); const f = decodeFrame(this.dv, this.pos); this.pos += FRAME_SIZE; return f; }
}

export const zigzag = (v: number): number => (v >= 0 ? v * 2 : -v * 2 - 1);
export const unzigzag = (u: number): number => (u % 2 === 0 ? u / 2 : -(u + 1) / 2);

// --- Stream framing (WebTransport reliable stream) -----------------------

export function streamFrame(body: Uint8Array): Uint8Array {
  if (body.length > MAX_STREAM_MESSAGE) throw new WireError("message too long");
  const w = new Writer(body.length + 5);
  w.uvarint(body.length);
  w.bytes(body);
  return w.finish();
}

/** Splits complete frames off the front of `buf`; returns bodies and bytes used. */
export function readStreamFrames(buf: Uint8Array): { bodies: Uint8Array[]; used: number } {
  const bodies: Uint8Array[] = [];
  let used = 0;
  while (used < buf.length) {
    const r = new Reader(buf.subarray(used));
    let n: number;
    try { n = r.uvarint(); } catch (e) { if (e instanceof WireError && e.message === "truncated") break; throw e; }
    if (n > MAX_STREAM_MESSAGE) throw new WireError("message too long");
    if (r.pos + n > r.buf.length) break;
    bodies.push(r.bytes(n));
    used += r.pos;
  }
  return { bodies, used };
}

/** WebSocket fallback: one channel byte, then exactly one message. */
export function wsWrap(channel: number, msg: Uint8Array): Uint8Array {
  const out = new Uint8Array(msg.length + 1);
  out[0] = channel;
  out.set(msg, 1);
  return out;
}

// --- Handshake -----------------------------------------------------------

export interface Hello {
  protocol: number; abi: number; layoutHash: bigint; mapHash: Uint8Array;
  resumeToken: Uint8Array; transport: number; names: string[];
}

export function encodeHello(w: Writer, m: Hello): void {
  if (m.names.length < 1 || m.names.length > MAX_LOCAL_PLAYERS) throw new WireError("names");
  if (m.mapHash.length !== 32 || m.resumeToken.length !== 16) throw new WireError("hash/token size");
  w.u8(Msg.hello); w.u32(MAGIC); w.u16(m.protocol); w.u16(m.abi); w.u64(m.layoutHash);
  w.bytes(m.mapHash); w.bytes(m.resumeToken); w.u8(m.transport); w.u8(m.names.length);
  for (const n of m.names) w.str(n, MAX_NAME_LEN);
}

export function decodeHello(r: Reader): Hello {
  if (r.u8() !== Msg.hello || r.u32() !== MAGIC) throw new WireError("not hello");
  const protocol = r.u16(), abi = r.u16(), layoutHash = r.u64();
  const mapHash = r.bytes(32).slice(), resumeToken = r.bytes(16).slice(), transport = r.u8();
  const n = r.u8();
  if (n < 1 || n > MAX_LOCAL_PLAYERS) throw new WireError("names");
  const names: string[] = [];
  for (let i = 0; i < n; i++) names.push(r.str(MAX_NAME_LEN));
  return { protocol, abi, layoutHash, mapHash, resumeToken, transport, names };
}

export interface Welcome {
  protocol: number; clientId: number; resumeToken: Uint8Array; serverTick: number;
  tickHz: number; snapshotHz: number; inputBufferTicks: number; redundancy: number;
  maxPlayers: number; configName: string; slots: number[];
}

export function encodeWelcome(w: Writer, m: Welcome): void {
  w.u8(Msg.welcome); w.u16(m.protocol); w.u32(m.clientId); w.bytes(m.resumeToken); w.u32(m.serverTick);
  w.u8(m.tickHz); w.u8(m.snapshotHz); w.u8(m.inputBufferTicks); w.u8(m.redundancy); w.u16(m.maxPlayers);
  w.str(m.configName, MAX_NAME_LEN); w.u8(m.slots.length); for (const s of m.slots) w.u8(s);
}

export function decodeWelcome(r: Reader): Welcome {
  if (r.u8() !== Msg.welcome) throw new WireError("not welcome");
  const m: Welcome = {
    protocol: r.u16(), clientId: r.u32(), resumeToken: r.bytes(16).slice(), serverTick: r.u32(),
    tickHz: r.u8(), snapshotHz: r.u8(), inputBufferTicks: r.u8(), redundancy: r.u8(), maxPlayers: r.u16(),
    configName: r.str(MAX_NAME_LEN), slots: [],
  };
  const n = r.u8();
  if (n < 1 || n > MAX_LOCAL_PLAYERS) throw new WireError("slots");
  for (let i = 0; i < n; i++) m.slots.push(r.u8());
  return m;
}

export interface Reject { code: number; message: string }
export function encodeReject(w: Writer, m: Reject): void { w.u8(Msg.reject); w.u8(m.code); w.str(m.message, MAX_CHAT_LEN); }
export function decodeReject(r: Reader): Reject {
  if (r.u8() !== Msg.reject) throw new WireError("not reject");
  return { code: r.u8(), message: r.str(MAX_CHAT_LEN) };
}

// --- Input datagram ------------------------------------------------------

export interface InputPlayer { slot: number; newestTick: number; frames: Frame[] }
export interface Input { ackSeq: number; ackBits: number; sendTime: number; players: InputPlayer[] }

export function encodeInput(w: Writer, m: Input): void {
  if (m.players.length < 1 || m.players.length > MAX_LOCAL_PLAYERS) throw new WireError("players");
  w.u8(Msg.input); w.u16(m.ackSeq); w.u32(m.ackBits); w.u16(m.sendTime); w.u8(m.players.length);
  for (const p of m.players) {
    if (p.frames.length < 1 || p.frames.length > MAX_REDUNDANCY) throw new WireError("frames");
    w.u8(p.slot); w.u32(p.newestTick); w.u8(p.frames.length);
    for (const f of p.frames) w.frame(f);
  }
}

export function decodeInput(r: Reader): Input {
  if (r.u8() !== Msg.input) throw new WireError("not input");
  const m: Input = { ackSeq: r.u16(), ackBits: r.u32(), sendTime: r.u16(), players: [] };
  const n = r.u8();
  if (n < 1 || n > MAX_LOCAL_PLAYERS) throw new WireError("players");
  for (let i = 0; i < n; i++) {
    const slot = r.u8(), newestTick = r.u32(), k = r.u8();
    if (k < 1 || k > MAX_REDUNDANCY) throw new WireError("frames");
    const frames: Frame[] = [];
    for (let j = 0; j < k; j++) {
      const f = r.frame();
      if (f.seq !== seqOf(newestTick - (k - 1 - j))) throw new WireError("frame seq");
      frames.push(f);
    }
    m.players.push({ slot, newestTick, frames });
  }
  if (!r.done()) throw new WireError("trailing bytes");
  return m;
}

// --- Snapshot ------------------------------------------------------------

export interface SnapshotPlayer { slot: number; inputAck: number; slackQ: number }
export interface SnapshotHeader { seq: number; tick: number; echoTime: number; holdMs: number; players: SnapshotPlayer[] }

export function encodeSnapshotHeader(w: Writer, h: SnapshotHeader, baseline = false): void {
  w.u8(baseline ? Msg.baseline : Msg.snapshot); w.u16(h.seq); w.u32(h.tick); w.u16(h.echoTime); w.u16(h.holdMs);
  w.u8(h.players.length);
  for (const p of h.players) { w.u8(p.slot); w.u32(p.inputAck); w.i8(p.slackQ); }
}

export function decodeSnapshotHeader(r: Reader): { header: SnapshotHeader; baseline: boolean } {
  const t = r.u8();
  if (t !== Msg.snapshot && t !== Msg.baseline) throw new WireError("not snapshot");
  const h: SnapshotHeader = { seq: r.u16(), tick: r.u32(), echoTime: r.u16(), holdMs: r.u16(), players: [] };
  const n = r.u8();
  if (n > MAX_LOCAL_PLAYERS) throw new WireError("players");
  for (let i = 0; i < n; i++) h.players.push({ slot: r.u8(), inputAck: r.u32(), slackQ: r.i8() });
  return { header: h, baseline: t === Msg.baseline };
}

export interface RecordHeader { handle: number; op: number; baseAge: number; generation: number; mask: number }

export function encodeRecordHeader(w: Writer, prev: number | null, h: RecordHeader): void {
  const base = prev === null ? 0 : prev + 1;
  if (h.handle < base) throw new WireError("records out of order");
  if ((h.op === RecordOp.update) !== (h.baseAge > 0) || h.baseAge > MAX_BASE_AGE) throw new WireError("base age");
  w.uvarint(h.handle - base);
  w.u8(h.op | (h.baseAge << 2));
  if (h.op === RecordOp.create) w.u16(h.generation);
  if (h.op !== RecordOp.remove) w.uvarint(h.mask >>> 0);
}

export function decodeRecordHeader(r: Reader, prev: number | null): RecordHeader {
  const handle = (prev === null ? 0 : prev + 1) + r.uvarint();
  if (handle > 0xffff) throw new WireError("handle");
  const ob = r.u8();
  const h: RecordHeader = { handle, op: ob & 3, baseAge: ob >> 2, generation: 0, mask: 0 };
  if (h.op > RecordOp.remove || (h.op === RecordOp.update) !== (h.baseAge > 0)) throw new WireError("op");
  if (h.op === RecordOp.create) h.generation = r.u16();
  if (h.op !== RecordOp.remove) {
    h.mask = r.uvarint();
    if (h.mask > 0xffffffff) throw new WireError("mask");
  }
  return h;
}

/** Delta codec for one component, driven by its field schema. */
export function encodeComponent(w: Writer, schema: FieldSchema, base: Record<string, number> | null, val: Record<string, number>): void {
  for (const [name, bytes, signed] of schema) {
    const bits = bytes * 8;
    const mod = 2 ** bits;
    let d = (((val[name] ?? 0) - (base ? base[name] ?? 0 : 0)) % mod + mod) % mod;
    if (d >= mod / 2) d -= mod;
    void signed;
    w.svarint(d);
  }
}

export function decodeComponent(r: Reader, schema: FieldSchema, base: Record<string, number> | null): Record<string, number> {
  const out: Record<string, number> = {};
  for (const [name, bytes, signed] of schema) {
    const bits = bytes * 8;
    const mod = 2 ** bits;
    const d = r.svarint();
    if (d < -mod / 2 || d >= mod / 2) throw new WireError("delta range");
    let v = (((base ? base[name] ?? 0 : 0) + d) % mod + mod) % mod;
    if (signed && v >= mod / 2) v -= mod;
    out[name] = v;
  }
  return out;
}

// --- Small reliable messages --------------------------------------------

export interface Chat { slot: number; text: string }
export function encodeChat(w: Writer, m: Chat, fromServer: boolean): void {
  w.u8(fromServer ? Msg.chatFrom : Msg.chat); w.u8(m.slot); w.str(m.text, MAX_CHAT_LEN);
}
export function decodeChat(r: Reader): Chat {
  const t = r.u8();
  if (t !== Msg.chat && t !== Msg.chatFrom) throw new WireError("not chat");
  return { slot: r.u8(), text: r.str(MAX_CHAT_LEN) };
}

export interface GameEvent { tick: number; kind: number; a: number; b: number; c: number; x: number; y: number; z: number }
export function encodeEvent(w: Writer, m: GameEvent): void {
  w.u8(Msg.event); w.u32(m.tick); w.u8(m.kind); w.u8(m.a); w.u8(m.b); w.u8(m.c);
  w.svarint(m.x); w.svarint(m.y); w.svarint(m.z);
}
export function decodeEvent(r: Reader): GameEvent {
  if (r.u8() !== Msg.event) throw new WireError("not event");
  return { tick: r.u32(), kind: r.u8(), a: r.u8(), b: r.u8(), c: r.u8(), x: r.svarint(), y: r.svarint(), z: r.svarint() };
}

export interface PlayerInfo { slot: number; flags: number; name: string }
export const PlayerInfoFlag = { present: 1, bot: 2 } as const;
export function encodePlayerInfo(w: Writer, m: PlayerInfo): void {
  w.u8(Msg.playerInfo); w.u8(m.slot); w.u8(m.flags); w.str(m.name, MAX_NAME_LEN);
}
export function decodePlayerInfo(r: Reader): PlayerInfo {
  if (r.u8() !== Msg.playerInfo) throw new WireError("not player_info");
  return { slot: r.u8(), flags: r.u8(), name: r.str(MAX_NAME_LEN) };
}
