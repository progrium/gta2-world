// The fixed list of game sounds, and the player's mapping from each one to
// samples in their own sound banks. The mapping is made by ear on the sound
// board, kept in localStorage and exported as JSON.

export const CUES = [
  "pistol",
  "machine_gun",
  "shotgun",
  "rocket_launch",
  "explosion",
  "bullet_hit",
  "ped_hurt",
  "ped_death",
  "car_crash",
  "car_door",
  "pickup",
  "weapon_switch",
  "horn",
  "engine",
] as const;

export type Cue = (typeof CUES)[number];

export const CUE_LABELS: Record<Cue, string> = {
  pistol: "Pistol shot",
  machine_gun: "Machine gun shot",
  shotgun: "Shotgun shot",
  rocket_launch: "Rocket launch",
  explosion: "Explosion",
  bullet_hit: "Bullet hit",
  ped_hurt: "Pedestrian hurt",
  ped_death: "Pedestrian death",
  car_crash: "Car crash",
  car_door: "Car door",
  pickup: "Pickup collected",
  weapon_switch: "Weapon switch",
  horn: "Horn",
  engine: "Engine loop (pitch follows speed)",
};

export const isCue = (s: string): s is Cue => (CUES as readonly string[]).includes(s);

/**
 * A sample reference. `bank` is "map" (the current map's bank, e.g. wil.sdt;
 * the shipped map banks share one layout, so an index means the same sound in
 * each, apart from a small per-district block around #122 to #137) or "fstyle" (the shared fstyle.sdt bank).
 */
export interface SampleRef {
  bank: "map" | "fstyle";
  index: number;
  /** Force an encoding when the guess is wrong. */
  format?: "s16" | "u8";
}

export interface CueMapping {
  /** Samples for the cue; one is picked at random per play. Empty: procedural. */
  samples: SampleRef[];
  /** Linear gain, 0..2. */
  gain: number;
}

export interface SoundMapping {
  version: 1;
  cues: Record<Cue, CueMapping>;
  /** Engine playback rate at standstill and at `topSpeed` (blocks/tick). */
  engine: { idleRate: number; topRate: number; topSpeed: number };
}

export const STORE_KEY = "gta2.sound.v1";

export function emptyMapping(): SoundMapping {
  const cues = {} as Record<Cue, CueMapping>;
  for (const c of CUES) cues[c] = { samples: [], gain: 1 };
  return { version: 1, cues, engine: { idleRate: 0.6, topRate: 2.0, topSpeed: 0.42 } };
}

const num = (v: unknown, lo: number, hi: number, d: number): number => (typeof v === "number" && Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : d);

/** Accepts any JSON; keeps what is valid and drops the rest. */
export function normalizeMapping(input: unknown): SoundMapping {
  const out = emptyMapping();
  if (!input || typeof input !== "object") return out;
  const o = input as Record<string, unknown>;
  const cues = (o.cues ?? {}) as Record<string, unknown>;
  for (const c of CUES) {
    const m = cues[c] as Record<string, unknown> | undefined;
    if (!m || typeof m !== "object") continue;
    const samples = Array.isArray(m.samples) ? m.samples : [];
    for (const s of samples) {
      const r = s as Record<string, unknown>;
      if ((r.bank === "map" || r.bank === "fstyle") && Number.isInteger(r.index) && (r.index as number) >= 0) {
        const ref: SampleRef = { bank: r.bank, index: r.index as number };
        if (r.format === "s16" || r.format === "u8") ref.format = r.format;
        out.cues[c].samples.push(ref);
      }
    }
    out.cues[c].gain = num(m.gain, 0, 2, 1);
  }
  const e = (o.engine ?? {}) as Record<string, unknown>;
  out.engine = { idleRate: num(e.idleRate, 0.1, 4, out.engine.idleRate), topRate: num(e.topRate, 0.1, 6, out.engine.topRate), topSpeed: num(e.topSpeed, 0.01, 4, out.engine.topSpeed) };
  return out;
}

export function loadMapping(storage: Pick<Storage, "getItem"> | null = safeStorage()): SoundMapping {
  try {
    const s = storage?.getItem(STORE_KEY);
    return s ? normalizeMapping(JSON.parse(s)) : emptyMapping();
  } catch {
    return emptyMapping();
  }
}

export function saveMapping(m: SoundMapping, storage: Pick<Storage, "setItem"> | null = safeStorage()): void {
  try {
    storage?.setItem(STORE_KEY, JSON.stringify(m));
  } catch {
    /* private mode: lasts for this visit */
  }
}

export const mappingJson = (m: SoundMapping): string => `${JSON.stringify(m, null, 2)}\n`;

export const sameRef = (a: SampleRef, b: SampleRef): boolean => a.bank === b.bank && a.index === b.index;

/** Playback rate for the engine loop at a speed in blocks per tick. */
export function engineRate(m: SoundMapping, speed: number): number {
  const t = Math.min(1, Math.abs(speed) / m.engine.topSpeed);
  return m.engine.idleRate + (m.engine.topRate - m.engine.idleRate) * t;
}

function safeStorage(): Storage | null {
  try {
    return typeof localStorage === "undefined" ? null : localStorage;
  } catch {
    return null;
  }
}
