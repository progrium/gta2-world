// Reading the GTA2 freeware installer in the browser, as it downloads.
//
// The installer is a Windows stub followed by a plain list of entries:
// name\0 path\0 version\0 decimal-size\0 then that many bytes. Inside are an
// InstallShield cabinet set (data1.hdr, data1.cab, data2.cab), whose header
// lists every file with its volume, offset and sizes. Compressed files are a
// run of chunks, each a u16 length and that many bytes of raw deflate.
//
// The download is pushed through in pieces and only the byte ranges of the
// files the game keeps are held, so the whole installer is never in memory.

import { kindOf } from "./kinds.ts";
import type { PickedFile } from "./pick.ts";

export interface CabFile {
  /** Path inside the cabinet, with / separators. */
  path: string;
  flags: number;
  expanded: number;
  compressed: number;
  offset: number;
  volume: number;
}

const FILE_SPLIT = 1;
const FILE_OBFUSCATED = 2;
const FILE_COMPRESSED = 4;
const FILE_INVALID = 8;

const u16 = (b: Uint8Array, o: number): number => b[o]! | (b[o + 1]! << 8);
const u32 = (b: Uint8Array, o: number): number => (b[o]! | (b[o + 1]! << 8) | (b[o + 2]! << 16) | (b[o + 3]! << 24)) >>> 0;
const u64 = (b: Uint8Array, o: number): number => u32(b, o) + u32(b, o + 4) * 2 ** 32;
const cstr = (b: Uint8Array, o: number): string => {
  let e = o;
  while (e < b.length && b[e] !== 0) e++;
  return String.fromCharCode(...b.subarray(o, e));
};

/** The file list in an InstallShield 6+ cabinet header (dataN.hdr). */
export function parseCabHeader(hdr: Uint8Array): CabFile[] {
  if (cstr(hdr, 0).slice(0, 4) !== "ISc(") throw new Error("not an InstallShield cabinet header");
  const desc = u32(hdr, 12);
  const tableOff = desc + u32(hdr, desc + 0x0c);
  const dirCount = u32(hdr, desc + 0x1c);
  const fileCount = u32(hdr, desc + 0x28);
  const descOff = tableOff + u32(hdr, desc + 0x2c);
  if (descOff + fileCount * 0x57 > hdr.length) throw new Error("cabinet header is truncated");
  const dirs: string[] = [];
  for (let i = 0; i < dirCount; i++) dirs.push(cstr(hdr, tableOff + u32(hdr, tableOff + 4 * i)));
  const out: CabFile[] = [];
  for (let i = 0; i < fileCount; i++) {
    const p = descOff + i * 0x57;
    const flags = u16(hdr, p);
    const name = cstr(hdr, tableOff + u32(hdr, p + 0x3a));
    const dir = dirs[u16(hdr, p + 0x3e)] ?? "";
    out.push({
      path: (dir ? `${dir}\\${name}` : name).replace(/\\/g, "/"),
      flags,
      expanded: u64(hdr, p + 2),
      compressed: u64(hdr, p + 10),
      offset: u64(hdr, p + 18),
      volume: u16(hdr, p + 0x55),
    });
  }
  return out;
}

/**
 * The files the game uses from the cabinet: the data/ folder's maps, styles,
 * scripts, text, sound banks and spoken lines. The music in data/GTAudio
 * (about 290 MB) is left out, since nothing plays it yet.
 */
export function wanted(files: readonly CabFile[]): CabFile[] {
  return files.filter(
    (f) => !(f.flags & FILE_INVALID) && f.expanded > 0 && /(^|\/)data\//i.test(f.path) && !/(^|\/)data\/gtaudio\//i.test(f.path) && kindOf(f.path) !== null,
  );
}

async function inflateRaw(data: Uint8Array): Promise<Uint8Array> {
  const s = new Blob([data as BlobPart]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
  return new Uint8Array(await new Response(s).arrayBuffer());
}

/** A file's bytes from its stored (possibly compressed) form. */
export async function expand(f: CabFile, stored: Uint8Array): Promise<Uint8Array> {
  if (f.flags & FILE_OBFUSCATED) throw new Error(`${f.path}: obfuscated files are not supported`);
  if (!(f.flags & FILE_COMPRESSED)) return stored.subarray(0, f.expanded);
  const out = new Uint8Array(f.expanded);
  let o = 0;
  let n = 0;
  while (o + 2 <= stored.length && n < f.expanded) {
    const len = u16(stored, o);
    o += 2;
    if (o + len > stored.length) throw new Error(`${f.path}: compressed chunk overruns the file`);
    const part = await inflateRaw(stored.subarray(o, o + len));
    o += len;
    if (n + part.length > f.expanded) throw new Error(`${f.path}: expands past its size`);
    out.set(part, n);
    n += part.length;
  }
  if (n !== f.expanded) throw new Error(`${f.path}: expanded to ${n} bytes, expected ${f.expanded}`);
  return out;
}

export interface Extracted {
  path: string;
  data: Uint8Array;
}

interface Entry {
  path: string;
  size: number;
  start: number;
}

/**
 * Takes the installer's bytes in order and keeps what the game needs.
 * push() every chunk of the download, then finish() for the extracted files.
 */
export class InstallerReader {
  private pos = 0;
  private stubEnd = -1;
  private head = new Uint8Array(0);
  private entry: Entry | null = null;
  private meta = new Uint8Array(0);
  private kept = new Map<string, Uint8Array>();
  private cab: CabFile[] | null = null;
  private volume = new Map<number, { file: CabFile; buf: Uint8Array }[]>();
  private volumes = new Map<string, number>();

  push(chunk: Uint8Array): void {
    let c = chunk;
    while (c.length > 0) {
      if (this.stubEnd < 0) {
        c = this.readStub(c);
        continue;
      }
      if (this.pos < this.stubEnd) {
        const skip = Math.min(c.length, this.stubEnd - this.pos);
        this.pos += skip;
        c = c.subarray(skip);
        continue;
      }
      if (!this.entry) {
        c = this.readEntryHead(c);
        continue;
      }
      const e = this.entry;
      const take = Math.min(c.length, e.start + e.size - this.pos);
      this.body(e, c.subarray(0, take), this.pos - e.start);
      this.pos += take;
      c = c.subarray(take);
      if (this.pos === e.start + e.size) this.entryDone(e);
    }
  }

  /** The PE stub's length comes from its section table; the entries follow it. */
  private readStub(c: Uint8Array): Uint8Array {
    const need = 0x400;
    const take = Math.min(c.length, need - this.head.length);
    this.head = concat(this.head, c.subarray(0, take));
    this.pos += take;
    if (this.head.length < need) return c.subarray(take);
    const h = this.head;
    if (h[0] !== 0x4d || h[1] !== 0x5a) throw new Error("not a Windows installer");
    const pe = u32(h, 0x3c);
    const n = u16(h, pe + 6);
    const sec = pe + 24 + u16(h, pe + 20);
    if (sec + 40 * n > need) throw new Error("unexpected installer layout");
    let end = 0;
    for (let i = 0; i < n; i++) end = Math.max(end, u32(h, sec + 40 * i + 20) + u32(h, sec + 40 * i + 16));
    if (end < need) throw new Error("unexpected installer layout");
    this.stubEnd = end;
    this.head = new Uint8Array(0);
    return c.subarray(take);
  }

  /** Four NUL-terminated strings: name, path, version, size. */
  private readEntryHead(c: Uint8Array): Uint8Array {
    let nul = 0;
    for (const b of this.meta) if (b === 0) nul++;
    let i = 0;
    while (i < c.length && nul < 4) if (c[i++] === 0) nul++;
    this.meta = concat(this.meta, c.subarray(0, i));
    this.pos += i;
    if (nul < 4) return c.subarray(i);
    const parts: string[] = [];
    let s = 0;
    for (let j = 0; j < this.meta.length; j++) {
      if (this.meta[j] === 0) {
        parts.push(String.fromCharCode(...this.meta.subarray(s, j)));
        s = j + 1;
      }
    }
    if (this.meta.length > 1024) throw new Error("unexpected installer layout");
    const size = Number(parts[3]);
    if (!Number.isSafeInteger(size) || size < 0) throw new Error("unexpected installer layout");
    this.meta = new Uint8Array(0);
    this.entry = { path: parts[1]!.replace(/\\/g, "/"), size, start: this.pos };
    this.entryStart(this.entry);
    if (size === 0) this.entryDone(this.entry);
    return c.subarray(i);
  }

  private base(p: string): string {
    return p.split("/").pop()!.toLowerCase();
  }

  private entryStart(e: Entry): void {
    const name = this.base(e.path);
    if (/^data\d+\.hdr$/.test(name)) this.kept.set(name, new Uint8Array(e.size));
    const m = /^data(\d+)\.cab$/.exec(name);
    if (m) {
      const vol = Number(m[1]);
      this.volumes.set(name, vol);
      if (!this.cab) this.kept.set(name, new Uint8Array(e.size)); // header not seen yet: keep it all
      else this.volume.set(vol, this.slots(vol));
    }
  }

  private slots(vol: number): { file: CabFile; buf: Uint8Array }[] {
    return wanted(this.cab!)
      .filter((f) => f.volume === vol)
      .map((file) => {
        if (file.flags & FILE_SPLIT) throw new Error(`${file.path} spans two cabinet volumes, which is not supported`);
        return { file, buf: new Uint8Array(file.compressed) };
      });
  }

  private body(e: Entry, bytes: Uint8Array, at: number): void {
    const name = this.base(e.path);
    const whole = this.kept.get(name);
    if (whole) {
      whole.set(bytes, at);
      return;
    }
    const vol = this.volumes.get(name);
    if (vol === undefined) return;
    for (const s of this.volume.get(vol) ?? []) {
      const a = Math.max(at, s.file.offset);
      const b = Math.min(at + bytes.length, s.file.offset + s.file.compressed);
      if (a < b) s.buf.set(bytes.subarray(a - at, b - at), a - s.file.offset);
    }
  }

  private entryDone(e: Entry): void {
    this.entry = null;
    const name = this.base(e.path);
    if (name === "data1.hdr") {
      this.cab = parseCabHeader(this.kept.get(name)!);
      // A volume that arrived before the header was kept whole; slice it now.
      for (const [cab, vol] of this.volumes) {
        const whole = this.kept.get(cab);
        if (!whole) continue;
        this.kept.delete(cab);
        const slots = this.slots(vol);
        for (const s of slots) s.buf.set(whole.subarray(s.file.offset, s.file.offset + s.file.compressed));
        this.volume.set(vol, slots);
      }
    }
  }

  /** Call after the last push. Expands and returns the game's files. */
  async finish<T = Extracted>(onFile?: (done: number, total: number, path: string) => void, keep: (e: Extracted) => T = (e) => e as T): Promise<T[]> {
    if (this.entry || this.meta.length || this.stubEnd < 0 || this.pos < this.stubEnd) throw new Error("the download ended early");
    if (!this.cab) throw new Error("no InstallShield cabinet found in the installer");
    const slots = [...this.volume.values()].flat();
    const want = wanted(this.cab);
    if (slots.length < want.length) throw new Error("some cabinet volumes were missing from the installer");
    const out: T[] = [];
    for (const s of slots) {
      onFile?.(out.length, slots.length, s.file.path);
      out.push(keep({ path: s.file.path.replace(/^.*?(data\/)/i, "$1"), data: await expand(s.file, s.buf) }));
      s.buf = new Uint8Array(0);
    }
    return out;
  }
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  if (a.length === 0) return b.slice();
  const o = new Uint8Array(a.length + b.length);
  o.set(a);
  o.set(b, a.length);
  return o;
}

/** The Internet Archive item: Rockstar's freeware release of GTA2. */
export const ARCHIVE_ITEM = "gta2_rockstar-classics";
export const ARCHIVE_PAGE = `https://archive.org/details/${ARCHIVE_ITEM}`;
/** archive.org's CORS endpoint, so the browser can read the download itself. */
export const ARCHIVE_URL = `https://archive.org/cors/${ARCHIVE_ITEM}/GTA2INSTALLER.exe`;
export const ARCHIVE_SIZE = 362331961;

/**
 * Downloads the installer from the Internet Archive straight into this browser
 * and returns the game files inside it. Nothing passes through our servers.
 */
export async function downloadFromArchive(
  progress: (phase: "download" | "extract", done: number, total: number, path?: string) => void,
  signal?: AbortSignal,
  url = ARCHIVE_URL,
): Promise<PickedFile[]> {
  const res = await fetch(url, { signal, credentials: "omit" });
  if (!res.ok || !res.body) throw new Error(`the Internet Archive answered ${res.status}`);
  const total = Number(res.headers.get("content-length")) || ARCHIVE_SIZE;
  const reader = new InstallerReader();
  const rd = res.body.getReader();
  let done = 0;
  for (;;) {
    const { value, done: end } = await rd.read();
    if (end) break;
    reader.push(value);
    done += value.length;
    progress("download", done, total);
  }
  // Each file goes into a File as it is expanded, so the browser can keep it
  // off the JS heap; the stored bytes are dropped as they are used.
  return reader.finish(
    (d, t, p) => progress("extract", d, t, p),
    (e) => ({ path: e.path, file: new File([e.data as BlobPart], e.path.split("/").pop()!) }),
  );
}
