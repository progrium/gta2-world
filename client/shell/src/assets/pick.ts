// Getting files from the player: a folder picker where the browser has one,
// a webkitdirectory input otherwise, plain multi-file input, and drag-drop of
// files or folders. Returns paths relative to what was picked.

import { kindOf } from "./kinds.ts";

export interface PickedFile {
  path: string;
  file: File;
}

const keep = (p: PickedFile): boolean => kindOf(p.path) !== null;

/** File System Access folder picker (Chromium). Null if unsupported or cancelled. */
export async function pickDirectory(): Promise<PickedFile[] | null> {
  const picker = (window as unknown as { showDirectoryPicker?: (o?: object) => Promise<FileSystemDirectoryHandle> }).showDirectoryPicker;
  if (!picker) return null;
  let dir: FileSystemDirectoryHandle;
  try {
    dir = await picker({ id: "gta2", mode: "read" });
  } catch {
    return [];
  }
  const out: PickedFile[] = [];
  await walkHandle(dir, "", out);
  return out.filter(keep);
}

async function walkHandle(dir: FileSystemDirectoryHandle, prefix: string, out: PickedFile[], depth = 0): Promise<void> {
  if (depth > 6) return;
  for await (const [name, h] of (dir as unknown as { entries(): AsyncIterable<[string, FileSystemHandle]> }).entries()) {
    const path = prefix + name;
    if (h.kind === "directory") await walkHandle(h as FileSystemDirectoryHandle, `${path}/`, out, depth + 1);
    else if (kindOf(name)) out.push({ path, file: await (h as FileSystemFileHandle).getFile() });
  }
}

/** Files from an <input type=file> (with or without webkitdirectory). */
export function fromInput(input: HTMLInputElement): PickedFile[] {
  return Array.from(input.files ?? [])
    .map((file) => ({ path: (file as File & { webkitRelativePath?: string }).webkitRelativePath || file.name, file }))
    .filter(keep);
}

/** Files and folders dropped on the page. */
export async function fromDrop(dt: DataTransfer): Promise<PickedFile[]> {
  const entries: FileSystemEntry[] = [];
  for (const item of Array.from(dt.items)) {
    const e = item.webkitGetAsEntry?.();
    if (e) entries.push(e);
  }
  if (entries.length === 0) return Array.from(dt.files).map((file) => ({ path: file.name, file })).filter(keep);
  const out: PickedFile[] = [];
  for (const e of entries) await walkEntry(e, "", out);
  return out.filter(keep);
}

async function walkEntry(e: FileSystemEntry, prefix: string, out: PickedFile[], depth = 0): Promise<void> {
  if (depth > 6) return;
  if (e.isFile) {
    if (!kindOf(e.name)) return;
    const file = await new Promise<File>((res, rej) => (e as FileSystemFileEntry).file(res, rej));
    out.push({ path: prefix + e.name, file });
    return;
  }
  const reader = (e as FileSystemDirectoryEntry).createReader();
  // readEntries returns batches (100 in Chrome) until an empty one.
  for (;;) {
    const batch = await new Promise<FileSystemEntry[]>((res, rej) => reader.readEntries(res, rej));
    if (batch.length === 0) break;
    for (const c of batch) await walkEntry(c, `${prefix}${e.name}/`, out, depth + 1);
  }
}
