// The game sounds (cues), grouped for the sound board, and the player's mapping
// samples in their own sound banks. The mapping is made by ear on the sound
// board, kept in localStorage and exported as JSON.

export type CueGroup = "Weapons" | "Hits and deaths" | "Vehicles" | "Pickups" | "Player and missions" | "Not in the game yet";

export interface CueInfo {
  label: string;
  group: CueGroup;
  /**
   * While this cue has no samples of its own it borrows this cue's (and, with
   * no procedural sound of its own, that cue's built-in sound too).
   */
  fallback?: string;
}

// Order is the board's order. Cues in "Not in the game yet" can be mapped now;
// nothing plays them until the game has the event.
const INFO = {
  // Weapons: one per weapon id, then the weapon change.
  pistol: { label: "Pistol shot", group: "Weapons" },
  dual_pistol: { label: "Dual pistol shot", group: "Weapons", fallback: "pistol" },
  machine_gun: { label: "Machine gun shot", group: "Weapons" },
  silenced_mg: { label: "Silenced machine gun shot", group: "Weapons", fallback: "machine_gun" },
  shotgun: { label: "Shotgun shot", group: "Weapons" },
  rocket_launch: { label: "Rocket launch", group: "Weapons" },
  flamethrower: { label: "Flamethrower", group: "Weapons" },
  electro_gun: { label: "Electro gun", group: "Weapons" },
  grenade_throw: { label: "Grenade throw", group: "Weapons", fallback: "throw" },
  molotov_throw: { label: "Molotov throw", group: "Weapons", fallback: "throw" },
  throw: { label: "Throw (any)", group: "Weapons" },
  weapon_switch: { label: "Weapon switch", group: "Weapons" },
  // Hits and deaths
  bullet_hit: { label: "Bullet hit", group: "Hits and deaths" },
  explosion: { label: "Explosion", group: "Hits and deaths" },
  ped_hurt: { label: "Pedestrian hurt", group: "Hits and deaths" },
  ped_death: { label: "Pedestrian death", group: "Hits and deaths" },
  wasted: { label: "Wasted (you die)", group: "Hits and deaths", fallback: "ped_death" },
  // Vehicles
  engine: { label: "Engine loop (pitch follows speed)", group: "Vehicles" },
  horn: { label: "Horn", group: "Vehicles" },
  car_door: { label: "Car door (get in or out)", group: "Vehicles" },
  car_crash: { label: "Car crash (hard)", group: "Vehicles" },
  car_bump: { label: "Car bump (light)", group: "Vehicles", fallback: "car_crash" },
  tyre_screech: { label: "Tyre screech (hard turn at speed)", group: "Vehicles" },
  siren: { label: "Siren", group: "Vehicles" },
  // Pickups
  pickup: { label: "Weapon pickup", group: "Pickups" },
  pickup_health: { label: "Health pickup", group: "Pickups", fallback: "pickup" },
  pickup_armour: { label: "Armour pickup", group: "Pickups", fallback: "pickup" },
  pickup_powerup: { label: "Power-up pickup", group: "Pickups", fallback: "pickup" },
  // Player and missions
  wanted_up: { label: "Wanted level up", group: "Player and missions" },
  wanted_down: { label: "Wanted level down", group: "Player and missions" },
  busted: { label: "Busted", group: "Player and missions" },
  phone_ring: { label: "Phone ringing", group: "Player and missions" },
  pager: { label: "Pager (mission brief)", group: "Player and missions" },
  mission_start: { label: "Job started", group: "Player and missions", fallback: "pager" },
  mission_pass: { label: "Job passed", group: "Player and missions" },
  mission_fail: { label: "Job failed", group: "Player and missions" },
  game_over: { label: "Game over", group: "Player and missions", fallback: "mission_fail" },
  level_complete: { label: "Level complete", group: "Player and missions", fallback: "mission_pass" },
  round_end: { label: "Round over (multiplayer)", group: "Player and missions", fallback: "mission_pass" },
  player_joined: { label: "Player joined (multiplayer)", group: "Player and missions", fallback: "pager" },
  // Not in the game yet
  footstep: { label: "Footstep", group: "Not in the game yet" },
  punch: { label: "Punch", group: "Not in the game yet" },
  glass_break: { label: "Glass breaking", group: "Not in the game yet" },
  splash: { label: "Splash (into water)", group: "Not in the game yet" },
  car_alarm: { label: "Car alarm", group: "Not in the game yet" },
  car_fire: { label: "Car on fire", group: "Not in the game yet" },
  ped_chatter: { label: "Pedestrian chatter", group: "Not in the game yet" },
  cop_shout: { label: "Cop shout", group: "Not in the game yet" },
  gang_shout: { label: "Gang member shout", group: "Not in the game yet" },
  train: { label: "Train", group: "Not in the game yet" },
} as const satisfies Record<string, CueInfo>;

export type Cue = keyof typeof INFO;
export const CUE_INFO: Record<Cue, CueInfo> = INFO;
export const CUES = Object.keys(INFO) as Cue[];
export const CUE_LABELS = Object.fromEntries(CUES.map((c) => [c, INFO[c].label])) as Record<Cue, string>;
export const CUE_GROUPS: CueGroup[] = [...new Set(CUES.map((c) => INFO[c].group))];

/** The cue itself, then the cues it borrows from, nearest first. */
export function fallbackChain(c: Cue): Cue[] {
  const out: Cue[] = [c];
  let f = CUE_INFO[c].fallback as Cue | undefined;
  while (f && !out.includes(f)) {
    out.push(f);
    f = CUE_INFO[f].fallback as Cue | undefined;
  }
  return out;
}

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

/**
 * The shipped mapping: sample numbers in the shared map-bank layout, picked by
 * ear on the sound board. It names samples by index only; the sounds are
 * whatever the player's own banks hold. Cues added after it was made start
 * from a first guess by waveform shape (marked below) until someone listens.
 */
const DEFAULT_SAMPLES: Partial<Record<Cue, number[]>> = {
  pistol: [312],
  machine_gun: [26, 28],
  shotgun: [314],
  rocket_launch: [29],
  explosion: [186, 187, 188],
  bullet_hit: [194, 195, 196, 197],
  ped_hurt: [216, 217, 218, 219, 285, 286, 287],
  ped_death: [229, 230, 231, 234, 235, 237],
  car_crash: [37, 38, 39, 40],
  car_door: [25, 27, 26],
  pickup: [319],
  weapon_switch: [56],
  horn: [17],
  engine: [3],
  // First guesses, not yet heard:
  flamethrower: [58],
  electro_gun: [310],
  tyre_screech: [24],
  siren: [14],
  phone_ring: [23],
  footstep: [198, 199, 200, 201],
  punch: [206, 207],
  glass_break: [202, 203, 204, 205],
  car_alarm: [30],
  ped_chatter: [210, 211, 212, 213],
};

export function defaultMapping(): SoundMapping {
  const m = emptyMapping();
  for (const c of CUES) m.cues[c].samples = (DEFAULT_SAMPLES[c] ?? []).map((index) => ({ bank: "map", index }));
  return m;
}

/**
 * Accepts any JSON; keeps what is valid and drops the rest. A cue the input
 * doesn't mention (one added since it was saved) keeps `base`'s entry.
 */
export function normalizeMapping(input: unknown, base: SoundMapping = defaultMapping()): SoundMapping {
  const out = base;
  if (!input || typeof input !== "object") return out;
  const o = input as Record<string, unknown>;
  const cues = (o.cues ?? {}) as Record<string, unknown>;
  for (const c of CUES) {
    const m = cues[c] as Record<string, unknown> | undefined;
    if (!m || typeof m !== "object") continue;
    out.cues[c] = { samples: [], gain: 1 };
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
    return s ? normalizeMapping(JSON.parse(s)) : defaultMapping();
  } catch {
    return defaultMapping();
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
