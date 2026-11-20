// Asset worker: hashes, checks and caches the player's GTA2 files in OPFS.
// Nothing here touches the network: files go from the picked folder to the
// browser's private origin storage and nowhere else.

/// <reference lib="webworker" />

import { kindOf, parseAsset, sha256Hex } from "./kinds.ts";
import type { AssetRecord, FromWorker, Manifest, ToWorker } from "./protocol.ts";

const ROOT = "gta2";
const BLOBS = "blobs";
const MANIFEST = "manifest.json";

const post = (m: FromWorker, transfer: Transferable[] = []): void => (self as unknown as Worker).postMessage(m, transfer);

// In-memory fallback when OPFS is unavailable (some private modes).
const memBlobs = new Map<string, ArrayBuffer>();
let memManifest: Manifest = { version: 1, files: [] };

async function dirs(): Promise<{ root: FileSystemDirectoryHandle; blobs: FileSystemDirectoryHandle } | null> {
  try {
    const top = await navigator.storage.getDirectory();
    const root = await top.getDirectoryHandle(ROOT, { create: true });
    const blobs = await root.getDirectoryHandle(BLOBS, { create: true });
    return { root, blobs };
  } catch {
    return null;
  }
}

async function writeFile(dir: FileSystemDirectoryHandle, name: string, data: ArrayBuffer | Uint8Array): Promise<void> {
  const fh = await dir.getFileHandle(name, { create: true });
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  const sync = (fh as FileSystemFileHandle & { createSyncAccessHandle?: () => Promise<SyncHandle> }).createSyncAccessHandle;
  if (sync) {
    const h = await sync.call(fh);
    try {
      h.truncate(0);
      h.write(bytes, { at: 0 });
      h.flush();
    } finally {
      h.close();
    }
    return;
  }
  const w = await (fh as FileSystemFileHandle & { createWritable: () => Promise<FileSystemWritableFileStream> }).createWritable();
  await w.write(bytes as unknown as BufferSource);
  await w.close();
}

interface SyncHandle {
  truncate(n: number): void;
  write(b: Uint8Array, o: { at: number }): number;
  flush(): void;
  close(): void;
}

async function exists(dir: FileSystemDirectoryHandle, name: string): Promise<boolean> {
  try {
    await dir.getFileHandle(name);
    return true;
  } catch {
    return false;
  }
}

async function loadManifest(): Promise<{ m: Manifest; persistent: boolean }> {
  const d = await dirs();
  if (!d) return { m: memManifest, persistent: false };
  try {
    const f = await (await d.root.getFileHandle(MANIFEST)).getFile();
    const m = JSON.parse(await f.text()) as Manifest;
    if (m.version === 1 && Array.isArray(m.files)) return { m, persistent: true };
  } catch {
    /* none yet */
  }
  return { m: { version: 1, files: [] }, persistent: true };
}

async function saveManifest(m: Manifest): Promise<boolean> {
  const d = await dirs();
  if (!d) {
    memManifest = m;
    return false;
  }
  await writeFile(d.root, MANIFEST, new TextEncoder().encode(JSON.stringify(m)));
  // Drop blobs no record points at.
  const keep = new Set(m.files.map((f) => f.hash));
  const stale: string[] = [];
  for await (const name of (d.blobs as unknown as { keys(): AsyncIterable<string> }).keys()) if (!keep.has(name)) stale.push(name);
  for (const name of stale) await d.blobs.removeEntry(name).catch(() => {});
  return true;
}

async function importFiles(id: number, files: { path: string; file: File }[]): Promise<void> {
  const { m } = await loadManifest();
  const d = await dirs();
  const byPath = new Map(m.files.map((f) => [f.path.toLowerCase(), f]));
  const errors: { path: string; error: string }[] = [];
  const keep = files.filter((f) => kindOf(f.path) !== null);
  let done = 0;
  for (const { path, file } of keep) {
    post({ op: "progress", id, done, total: keep.length, path });
    try {
      const kind = kindOf(path)!;
      const buf = await file.arrayBuffer();
      const hash = await sha256Hex(buf);
      const info = parseAsset(kind, buf);
      if (!info.ok) errors.push({ path, error: info.error ?? "unreadable" });
      if (d) {
        if (!(await exists(d.blobs, hash))) await writeFile(d.blobs, hash, buf);
      } else {
        memBlobs.set(hash, buf);
      }
      const name = path.split("/").pop()!.toLowerCase();
      const rec: AssetRecord = { path, name, kind, size: buf.byteLength, hash, info, importedAt: Date.now() };
      byPath.set(path.toLowerCase(), rec);
    } catch (e) {
      errors.push({ path, error: String((e as Error)?.message ?? e) });
    }
    done++;
  }
  post({ op: "progress", id, done, total: keep.length, path: "" });
  const next: Manifest = { version: 1, files: [...byPath.values()].sort((a, b) => a.path.localeCompare(b.path)) };
  const persistent = await saveManifest(next);
  post({ op: "result", id, manifest: next, persistent, errors });
}

async function read(id: number, hash: string): Promise<void> {
  const d = await dirs();
  let data: ArrayBuffer | undefined;
  if (d) {
    try {
      data = await (await (await d.blobs.getFileHandle(hash)).getFile()).arrayBuffer();
    } catch {
      /* missing */
    }
  } else {
    data = memBlobs.get(hash)?.slice(0);
  }
  if (!data) return post({ op: "error", id, error: `no cached file ${hash}` });
  // Verify on the way out: a damaged cache entry must not reach the parsers.
  if ((await sha256Hex(data)) !== hash) return post({ op: "error", id, error: `cached file ${hash} is damaged; re-import` });
  post({ op: "result", id, data, persistent: !!d }, [data]);
}

async function clear(id: number): Promise<void> {
  memBlobs.clear();
  memManifest = { version: 1, files: [] };
  try {
    const top = await navigator.storage.getDirectory();
    await top.removeEntry(ROOT, { recursive: true });
  } catch {
    /* nothing there */
  }
  post({ op: "result", id, manifest: memManifest, persistent: false });
}

self.onmessage = (ev: MessageEvent<ToWorker>): void => {
  const m = ev.data;
  const fail = (e: unknown): void => post({ op: "error", id: m.id, error: String((e as Error)?.message ?? e) });
  switch (m.op) {
    case "import":
      importFiles(m.id, m.files).catch(fail);
      break;
    case "manifest":
      loadManifest()
        .then(({ m: man, persistent }) => post({ op: "result", id: m.id, manifest: man, persistent }))
        .catch(fail);
      break;
    case "read":
      read(m.id, m.hash).catch(fail);
      break;
    case "clear":
      clear(m.id).catch(fail);
      break;
  }
};
