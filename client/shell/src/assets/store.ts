// Main-thread side of the asset cache. Owns the worker; everything else asks
// this for files by name or hash.

import type { AssetRecord, FromWorker, Manifest, ToWorker } from "./protocol.ts";
import type { LevelEntry, MapEntry } from "./kinds.ts";

export interface ImportResult {
  manifest: Manifest;
  persistent: boolean;
  errors: { path: string; error: string }[];
}

export interface MapChoice extends MapEntry {
  /** The .mmp file this came from, or null for a bare gmp/sty pair. */
  mmp: string | null;
  gmpRecord: AssetRecord;
  styRecord: AssetRecord;
  scrRecord: AssetRecord | null;
  /** A single-player level (story area or bonus stage), not a deathmatch map. */
  story?: { bonus: boolean; index: number };
}

type Pending = { resolve: (m: FromWorker & { op: "result" }) => void; reject: (e: Error) => void; progress?: (done: number, total: number, path: string) => void };

export class AssetStore {
  private worker: Worker;
  private seq = 1;
  private pending = new Map<number, Pending>();
  manifest: Manifest = { version: 1, files: [] };
  persistent = false;

  constructor(workerUrl: URL | string = new URL("./worker.js", import.meta.url)) {
    this.worker = new Worker(workerUrl, { type: "module", name: "assets" });
    this.worker.onmessage = (ev: MessageEvent<FromWorker>) => {
      const m = ev.data;
      const p = this.pending.get(m.id);
      if (!p) return;
      if (m.op === "progress") return p.progress?.(m.done, m.total, m.path);
      this.pending.delete(m.id);
      if (m.op === "error") p.reject(new Error(m.error));
      else p.resolve(m);
    };
  }

  private call(msg: Omit<ToWorker, "id">, progress?: Pending["progress"]): Promise<FromWorker & { op: "result" }> {
    const id = this.seq++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject, progress });
      this.worker.postMessage({ ...msg, id } as ToWorker);
    });
  }

  async load(): Promise<Manifest> {
    const r = await this.call({ op: "manifest" });
    this.manifest = r.manifest!;
    this.persistent = r.persistent;
    return this.manifest;
  }

  async import(files: { path: string; file: File }[], progress?: Pending["progress"]): Promise<ImportResult> {
    const r = await this.call({ op: "import", files } as Omit<ToWorker, "id">, progress);
    this.manifest = r.manifest!;
    this.persistent = r.persistent;
    return { manifest: this.manifest, persistent: r.persistent, errors: r.errors ?? [] };
  }

  async clear(): Promise<void> {
    await this.call({ op: "clear" });
    this.manifest = { version: 1, files: [] };
  }

  /** Read a cached file's bytes; the worker re-checks the hash. */
  async read(hash: string): Promise<ArrayBuffer> {
    const r = await this.call({ op: "read", hash } as Omit<ToWorker, "id">);
    return r.data!;
  }

  /** Find a record by file name, case-insensitively (.mmp files use mixed case). */
  find(name: string): AssetRecord | null {
    const n = name.toLowerCase().split(/[\\/]/).pop()!;
    return this.manifest.files.find((f) => f.name === n) ?? null;
  }

  /** Maps the player can start: every valid .mmp whose files are present, else every gmp with a same-named sty. */
  maps(): MapChoice[] {
    return listMaps(this.manifest.files);
  }

  /** Single-player levels the player can start (see `listLevels`). */
  levels(): MapChoice[] {
    return listLevels(this.manifest.files);
  }

  /** A level's script files: its main .scr and the mission sub-scripts in the folder named after it. */
  scripts(level: MapChoice): AssetRecord[] {
    return levelScripts(this.manifest.files, level);
  }
}

export function listMaps(files: readonly AssetRecord[]): MapChoice[] {
  const by = (n: string): AssetRecord | null => files.find((f) => f.name === n.toLowerCase()) ?? null;
  const ok = (r: AssetRecord | null): r is AssetRecord => !!r && r.info.ok;
  const out: MapChoice[] = [];
  for (const f of files) {
    if (f.kind !== "mmp" || !f.info.ok || !f.info.map) continue;
    const e = f.info.map;
    const g = by(e.gmp);
    const s = by(e.sty);
    if (!ok(g) || !ok(s)) continue;
    out.push({ ...e, mmp: f.name, gmpRecord: g, styRecord: s, scrRecord: e.scr ? by(e.scr) : null });
  }
  if (out.length > 0) return out.sort((a, b) => a.description.localeCompare(b.description));
  for (const g of files) {
    if (g.kind !== "gmp" || !g.info.ok) continue;
    const base = g.name.replace(/\.gmp$/, "");
    const s = by(`${base}.sty`);
    if (!ok(s)) continue;
    const scr = by(`${base}.scr`);
    out.push({ description: base, gmp: g.name, sty: s.name, scr: scr?.name ?? null, mmp: null, gmpRecord: g, styRecord: s, scrRecord: scr });
  }
  return out;
}

/**
 * Single-player levels: those a .seq file lists, in its order, whose .gmp,
 * .sty and .scr are present. Without a .seq, every .gmp with a same-named
 * .sty and .scr is a main area.
 */
export function listLevels(files: readonly AssetRecord[]): MapChoice[] {
  const by = (n: string): AssetRecord | null => files.find((f) => f.name === n.toLowerCase()) ?? null;
  const ok = (r: AssetRecord | null): r is AssetRecord => !!r && r.info.ok;
  const out: MapChoice[] = [];
  const seen = new Set<string>();
  const add = (e: LevelEntry, mmp: string | null): void => {
    const g = by(e.gmp);
    const s = by(e.sty);
    const c = e.scr ? by(e.scr) : null;
    if (!ok(g) || !ok(s) || !ok(c) || seen.has(g.name)) return;
    seen.add(g.name);
    out.push({ description: e.description, gmp: e.gmp, sty: e.sty, scr: e.scr, mmp, gmpRecord: g, styRecord: s, scrRecord: c, story: { bonus: e.bonus, index: out.length } });
  };
  for (const f of files) if (f.kind === "seq" && f.info.ok) for (const e of f.info.levels ?? []) add(e, f.name);
  if (out.length > 0) return out;
  for (const g of files) {
    if (g.kind !== "gmp" || !g.info.ok) continue;
    const base = g.name.replace(/\.gmp$/, "");
    add({ description: base, gmp: g.name, sty: `${base}.sty`, scr: `${base}.scr`, bonus: false }, null);
  }
  return out;
}

/** The main .scr, then the .scr files in a folder named after it (its mission sub-scripts). */
export function levelScripts(files: readonly AssetRecord[], level: MapChoice): AssetRecord[] {
  if (!level.scrRecord) return [];
  const base = level.scrRecord.name.replace(/\.scr$/, "");
  const subs = files.filter((f) => f.kind === "scr" && f !== level.scrRecord && f.path.toLowerCase().split(/[\\/]/).slice(0, -1).includes(base));
  const names = new Set<string>();
  return [level.scrRecord, ...subs].filter((f) => (names.has(f.name) ? false : (names.add(f.name), true)));
}
