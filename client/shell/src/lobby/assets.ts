// The lobby's view of the local asset store (OPFS, keyed by SHA-256): which
// files a match needs, whether we have them, and keeping received ones.

import type { AssetRecord } from "../assets/protocol.ts";
import type { AssetStore, MapChoice } from "../assets/store.ts";
import type { FileInfo } from "./files.ts";
import type { HostFiles, JoinStore, MatchFiles } from "./lobby.ts";

/** Received files are imported under this folder name, next to the player's own. */
export const SHARED_DIR = "shared";

const info = (r: AssetRecord): FileInfo => ({ name: r.name, kind: r.kind, size: r.size, sha256: r.hash });

/** The .gci (car handling) a game uses: the player's imported one, if any. Offline and hosted games pick it the same way. */
export function carInfoRecord(store: AssetStore): AssetRecord | null {
  return store.manifest.files.find((f) => f.kind === "gci") ?? null;
}

/**
 * The files a joiner needs for a match on `map`: the .gmp (its SHA-256 is the
 * map hash in hello), the .sty, and the host's .gci when it has one. The car
 * models come from the .sty and .gci, and every player must build the same
 * ones as the host (gameScreen). Sound banks are optional (procedural fallback).
 */
export function hostFiles(store: AssetStore, map: MapChoice, share: () => boolean, gci: AssetRecord | null = null): HostFiles {
  return {
    mapHash: map.gmpRecord.hash,
    description: map.description,
    files: [info(map.gmpRecord), info(map.styRecord), ...(gci ? [info(gci)] : [])],
    share,
    read: async (sha) => new Uint8Array(await store.read(sha)),
  };
}

export function joinStore(store: AssetStore): JoinStore {
  // One import at a time: each import rewrites the manifest, and two at once
  // would race on it (and on OPFS access handles).
  let chain: Promise<unknown> = Promise.resolve();
  return {
    has: (sha) => store.manifest.files.some((f) => f.hash === sha),
    save: (f, bytes) => {
      const run = async (): Promise<void> => {
        const file = new File([bytes as Uint8Array<ArrayBuffer>], f.name);
        const r = await store.import([{ path: `${SHARED_DIR}/${f.name}`, file }]);
        if (!r.manifest.files.some((x) => x.hash === f.sha256)) throw new Error(`could not keep ${f.name} in this browser`);
      };
      const p = chain.then(run, run);
      chain = p.catch(() => {});
      return p;
    },
  };
}

/** The SHA-256 of the match's .gci, or null when the host plays with style-only car models. */
export function gciFromMatch(m: MatchFiles): string | null {
  return m.files.find((f) => f.kind === "gci")?.sha256 ?? null;
}

/** The MapChoice for a match whose files are all in the store now. */
export function mapFromMatch(store: AssetStore, m: MatchFiles): MapChoice {
  const rec = (kind: string): AssetRecord => {
    const want = m.files.find((f) => f.kind === kind);
    const r = want && store.manifest.files.find((f) => f.hash === want.sha256);
    if (!r) throw new Error(`the match has no ${kind} file`);
    return r;
  };
  const gmp = rec("gmp");
  const sty = rec("sty");
  return { description: m.description, gmp: gmp.name, sty: sty.name, scr: null, mmp: null, gmpRecord: gmp, styRecord: sty, scrRecord: null };
}
