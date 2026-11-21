// The sound API the game screen uses:
//
//   audio.play(cue, x, y, z)       one-shot at a world position (blocks)
//   audio.setListener(x, y, z)     the camera, once per frame
//   audio.setEngine(id, speed)     per driven car, every tick (blocks/tick);
//                                  stops by itself when the calls stop
//
// plus audio.volume, audio.muted and audio.toggleMute(). Samples come from the
// player's own banks (data/audio/<map>.sdt/.raw and fstyle.sdt/.raw) through
// the mapping made on the sound board, plus the spoken lines in
// data/audio/Vocals/*.wav; unmapped cues play a procedural sound.

import type { AssetStore, MapChoice } from "../assets/store.ts";
import { AudioEngine, type Bank, type BankId } from "./engine.ts";
import { SoundBank } from "./sdt.ts";
import { VocalBank } from "./wav.ts";

export { CUES, CUE_LABELS, type Cue } from "./cues.ts";
export { AudioEngine } from "./engine.ts";

export const audio = new AudioEngine();

/** The map's bank shares the map's base name (wil.gmp → wil.sdt). */
export function mapBankName(map: Pick<MapChoice, "gmp">): string {
  return map.gmp.toLowerCase().split(/[\\/]/).pop()!.replace(/\.gmp$/, "");
}

/**
 * Loads the map bank and fstyle into the engine. A map without its own bank
 * borrows another map's: the shipped map banks share one layout.
 */
export async function loadBanks(store: AssetStore, map: Pick<MapChoice, "gmp">, engine: AudioEngine = audio): Promise<Partial<Record<BankId, string>>> {
  const banks: Partial<Record<BankId, Bank>> = {};
  const names: Partial<Record<BankId, string>> = {};
  const pair = async (base: string): Promise<SoundBank | null> => {
    const s = store.find(`${base}.sdt`);
    const r = store.find(`${base}.raw`);
    if (!s || !r || !s.info.ok || !r.info.ok) return null;
    const [sdt, raw] = await Promise.all([store.read(s.hash), store.read(r.hash)]);
    return new SoundBank(base, sdt, raw);
  };
  const want = mapBankName(map);
  // Multiplayer maps are named after their district (wil-multi.gmp → wil.sdt).
  const district = want.split(/[-_]/)[0]!;
  const first = district === want ? [want] : [want, district];
  const others = store.manifest.files.filter((f) => f.kind === "sdt" && f.name !== "fstyle.sdt" && !first.includes(f.name.replace(/\.sdt$/, ""))).map((f) => f.name.replace(/\.sdt$/, ""));
  for (const base of [...first, ...others]) {
    const b = await pair(base).catch(() => null);
    if (b) {
      banks.map = b;
      names.map = `${base}.sdt`;
      break;
    }
  }
  const f = await pair("fstyle").catch(() => null);
  if (f) {
    banks.fstyle = f;
    names.fstyle = "fstyle.sdt";
  }
  const wavs = store.manifest.files.filter((f) => f.kind === "wav" && f.info.ok);
  if (wavs.length) {
    const files = await Promise.all(wavs.map(async (f) => ({ name: f.name, buf: await store.read(f.hash).catch(() => null) })));
    const v = new VocalBank(files.filter((f): f is { name: string; buf: ArrayBuffer } => f.buf !== null));
    if (v.names.length) {
      banks.vocals = v;
      names.vocals = `Vocals (${v.names.length} lines)`;
    }
  }
  engine.setBanks(banks, names);
  return names;
}
