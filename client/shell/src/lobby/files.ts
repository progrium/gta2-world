// Lobby file channel `f`: message format and the pure parts (chunk framing,
// reassembly with SHA-256 check, the transfer limit). No DOM; unit-tested in
// test/lobby.test.ts.
//
// Control messages are JSON text; file bytes are binary messages.
//
//   joiner -> host  {t:"want", map:"<first 12 hex of the .gmp SHA-256>"}
//   host -> joiner  {t:"match", description, share, files:[FileInfo...]}
//                   or {t:"error", message}
//   joiner -> host  {t:"get", files:["<sha256>", ...]}        (only the missing ones)
//   host -> joiner  {t:"refused", names:["wil.sty", ...]}      (sharing is off)
//                   or, per file: {t:"file", id, name, kind, size, sha256}
//                   then binary chunks: u32 id (little-endian) + up to 16 KB,
//                   in order, then {t:"end", id}
//   joiner -> host  {t:"got", sha256, ok}
//   joiner -> host  {t:"ready"}   all files present; nothing more is sent on `f`.
//
// The host runs at most 2 transfers at once across all peers.

import type { AssetKind } from "../assets/kinds.ts";

export const CHUNK = 16 * 1024;
export const MAX_TRANSFERS = 2;
/** Largest file a joiner accepts (the biggest .sty is a few MB). */
export const MAX_FILE = 64 << 20;
/** Sender waits while more than this is queued on the channel. */
export const HIGH_WATER = 1 << 20;

export interface FileInfo {
  name: string;
  kind: AssetKind;
  size: number;
  sha256: string;
}

export type LobbyMsg =
  | { t: "want"; map: string }
  | { t: "match"; description: string; share: boolean; files: FileInfo[] }
  | { t: "error"; message: string }
  | { t: "get"; files: string[] }
  | { t: "refused"; names: string[] }
  | ({ t: "file"; id: number } & FileInfo)
  | { t: "end"; id: number }
  | { t: "got"; sha256: string; ok: boolean }
  | { t: "ready" };

const HEX64 = /^[0-9a-f]{64}$/;
const KINDS: readonly string[] = ["gmp", "sty", "scr", "mmp", "gxt", "sdt", "raw", "gci"];

/** A file name as the joiner will store it: a bare base name (no folders) with the kind's extension, lower-cased. */
export function safeName(name: unknown, kind: unknown): string | null {
  if (typeof name !== "string" || typeof kind !== "string" || !KINDS.includes(kind)) return null;
  const base = name.toLowerCase();
  if (!/^[a-z0-9_.-]{1,64}$/.test(base) || base.startsWith(".")) return null;
  if (!base.endsWith(`.${kind}`)) return null;
  return base;
}

export function validFileInfo(f: unknown): f is FileInfo {
  if (!f || typeof f !== "object") return false;
  const o = f as Record<string, unknown>;
  return safeName(o.name, o.kind) !== null && Number.isSafeInteger(o.size) && (o.size as number) >= 0 && (o.size as number) <= MAX_FILE && typeof o.sha256 === "string" && HEX64.test(o.sha256);
}

/** Parses a text message; null for anything malformed. */
export function parseLobbyMsg(text: string): LobbyMsg | null {
  let m: unknown;
  try {
    m = JSON.parse(text);
  } catch {
    return null;
  }
  if (!m || typeof m !== "object") return null;
  const o = m as Record<string, unknown>;
  const strs = (v: unknown): v is string[] => Array.isArray(v) && v.every((x) => typeof x === "string");
  switch (o.t) {
    case "want":
      return typeof o.map === "string" && /^[0-9a-f]{12}$/.test(o.map) ? { t: "want", map: o.map } : null;
    case "match":
      return typeof o.description === "string" && typeof o.share === "boolean" && Array.isArray(o.files) && o.files.every(validFileInfo)
        ? { t: "match", description: o.description, share: o.share, files: o.files as FileInfo[] }
        : null;
    case "error":
      return typeof o.message === "string" ? { t: "error", message: o.message } : null;
    case "get":
      return strs(o.files) && o.files.every((x) => HEX64.test(x)) ? { t: "get", files: o.files } : null;
    case "refused":
      return strs(o.names) ? { t: "refused", names: o.names } : null;
    case "file":
      return Number.isInteger(o.id) && validFileInfo(o)
        ? { t: "file", id: o.id as number, name: o.name as string, kind: o.kind as AssetKind, size: o.size as number, sha256: o.sha256 as string }
        : null;
    case "end":
      return Number.isInteger(o.id) ? { t: "end", id: o.id as number } : null;
    case "got":
      return typeof o.sha256 === "string" && typeof o.ok === "boolean" ? { t: "got", sha256: o.sha256, ok: o.ok } : null;
    case "ready":
      return { t: "ready" };
  }
  return null;
}

/** One binary chunk message: u32 transfer id, then the bytes. */
export function encodeChunk(id: number, bytes: Uint8Array): Uint8Array {
  const out = new Uint8Array(4 + bytes.length);
  new DataView(out.buffer).setUint32(0, id >>> 0, true);
  out.set(bytes, 4);
  return out;
}

export function decodeChunk(buf: ArrayBuffer | Uint8Array): { id: number; bytes: Uint8Array } | null {
  const b = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  if (b.length < 4) return null;
  return { id: new DataView(b.buffer, b.byteOffset, 4).getUint32(0, true), bytes: b.subarray(4) };
}

/** Splits a file into chunk messages for transfer `id`. */
export function* chunks(id: number, data: Uint8Array, size = CHUNK): Generator<Uint8Array> {
  for (let o = 0; o < data.length; o += size) yield encodeChunk(id, data.subarray(o, Math.min(data.length, o + size)));
}

export async function sha256Hex(data: Uint8Array | ArrayBuffer): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", data as Uint8Array<ArrayBuffer>));
  let s = "";
  for (const x of d) s += x.toString(16).padStart(2, "0");
  return s;
}

/** Reassembles one file from its header and chunks, then checks size and SHA-256. */
export class Assembler {
  readonly info: FileInfo;
  readonly data: Uint8Array;
  received = 0;
  private bad: string | null = null;

  constructor(info: FileInfo) {
    this.info = info;
    this.data = new Uint8Array(info.size);
  }

  add(bytes: Uint8Array): void {
    if (this.bad) return;
    if (bytes.length > CHUNK) this.bad = "chunk too large";
    else if (this.received + bytes.length > this.info.size) this.bad = "more data than the header said";
    else {
      this.data.set(bytes, this.received);
      this.received += bytes.length;
    }
  }

  /** Resolves to the bytes if they are complete and hash to the header's SHA-256; else throws. */
  async finish(): Promise<Uint8Array> {
    if (this.bad) throw new Error(`${this.info.name}: ${this.bad}`);
    if (this.received !== this.info.size) throw new Error(`${this.info.name}: got ${this.received} of ${this.info.size} bytes`);
    const h = await sha256Hex(this.data);
    if (h !== this.info.sha256) throw new Error(`${this.info.name}: SHA-256 mismatch (got ${h.slice(0, 12)}, expected ${this.info.sha256.slice(0, 12)})`);
    return this.data;
  }
}

/** At most `n` tasks at once, the rest wait in order. */
export class Limiter {
  private running = 0;
  private waiting: (() => void)[] = [];
  readonly n: number;
  constructor(n: number) {
    this.n = n;
  }
  get active(): number {
    return this.running;
  }
  async run<T>(task: () => Promise<T>): Promise<T> {
    if (this.running >= this.n) await new Promise<void>((r) => this.waiting.push(r));
    this.running++;
    try {
      return await task();
    } finally {
      this.running--;
      this.waiting.shift()?.();
    }
  }
}
