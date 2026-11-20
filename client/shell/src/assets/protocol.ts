// Messages between the asset store (main thread) and its worker.

import type { AssetKind, ParsedInfo } from "./kinds.ts";

export interface AssetRecord {
  /** Path as picked, relative to the chosen folder; the lookup key. */
  path: string;
  /** Lower-cased base name, for .mmp references (which use other cases). */
  name: string;
  kind: AssetKind;
  size: number;
  /** SHA-256 hex. The OPFS blob is stored under this name. */
  hash: string;
  info: ParsedInfo;
  importedAt: number;
}

export interface Manifest {
  version: 1;
  files: AssetRecord[];
}

export type ToWorker =
  | { op: "import"; id: number; files: { path: string; file: File }[] }
  | { op: "manifest"; id: number }
  | { op: "read"; id: number; hash: string }
  | { op: "clear"; id: number };

export type FromWorker =
  | { op: "progress"; id: number; done: number; total: number; path: string }
  | { op: "result"; id: number; manifest?: Manifest; data?: ArrayBuffer; persistent: boolean; errors?: { path: string; error: string }[] }
  | { op: "error"; id: number; error: string };
