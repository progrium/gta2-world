// The game module (client/wasm, game.wasm): sim/ in WASM plus the map,
// style and render-list builders. This wrapper copies files in, hands the
// Zig buffers to the renderer and runs ticks. See client/wasm/src/game.zig.

import { CHUNK_BYTES, INSTANCE_BYTES, type MapMeshData, type StyleData, VERTEX_BYTES } from "../../../render/ts/src/index.ts";
import { FRAME_SIZE, type Frame, encodeFrame } from "../input/i2.ts";

type Exports = Record<string, (...a: number[]) => number> & { memory: WebAssembly.Memory };

export const MAX_PLAYERS = 16;

/** Exports the page relies on that older builds of game.wasm lack. */
const REQUIRED_EXPORTS = ["gameStep", "buildList", "playerInfo", "simEventsTake", "cuesTake", "effectExplosion"] as const;

export interface PlayerInfo {
  active: boolean;
  inCar: boolean;
  hp: number;
  /** Frags: kills, less one for each death by your own hand. */
  kills: number;
  deaths: number;
  respawnTimer: number;
  /** Blocks per tick. */
  speed: number;
  z: number;
  /** Weapon in hand, an index into `WEAPON_NAMES`. */
  weapon: number;
  /** Rounds for it; -1 never runs out. */
  rounds: number;
  /** Points, from the scoring notes. */
  score: number;
  /** Armour charges left. */
  armour: number;
  /** Power-up ticks left. */
  invulnerable: number;
  doubleDamage: number;
  fastReload: number;
  /** Throw charge while a grenade or molotov is wound up (ticks). */
  charge: number;
  burning: boolean;
}

/** A game event: offline from the sim, online from the server (I3 `event`). */
export interface GameEvent {
  kind: number;
  a: number;
  b: number;
  c: number;
  /** Blocks. */
  x: number;
  y: number;
  z: number;
}

/** Something the client saw for sound: 1 shot (a = weapon), 2 ped hurt, 3 car hit, 4 weapon change (a = weapon). */
export interface Cue {
  kind: number;
  a: number;
  x: number;
  y: number;
  z: number;
}

export const WEAPON_NAMES = [
  "Pistol",
  "Machine gun",
  "Shotgun",
  "Rocket launcher",
  "Dual pistols",
  "Silenced machine gun",
  "Flamethrower",
  "Electro gun",
  "Grenades",
  "Molotovs",
] as const;
/** Pickup kinds after the weapons (`tuning.pickup_health` on). */
export const PICKUP_NAMES = ["Health", "Armour", "Invulnerability", "Double damage", "Fast reload"] as const;

/** The single-player state the HUD draws (`spInfo` in game.zig). */
export interface SpHud {
  lives: number;
  multiplier: number;
  /** Points; in GTA2 cash and points are one number. */
  points: number;
  jailCards: number;
  /** Wanted stars, 0-6. */
  stars: number;
  wantedPoints: number;
  careerFlags: number;
  /** Wasted or busted and not yet back on the street. */
  out: boolean;
  /** Banner message text id (0 none) and ticks left. */
  banner: number;
  bannerTicks: number;
  /** Queued brief text ids, the showing one first. */
  briefs: number[];
  /** Countdown in ticks (0 none). */
  timer: number;
  counters: [number, number];
  /** Where the arrow points, in blocks, or null. */
  arrow: { x: number; y: number; entity: boolean } | null;
  hudFlags: number;
  tick: number;
}

export interface CameraTarget {
  x: number;
  y: number;
  z: number;
  angle: number;
  vx: number;
  vy: number;
  found: boolean;
}

export interface TuneEntry {
  index: number;
  name: string;
  /** fx: 16.16 fixed point; int: plain integer; shift: a right-shift count. */
  unit: "fx" | "int" | "shift";
  default: number;
}

export class GameModule {
  private w: Exports;

  private constructor(w: Exports) {
    this.w = w;
  }

  static async load(url: URL | string = new URL("./game.wasm", import.meta.url)): Promise<GameModule> {
    // no-cache revalidates, so a new page never runs against a cached old module.
    const res = await fetch(url, { cache: "no-cache" });
    if (!res.ok) throw new Error(`game.wasm: HTTP ${res.status}`);
    const { instance } = await WebAssembly.instantiate(await res.arrayBuffer(), {});
    const missing = REQUIRED_EXPORTS.filter((n) => typeof (instance.exports as Record<string, unknown>)[n] !== "function");
    if (missing.length) throw new Error(`game.wasm is from another version of the page (missing ${missing.join(", ")}). Reload the page; if that doesn't help, clear the site's cached data.`);
    return new GameModule(instance.exports as unknown as Exports);
  }

  private get buf(): ArrayBuffer {
    return this.w.memory.buffer;
  }
  private u8(p: number, n: number): Uint8Array {
    return new Uint8Array(this.buf, p, n);
  }
  private error(): string {
    return new TextDecoder().decode(this.u8(this.w.errorPtr!(), this.w.errorLen!()));
  }
  private withBytes(bytes: Uint8Array, f: (p: number, n: number) => number): void {
    const p = this.w.alloc!(bytes.length);
    if (!p) throw new Error("out of WASM memory");
    this.u8(p, bytes.length).set(bytes);
    const rc = f(p, bytes.length);
    this.w.free!(p, bytes.length);
    if (rc !== 0) throw new Error(this.error());
  }

  /** Parses a .sty and returns the buffers the renderer uploads (copies). */
  loadStyle(bytes: Uint8Array): StyleData {
    this.withBytes(bytes, (p, n) => this.w.loadStyle!(p, n));
    const w = this.w;
    const si = new Uint32Array(this.buf, w.styleInfo!(), 18).slice();
    return {
      tiles: this.u8(w.tilesPtr!(), w.tilesLen!()).slice(),
      spritePages: this.u8(w.spritePagesPtr!(), w.spritePagesLen!()).slice(),
      ppal: this.u8(w.ppalPtr!(), w.ppalLen!()).slice(),
      palx: new Uint16Array(this.buf, w.palxPtr!(), 16384).slice(),
      spriteTable: new Uint16Array(this.buf, w.spriteTablePtr!(), w.spriteTableRows!() * 64 * 4).slice(),
      tilePaletteBase: si[4]!,
      spritePaletteBase: si[5]!,
    };
  }

  /**
   * Car models from the loaded style's car info and a .gci's text (or none:
   * default handling). Call after loadStyle, before start. Returns the count.
   */
  loadCarInfo(gci: Uint8Array | null): number {
    if (!gci || gci.length === 0) {
      const n = this.w.loadCarInfo!(0, 0);
      if (n < 0) throw new Error(this.error());
      return n;
    }
    let n = 0;
    this.withBytes(gci, (p, len) => {
      n = this.w.loadCarInfo!(p, len);
      return n < 0 ? n : 0;
    });
    return n;
  }

  /** One default car model for every car (online, to match the server). */
  useDefaultCars(): void {
    this.w.useDefaultCars!();
  }

  /** Parses a .gmp: builds the collision grid for the sim and the map mesh. */
  loadMap(bytes: Uint8Array, bakeLights = true): MapMeshData & { triangles: number } {
    this.withBytes(bytes, (p, n) => this.w.loadMap!(p, n, bakeLights ? 1 : 0));
    const w = this.w;
    const mi = new Uint32Array(this.buf, w.meshInfo!(), 8);
    return {
      vertices: this.u8(w.vertexPtr!(), w.vertexCount!() * VERTEX_BYTES).slice(),
      chunks: this.u8(w.chunkPtr!(), w.chunkCount!() * CHUNK_BYTES).slice(),
      anims: new Uint16Array(this.buf, w.animPtr!(), w.animLen!()).slice(),
      triangles: mi[0]!,
    };
  }

  start(seed: number, hint?: { x: number; y: number }): void {
    const rc = this.w.gameStart!(seed >>> 0, hint ? 1 : 0, hint?.x ?? 0, hint?.y ?? 0);
    if (rc !== 0) throw new Error(this.error());
  }

  // -------------------------------------------------------- single player

  /** Whether this game.wasm has the single-player exports. */
  get hasSinglePlayer(): boolean {
    return typeof this.w.spStart === "function";
  }

  /** Starts a single-player game on the loaded map, with its level data and scripts. */
  startSp(seed: number, hint?: { x: number; y: number }): void {
    const rc = this.w.spStart!(seed >>> 0, hint ? 1 : 0, hint?.x ?? 0, hint?.y ?? 0);
    if (rc !== 0) throw new Error(this.error());
  }

  /** Forgets the level's script files. */
  clearScripts(): void {
    this.w.scriptsClear!();
  }

  /** Adds one of the level's script files (main .scr or a mission sub-script). */
  addScript(name: string, bytes: Uint8Array): void {
    const nm = new TextEncoder().encode(name.toLowerCase());
    const np = this.w.alloc!(Math.max(1, nm.length));
    if (!np) throw new Error("out of WASM memory");
    this.u8(np, nm.length).set(nm);
    try {
      this.withBytes(bytes, (p, n) => (this.w.scriptAdd!(np, nm.length, p, n) < 0 ? -1 : 0));
    } finally {
      this.w.free!(np, Math.max(1, nm.length));
    }
  }

  /** Loads a .gxt text table; returns its entry count. */
  loadText(bytes: Uint8Array): number {
    let n = 0;
    this.withBytes(bytes, (p, len) => {
      n = this.w.loadText!(p, len);
      return n < 0 ? n : 0;
    });
    return n;
  }

  private readText(len: number): string | null {
    if (len < 0) return null;
    const b = this.u8(this.w.textPtr!(), len * 2);
    let s = "";
    for (let i = 0; i < len; i++) s += String.fromCharCode(b[i * 2]! | (b[i * 2 + 1]! << 8));
    return s;
  }

  /** The text for a script message number, or null. */
  text(id: number): string | null {
    return this.readText(this.w.textById!(id >>> 0));
  }

  /** The text for a named key ("wasted", "nicked", ...), or null. */
  textKey(key: string): string | null {
    const k = new TextEncoder().encode(key);
    const p = this.w.alloc!(Math.max(1, k.length));
    if (!p) return null;
    this.u8(p, k.length).set(k);
    const len = this.w.textByKey!(p, k.length);
    const out = this.readText(len);
    this.w.free!(p, Math.max(1, k.length));
    return out;
  }

  spInfo(): SpHud {
    const a = new Int32Array(this.buf, this.w.spInfo!(), 24);
    const n = Math.max(0, Math.min(4, a[10]!));
    return {
      lives: a[0]!,
      multiplier: a[1]!,
      points: a[2]!,
      jailCards: a[3]!,
      stars: a[4]!,
      wantedPoints: a[5]!,
      careerFlags: a[6]!,
      out: a[7] !== 0,
      banner: a[8]! >>> 0,
      bannerTicks: a[9]!,
      briefs: Array.from(a.subarray(11, 11 + n), (x) => x >>> 0),
      timer: a[15]! >>> 0,
      counters: [a[16]!, a[17]!],
      arrow: a[18] ? { x: a[19]! / 65536, y: a[20]! / 65536, entity: a[18] === 1 } : null,
      hudFlags: a[21]!,
      tick: a[22]! >>> 0,
    };
  }

  /**
   * Offline debug: drives the HUD and career through the sim's APIs, as a
   * script would (see `spDebug` in game.zig). Does nothing until the
   * owning workstream fills in that API.
   */
  spDebug(op: number, a = 0, b = 0): boolean {
    return this.w.spDebug!(op, a | 0, b | 0) !== 0;
  }

  /** Drops a car in front of the player (offline play only). */
  spawnCar(slot = 0): boolean {
    return this.w.gameSpawnCar!(slot) !== 0;
  }

  /** Drops a pickup of `kind` in front of the player (offline play only). */
  spawnPickup(kind: number, slot = 0): boolean {
    return this.w.gameSpawnPickup!(slot, kind) !== 0;
  }

  join(slot: number): void {
    this.w.gameJoin!(slot);
  }
  leave(slot: number): void {
    this.w.gameLeave!(slot);
  }

  /** One sim tick with these frames (by slot; missing slots are neutral). */
  step(frames: readonly (Frame | null | undefined)[], seq: number): void {
    const view = new DataView(this.buf, this.w.framesPtr!(), MAX_PLAYERS * FRAME_SIZE);
    for (let i = 0; i < MAX_PLAYERS; i++) {
      const f = frames[i] ?? { steer: 0, throttle: 0, buttons: 0, aim: 0, seq: seq & 0xffff };
      encodeFrame(f, new DataView(this.buf, view.byteOffset + i * FRAME_SIZE, FRAME_SIZE));
    }
    this.w.gameStep!();
  }

  get tick(): number {
    return this.w.gameTick!() >>> 0;
  }

  hash(): string {
    const h = new Uint32Array(this.buf, this.w.gameHash!(), 2);
    return h[1]!.toString(16).padStart(8, "0") + h[0]!.toString(16).padStart(8, "0");
  }

  player(slot: number): PlayerInfo {
    const a = new Int32Array(this.buf, this.w.playerInfo!(slot), 17);
    return {
      active: a[0] !== 0,
      inCar: a[1] !== 0,
      hp: a[2]!,
      kills: a[3]!,
      deaths: a[4]!,
      respawnTimer: a[5]! >>> 0,
      speed: a[6]! / 65536,
      z: a[7]! / 65536,
      weapon: a[8]!,
      rounds: a[9]!,
      score: a[10]!,
      armour: a[11]!,
      invulnerable: a[12]!,
      doubleDamage: a[13]!,
      fastReload: a[14]!,
      charge: a[15]!,
      burning: a[16]! > 0,
    };
  }

  /** Offline game events since the last call. */
  takeEvents(): GameEvent[] {
    const n = this.w.simEventsTake!();
    const dv = new DataView(this.buf, this.w.simEventsPtr!(), n * 16);
    const out: GameEvent[] = [];
    for (let i = 0; i < n; i++) {
      const o = i * 16;
      out.push({ kind: dv.getUint8(o), a: dv.getUint8(o + 1), b: dv.getUint8(o + 2), c: dv.getUint8(o + 3), x: dv.getInt32(o + 4, true) / 65536, y: dv.getInt32(o + 8, true) / 65536, z: dv.getInt32(o + 12, true) / 65536 });
    }
    return out;
  }

  /** Sound cues the render pass saw since the last call. */
  takeCues(): Cue[] {
    const n = this.w.cuesTake!();
    const dv = new DataView(this.buf, this.w.cuesPtr!(), n * 24);
    const out: Cue[] = [];
    for (let i = 0; i < n; i++) {
      const o = i * 24;
      out.push({ kind: dv.getUint32(o, true), a: dv.getUint32(o + 4, true), x: dv.getFloat32(o + 8, true), y: dv.getFloat32(o + 12, true), z: dv.getFloat32(o + 16, true) });
    }
    return out;
  }

  /** Shows an explosion at (x, y, z) in blocks. */
  explosion(x: number, y: number, z: number, nowMs: number): void {
    this.w.effectExplosion!(Math.round(x * 65536), Math.round(y * 65536), Math.round(z * 65536), nowMs);
  }

  /** Render list at `alpha` between the last two ticks: bytes and count. */
  renderList(alpha: number, nowMs = performance.now()): { bytes: Uint8Array; count: number } {
    const count = this.w.buildList!(alpha, nowMs);
    return { bytes: this.u8(this.w.instancePtr!(), count * INSTANCE_BYTES), count };
  }

  camera(alpha: number, slot = 0): CameraTarget {
    const t = new Float32Array(this.buf, this.w.cameraTarget!(alpha, slot), 7);
    return { x: t[0]!, y: t[1]!, z: t[2]!, angle: t[3]!, vx: t[4]!, vy: t[5]!, found: t[6] !== 0 };
  }

  // -------------------------------------------------------------- online

  get layoutHash(): bigint {
    const h = new Uint32Array(this.buf, this.w.layoutHashPtr!(), 2);
    return (BigInt(h[1]!) << 32n) | BigInt(h[0]!);
  }

  /** Switches to online mode as `slot`; resets tuning to the defaults. */
  netStart(slot: number, bufferTicks: number): void {
    if (this.w.netStart!(slot, bufferTicks) !== 0) throw new Error(this.error());
  }
  netStop(): void {
    this.w.netStop!();
  }
  /** A snapshot datagram or baseline body (from its type byte). */
  netSnapshot(body: Uint8Array, nowMs: number): void {
    this.withBytes(body, (p, n) => this.w.netSnapshot!(p, n, nowMs));
  }
  /** Runs due predicted ticks with `frame` as the own input; returns ticks run. */
  netUpdate(nowMs: number, frame: Frame): number {
    encodeFrame(frame, new DataView(this.buf, this.w.framesPtr!(), FRAME_SIZE));
    return this.w.netUpdate!(nowMs);
  }
  /** The input datagram for the newest tick (copy), or null before the baseline. */
  netInput(nowMs: number): Uint8Array | null {
    const n = this.w.netInput!(nowMs);
    return n ? this.u8(this.w.netInputPtr!(), n).slice() : null;
  }
  netStats(): { started: boolean; rttMs: number; snapshots: number; replays: number; maxReplay: number; resyncs: number; hitches: number; inputAck: number } {
    const a = new Uint32Array(this.buf, this.w.netStats!(), 8);
    return { started: a[0] !== 0, rttMs: a[1]!, snapshots: a[2]!, replays: a[3]!, maxReplay: a[4]!, resyncs: a[5]!, hitches: a[6]!, inputAck: a[7]! };
  }

  // -------------------------------------------------------------- tuning

  private tuneDefaults: number[] | null = null;

  tuning(): TuneEntry[] {
    const names = new TextDecoder().decode(this.u8(this.w.tuneNamesPtr!(), this.w.tuneNamesLen!())).split(";");
    if (!this.tuneDefaults) {
      this.w.tuneReset!();
      this.tuneDefaults = names.map((_, i) => this.w.tuneGet!(i));
    }
    return names.map((s, i) => {
      const [name, unit] = s.split(":") as [string, TuneEntry["unit"]];
      return { index: i, name, unit, default: this.tuneDefaults![i]! };
    });
  }
  tuneGet(i: number): number {
    return this.w.tuneGet!(i);
  }
  tuneSet(i: number, raw: number): void {
    this.w.tuneSet!(i, raw | 0);
  }
  tuneReset(): void {
    this.w.tuneReset!();
  }
}
