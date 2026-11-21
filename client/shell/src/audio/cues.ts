// The game sounds (cues), grouped for the sound board, and the player's mapping from each one to
// samples in their own sound banks. The mapping is made by ear on the sound
// board, kept in localStorage and exported as JSON.

export type CueGroup = "Weapons" | "Hits and deaths" | "On foot" | "Vehicles" | "Pickups" | "Announcer" | "Player and missions" | "Not in the game yet";

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
const NY = "Not in the game yet";
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
  // On foot: a step every stride while a player walks or runs, by the ground.
  footstep: { label: "Footstep (road, pavement, floors)", group: "On foot" },
  footstep_grass: { label: "Footstep on grass", group: "On foot", fallback: "footstep" },
  footstep_water: { label: "Footstep in water", group: "On foot", fallback: "splash" },
  // Vehicles: an engine loop for every car nearby that is driven or moving.
  engine: { label: "Engine loop (pitch follows speed)", group: "Vehicles" },
  horn: { label: "Horn", group: "Vehicles" },
  car_door: { label: "Car door (get in or out)", group: "Vehicles" },
  car_crash: { label: "Car crash (hard)", group: "Vehicles" },
  car_bump: { label: "Car bump (light)", group: "Vehicles", fallback: "car_crash" },
  tyre_screech: { label: "Tyre screech (hard turn at speed)", group: "Vehicles" },
  siren: { label: "Siren", group: "Vehicles" },
  // Pickups: the pickup sound, then the announcer names what it was.
  pickup: { label: "Weapon pickup", group: "Pickups" },
  pickup_health: { label: "Health pickup", group: "Pickups", fallback: "pickup" },
  pickup_armour: { label: "Armour pickup", group: "Pickups", fallback: "pickup" },
  pickup_powerup: { label: "Power-up pickup", group: "Pickups", fallback: "pickup" },
  // Announcer: spoken lines played over the pickup sound, and when you frag someone.
  say_pistol: { label: "“Pistol!”", group: "Announcer" },
  say_machine_gun: { label: "“Machine gun!”", group: "Announcer" },
  say_shotgun: { label: "“Shotgun!”", group: "Announcer" },
  say_rocket_launcher: { label: "“Rocket launcher!”", group: "Announcer" },
  say_dual_pistol: { label: "“Dual pistol!”", group: "Announcer" },
  say_silenced_mg: { label: "“Silenced machine gun!”", group: "Announcer" },
  say_flamethrower: { label: "“Flamethrower!”", group: "Announcer" },
  say_electro_gun: { label: "“Electro gun!”", group: "Announcer" },
  say_grenades: { label: "“Grenades!”", group: "Announcer" },
  say_molotovs: { label: "“Molotov cocktails!”", group: "Announcer" },
  say_health: { label: "“Health!”", group: "Announcer" },
  say_armour: { label: "“Armour!”", group: "Announcer" },
  say_invulnerability: { label: "“Invulnerability!”", group: "Announcer" },
  say_double_damage: { label: "“Double damage!”", group: "Announcer" },
  say_fast_reload: { label: "“Fast reload!”", group: "Announcer" },
  frag_taunt: { label: "Taunt when you kill a player", group: "Announcer" },
  // Player and missions
  wanted_up: { label: "Wanted level up", group: "Player and missions" },
  wanted_down: { label: "Wanted level down", group: "Player and missions" },
  wasted: { label: "Wasted (you die)", group: "Player and missions", fallback: "ped_death" },
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
  // Not in the game yet: world and pedestrian sounds
  punch: { label: "Punch", group: NY },
  glass_break: { label: "Glass breaking", group: NY },
  splash: { label: "Splash (into water)", group: NY },
  car_alarm: { label: "Car alarm", group: NY },
  car_fire: { label: "Car on fire", group: NY },
  train: { label: "Train", group: NY },
  crowd: { label: "Crowd", group: NY },
  dog_bark: { label: "Dog bark", group: NY },
  ped_chatter: { label: "Pedestrian chatter (“Hey”, “Huh?”)", group: NY },
  ped_bumped: { label: "Pedestrian bumped (“Watch it, buddy!”)", group: NY },
  ped_panic: { label: "Pedestrian panic (“He's got a gun!”, “Help!”)", group: NY },
  ped_taxi: { label: "Pedestrian hailing a taxi", group: NY },
  mugger: { label: "Mugger (“Give me your wallet”)", group: NY },
  driver_angry: { label: "Angry driver (“Asshole!”, “Maniac”)", group: NY },
  carjacked: { label: "Carjacked driver (“Get out of my car!”)", group: NY },
  cop_shout: { label: "Cop shout (“Freeze!”, “Hold it!”)", group: NY },
  police_radio: { label: "Police radio", group: NY },
  gang_shout: { label: "Gang member shout", group: NY },
  laugh: { label: "Laughter", group: NY },
  elvis: { label: "Elvis (“Hey man, it's the king!”)", group: NY },
  // Not in the game yet: announcer
  say_kill_frenzy: { label: "“Kill frenzy!”", group: NY },
  frenzy_passed: { label: "Kill frenzy passed", group: NY, fallback: "mission_pass" },
  frenzy_failed: { label: "Kill frenzy failed", group: NY, fallback: "mission_fail" },
  kill_count: { label: "Kill count (“Thirty people down!”)", group: NY },
  say_multiplier: { label: "Multiplier up", group: NY },
  say_extra_life: { label: "Extra life", group: NY },
  say_jail_card: { label: "“Get out of jail free card!”", group: NY },
  say_respect: { label: "Respect", group: NY },
  say_instant_gang: { label: "Instant gang", group: NY },
  say_invisibility: { label: "“Invisibility!”", group: NY },
  say_vehicle_weapon: { label: "Vehicle weapon (“Vehicle bomb”, “Oil slick!”)", group: NY },
  time_out: { label: "“Time's up!”", group: NY },
  time_extended: { label: "Time extended", group: NY },
  race_start: { label: "Race on", group: NY },
  race_lap: { label: "“Second lap!” / “Final lap!”", group: NY },
  race_over: { label: "“Race over!”", group: NY },
} as const satisfies Record<string, CueInfo>;

export type Cue = keyof typeof INFO;
export const CUE_INFO: Record<Cue, CueInfo> = INFO;
export const CUES = Object.keys(INFO) as Cue[];
export const CUE_LABELS = Object.fromEntries(CUES.map((c) => [c, INFO[c].label])) as Record<Cue, string>;
export const CUE_GROUPS: CueGroup[] = [...new Set(CUES.map((c) => INFO[c].group))];

/**
 * Spoken cues: with nothing mapped they stay silent rather than play a
 * built-in stand-in, which would only be noise where a voice belongs.
 */
export const SPOKEN: ReadonlySet<Cue> = new Set(
  CUES.filter((c) => c.startsWith("say_") || ["frag_taunt", "kill_count", "time_out", "time_extended", "race_start", "race_lap", "race_over", "ped_chatter", "ped_bumped", "ped_panic", "ped_taxi", "mugger", "driver_angry", "carjacked", "cop_shout", "police_radio", "gang_shout", "laugh", "elvis", "crowd", "dog_bark"].includes(c)),
);

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
  bank: "map" | "fstyle" | "vocals";
  /** Position in the bank. For "vocals" it is ignored and `name` is used. */
  index: number;
  /** "vocals" only: the line's file name without .wav, e.g. "wasted". */
  name?: string;
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
 * The shipped mapping. It names samples only: a number in the shared map-bank
 * layout, or a spoken line's file name (data/audio/Vocals/<name>.wav); the
 * sounds are whatever the player's own files hold. Picked by ear on the sound
 * board, then checked against a listened-to description of every sample.
 */
const DEFAULT_SAMPLES: Partial<Record<Cue, (number | string)[]>> = {
  pistol: [312, 311],
  machine_gun: [53, 43],
  silenced_mg: [55],
  shotgun: [314, 315],
  rocket_launch: [29],
  flamethrower: [318],
  electro_gun: [313, 9],
  weapon_switch: [56],
  bullet_hit: [194, 195, 196, 197],
  explosion: [186, 187, 188, 68],
  ped_hurt: [269, 228, 232, 233, 236, 238],
  ped_death: [229, 230, 231, 234, 235, 237],
  engine: [4],
  horn: [17],
  car_door: [25, 27, 26, 28],
  car_crash: [37, 38, 39, 40, 33],
  siren: [14, 147],
  pickup: [319],
  say_pistol: ["pistolp"],
  say_machine_gun: ["macgun"],
  say_shotgun: ["shotgun"],
  say_rocket_launcher: ["rocketl"],
  say_dual_pistol: ["dualpist"],
  say_silenced_mg: ["silentmg"],
  say_flamethrower: ["flamet"],
  say_electro_gun: ["electro", "electrofingers"],
  say_grenades: ["grenades"],
  say_molotovs: ["molotovs"],
  say_health: ["health"],
  say_armour: ["armour"],
  say_invulnerability: ["invulnerability"],
  say_double_damage: ["doubledamage"],
  say_fast_reload: ["fastreload"],
  frag_taunt: ["youretoastbuddy", "thatsgottahurt", "oohdidthathurt", "sorrydidthathurt", "toasted", "eatleaddeath", "crispycritter", "suckitandsee", "sorryaboutthat", "shocking"],
  wasted: ["wasted"],
  busted: ["busted"],
  phone_ring: [30],
  mission_pass: ["jobcomplete"],
  mission_fail: ["jobfail"],
  game_over: ["gameover"],
  footstep: [198, 200, 206, 208],
  punch: [45, 59],
  glass_break: [66, 67],
  car_fire: [189, 190],
  train: [36],
  crowd: [0, 22, 161, 174],
  dog_bark: [49],
  ped_chatter: [216, 218, 219, 268, 272, 275, 276, 303, 305],
  ped_bumped: [210, 211, 212, 213, 214, 215],
  ped_panic: [221, 222, 223, 224, 225, 226, 245, 246, 247, 248, 249],
  ped_taxi: [239, 241, 242, 243, 244],
  mugger: [251, 252, 253, 255, 256],
  driver_angry: [257, 259, 261, 262, 263, 264, 266, 267, 280, 281],
  carjacked: [277, 278, 279, 283, 284],
  cop_shout: [285, 286, 288, 289, 291, 292, 293, 294, 296, 298, "freeze"],
  police_radio: [71, 72, 90, 98, 111, 119],
  gang_shout: [154, 155, 156, 164],
  laugh: [157, 158, 159, 160, 182, "laugh3", "laugh5", "laughb", "laughc"],
  elvis: [299, 300, 301, 302, "elvis"],
  say_kill_frenzy: ["killfrenzy"],
  frenzy_passed: ["frenzypassed"],
  frenzy_failed: ["frenzyfail"],
  kill_count: ["30peopledown", "60peopledown", "90peopledown", "120peopledown", "150peopledown"],
  say_multiplier: ["multiplyer"],
  say_extra_life: ["life"],
  say_jail_card: ["getoutjail"],
  say_respect: ["respect", "respectis"],
  say_instant_gang: ["instantgang"],
  say_invisibility: ["invisibility"],
  say_vehicle_weapon: ["vehbomb", "vehbomb2", "vehmacgun", "vehmines", "oilslick", "bombarmed"],
  time_out: ["timesup", "timeout"],
  time_extended: ["timeextended"],
  race_start: ["raceon"],
  race_lap: ["2ndlap", "finallap"],
  race_over: ["raceover"],
};

/**
 * Default gains other than 1. A light car bump borrows the crash samples
 * (nothing in the banks sounds like a bump), so it plays them quieter. No
 * sample sounds like a tyre screech either, so that cue uses its built-in sound.
 */
const DEFAULT_GAIN: Partial<Record<Cue, number>> = { car_bump: 0.45, footstep: 0.5, footstep_grass: 0.35, footstep_water: 0.5 };

export function defaultMapping(): SoundMapping {
  const m = emptyMapping();
  for (const [c, g] of Object.entries(DEFAULT_GAIN)) m.cues[c as Cue].gain = g;
  for (const c of CUES)
    m.cues[c].samples = (DEFAULT_SAMPLES[c] ?? []).map((x): SampleRef => (typeof x === "string" ? { bank: "vocals", index: 0, name: x } : { bank: "map", index: x }));
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
      if (r.bank === "vocals" && typeof r.name === "string" && r.name) {
        out.cues[c].samples.push({ bank: "vocals", index: 0, name: r.name.toLowerCase() });
      } else if ((r.bank === "map" || r.bank === "fstyle") && Number.isInteger(r.index) && (r.index as number) >= 0) {
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

/**
 * Picks that once shipped as the default and turned out wrong. A saved mapping
 * still holding exactly one of these gets today's default for that cue, so a
 * player who never changed it isn't stuck with the mistake.
 */
const RETIRED: Partial<Record<Cue, number[][]>> = {
  car_bump: [[44]],
  tyre_screech: [[24], [146]],
  // Soft noise that didn't read as an engine; #4 is the idling chug.
  engine: [[3]],
};

function retire(m: SoundMapping): SoundMapping {
  const d = defaultMapping();
  for (const [c, olds] of Object.entries(RETIRED) as [Cue, number[][]][]) {
    const cur = m.cues[c].samples;
    if (olds.some((o) => o.length === cur.length && cur.every((r, i) => r.bank === "map" && r.index === o[i]))) m.cues[c] = d.cues[c];
  }
  return m;
}

export function loadMapping(storage: Pick<Storage, "getItem"> | null = safeStorage()): SoundMapping {
  try {
    const s = storage?.getItem(STORE_KEY);
    return s ? retire(normalizeMapping(JSON.parse(s))) : defaultMapping();
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

export const sameRef = (a: SampleRef, b: SampleRef): boolean => a.bank === b.bank && (a.bank === "vocals" ? a.name === b.name : a.index === b.index);

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
