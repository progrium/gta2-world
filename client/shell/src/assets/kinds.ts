// Which GTA2 data files the shell keeps, and a light structural parse of each.
// Layouts are from the public DMA format documents: .gmp and .sty start with a
// 4-byte magic and a u16 version, then chunks of (4-byte type, u32 size, data).
// Full parsing is formats/ (Zig, workstream B); this only checks a file is what
// its name says and records its chunk index so a bad copy is caught on import.

import { checkSdt } from "../audio/sdt.ts";

export type AssetKind = "gmp" | "sty" | "scr" | "mmp" | "gxt" | "sdt" | "raw" | "gci" | "seq";

const EXT: Record<string, AssetKind> = {
  gmp: "gmp", sty: "sty", scr: "scr", mmp: "mmp", gxt: "gxt", sdt: "sdt", raw: "raw", gci: "gci", seq: "seq",
};

/** Kind from the file name, or null if the shell doesn't keep this file. */
export function kindOf(name: string): AssetKind | null {
  const m = /\.([A-Za-z0-9]+)$/.exec(name);
  return m ? EXT[m[1]!.toLowerCase()] ?? null : null;
}

export interface Chunk {
  type: string;
  offset: number;
  size: number;
}

export interface ParsedInfo {
  ok: boolean;
  error?: string;
  version?: number;
  chunks?: Chunk[];
  /** .mmp: the map entry it describes. */
  map?: MapEntry;
  /** .seq: the levels it lists, in order. */
  levels?: LevelEntry[];
  /** .sdt: how many samples it indexes, and the size its .raw must have. */
  samples?: number;
  rawSize?: number;
}

export interface MapEntry {
  description: string;
  gmp: string;
  sty: string;
  scr: string | null;
}

/** A single-player level from a .seq file: a main area or a bonus stage. */
export interface LevelEntry extends MapEntry {
  bonus: boolean;
}

const MAGIC: Partial<Record<AssetKind, string>> = { gmp: "GBMP", sty: "GBST" };

const ascii = (b: Uint8Array, o: number, n: number): string => String.fromCharCode(...b.subarray(o, o + n));

export function parseChunks(buf: ArrayBuffer, magic: string): ParsedInfo {
  const b = new Uint8Array(buf);
  if (b.length < 6) return { ok: false, error: "file too short" };
  if (ascii(b, 0, 4) !== magic) return { ok: false, error: `expected ${magic} header` };
  const dv = new DataView(buf);
  const version = dv.getUint16(4, true);
  const chunks: Chunk[] = [];
  let o = 6;
  while (o + 8 <= b.length) {
    const type = ascii(b, o, 4);
    if (!/^[A-Z0-9 ]{4}$/.test(type)) return { ok: false, error: `bad chunk type at ${o}`, version, chunks };
    const size = dv.getUint32(o + 4, true);
    if (o + 8 + size > b.length) return { ok: false, error: `chunk ${type} overruns file`, version, chunks };
    chunks.push({ type, offset: o + 8, size });
    o += 8 + size;
  }
  if (o !== b.length) return { ok: false, error: "trailing bytes", version, chunks };
  return { ok: true, version, chunks };
}

/** .mmp is a small INI: [MapFiles] GMPFile, STYFile, SCRFile, Description. */
export function parseMmp(text: string): ParsedInfo {
  const kv = new Map<string, string>();
  for (const line of text.split(/\r?\n/)) {
    const m = /^\s*([A-Za-z]+)\s*=\s*(.*?)\s*$/.exec(line);
    if (m) kv.set(m[1]!.toLowerCase(), m[2]!);
  }
  const gmp = kv.get("gmpfile");
  const sty = kv.get("styfile");
  if (!gmp || !sty) return { ok: false, error: "missing GMPFile or STYFile" };
  return { ok: true, map: { description: kv.get("description") || gmp, gmp, sty, scr: kv.get("scrfile") || null } };
}

/**
 * .seq is a list of level blocks in the same key = value form as .mmp:
 * MainOrBonus (MAIN or BONUS), GMPFile, STYFile, SCRFile, Description.
 * A new MainOrBonus line starts a block.
 */
export function parseSeq(text: string): ParsedInfo {
  const levels: LevelEntry[] = [];
  let kv: Map<string, string> | null = null;
  const flush = (): void => {
    if (!kv) return;
    const gmp = kv.get("gmpfile");
    const sty = kv.get("styfile");
    if (gmp && sty) levels.push({ description: kv.get("description") || gmp, gmp, sty, scr: kv.get("scrfile") || null, bonus: /^bonus$/i.test(kv.get("mainorbonus") ?? "") });
    kv = null;
  };
  for (const line of text.split(/\r?\n/)) {
    const m = /^\s*([A-Za-z]+)\s*=\s*(.*?)\s*$/.exec(line);
    if (!m) continue;
    const k = m[1]!.toLowerCase();
    if (k === "mainorbonus") flush();
    kv ??= new Map();
    kv.set(k, m[2]!);
  }
  flush();
  if (levels.length === 0) return { ok: false, error: "no levels listed" };
  return { ok: true, levels };
}

export function parseAsset(kind: AssetKind, buf: ArrayBuffer): ParsedInfo {
  const magic = MAGIC[kind];
  if (magic) return parseChunks(buf, magic);
  if (kind === "mmp") return parseMmp(new TextDecoder("latin1").decode(buf));
  if (kind === "seq") return parseSeq(new TextDecoder("latin1").decode(buf));
  if (kind === "sdt") {
    const c = checkSdt(buf);
    return { ok: c.ok, error: c.error, samples: c.count, rawSize: c.rawSize };
  }
  return { ok: buf.byteLength > 0, error: buf.byteLength > 0 ? undefined : "empty file" };
}

export async function sha256Hex(buf: ArrayBuffer): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", buf));
  let s = "";
  for (const x of d) s += x.toString(16).padStart(2, "0");
  return s;
}
