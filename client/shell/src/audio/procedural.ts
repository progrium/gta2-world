// Short synthesized stand-ins for every cue, so the game has sound before the
// player maps samples from their own banks. Pure: each returns mono PCM at
// RATE, deterministic (seeded noise), so it can be tested without WebAudio.

import { type Cue, SPOKEN, fallbackChain } from "./cues.ts";

export const RATE = 22050;

function rng(seed: number): () => number {
  let s = seed >>> 0 || 1;
  return () => {
    s ^= s << 13;
    s ^= s >>> 17;
    s ^= s << 5;
    return ((s >>> 0) / 0xffffffff) * 2 - 1;
  };
}

type Env = (t: number) => number;
const decay = (k: number): Env => (t) => Math.exp(-t * k);
const attackDecay = (a: number, k: number): Env => (t) => (t < a ? t / a : Math.exp(-(t - a) * k));

/** One-pole low-pass over a buffer, cutoff in Hz (may vary over time). */
function lowpass(x: Float32Array, cutoff: (t: number) => number): Float32Array {
  let y = 0;
  for (let i = 0; i < x.length; i++) {
    const a = 1 - Math.exp((-2 * Math.PI * cutoff(i / RATE)) / RATE);
    y += a * (x[i]! - y);
    x[i] = y;
  }
  return x;
}

function noise(seconds: number, seed: number, env: Env): Float32Array {
  const r = rng(seed);
  const n = Math.round(seconds * RATE);
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) out[i] = r() * env(i / RATE);
  return out;
}

/** Sine sweep from f0 to f1 Hz with an envelope. */
function tone(seconds: number, f0: number, f1: number, env: Env, shape: "sine" | "square" | "saw" = "sine"): Float32Array {
  const n = Math.round(seconds * RATE);
  const out = new Float32Array(n);
  let ph = 0;
  for (let i = 0; i < n; i++) {
    const t = i / RATE;
    const f = f0 + (f1 - f0) * (t / seconds);
    ph += f / RATE;
    const p = ph - Math.floor(ph);
    const v = shape === "sine" ? Math.sin(2 * Math.PI * p) : shape === "square" ? (p < 0.5 ? 1 : -1) : 2 * p - 1;
    out[i] = v * env(t);
  }
  return out;
}

function mix(...parts: [Float32Array, number][]): Float32Array {
  const n = Math.max(...parts.map(([p]) => p.length));
  const out = new Float32Array(n);
  for (const [p, g] of parts) for (let i = 0; i < p.length; i++) out[i]! += p[i]! * g;
  return out;
}

function normalize(x: Float32Array, peak = 0.9): Float32Array {
  let m = 0;
  for (const v of x) m = Math.max(m, Math.abs(v));
  if (m > 0) for (let i = 0; i < x.length; i++) x[i]! *= peak / m;
  return x;
}

const gunshot = (len: number, k: number, cut: number, seed: number, body: number): Float32Array =>
  normalize(mix([lowpass(noise(len, seed, decay(k)), (t) => cut * Math.exp(-t * 8) + 300), 1], [tone(len * 0.6, body, body * 0.4, decay(k * 1.5)), 0.6]));

const seq = (...parts: Float32Array[]): Float32Array => {
  const out = new Float32Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
};
const gate = (len: number, edge = 0.01): Env => (t) => Math.min(1, t / edge, Math.max(0, (len - t) / edge));
const beep = (len: number, f: number, shape: "sine" | "square" | "saw" = "sine"): Float32Array => tone(len, f, f, gate(len), shape);
const rest = (len: number): Float32Array => new Float32Array(Math.round(len * RATE));

/** A tone whose pitch swings around `f` by ±`depth` Hz, `rate` times a second. */
function wail(len: number, f: number, depth: number, rate: number): Float32Array {
  const n = Math.round(len * RATE);
  const out = new Float32Array(n);
  const env = gate(len, 0.05);
  let ph = 0;
  for (let i = 0; i < n; i++) {
    const t = i / RATE;
    ph += (f + depth * Math.sin(2 * Math.PI * rate * t)) / RATE;
    out[i] = Math.sin(2 * Math.PI * ph) * env(t);
  }
  return out;
}

/** Cues without an entry use the first cue in their fallback chain that has one. */
const BUILD: Partial<Record<Cue, () => Float32Array>> = {
  flamethrower: () => normalize(lowpass(noise(0.35, 22, gate(0.35, 0.05)), (t) => 1800 + 600 * Math.sin(t * 40))),
  electro_gun: () => normalize(mix([tone(0.25, 140, 120, decay(8), "square"), 0.6], [lowpass(noise(0.25, 23, decay(8)), () => 6000), 0.7]), 0.7),
  throw: () => normalize(lowpass(noise(0.25, 24, (t) => Math.sin((Math.PI * t) / 0.25)), (t) => 600 + 4000 * t)),
  tyre_screech: () => normalize(tone(0.6, 1500, 1300, gate(0.6, 0.06), "saw").map((v, i) => v * (0.7 + 0.3 * Math.sin(i * 0.013))), 0.5),
  siren: () => normalize(wail(1.2, 700, 250, 1.5), 0.6),
  wanted_up: () => normalize(seq(beep(0.08, 660, "square"), beep(0.12, 990, "square")), 0.5),
  wanted_down: () => normalize(seq(beep(0.08, 990, "square"), beep(0.12, 660, "square")), 0.5),
  busted: () => normalize(seq(beep(0.15, 523, "square"), rest(0.03), beep(0.15, 392, "square"), rest(0.03), beep(0.3, 262, "square")), 0.5),
  phone_ring: () => normalize(seq(mix([beep(0.4, 440), 1], [beep(0.4, 480), 1]), rest(0.2), mix([beep(0.4, 440), 1], [beep(0.4, 480), 1])), 0.6),
  pager: () => normalize(seq(beep(0.06, 2000, "square"), rest(0.05), beep(0.06, 2000, "square"), rest(0.05), beep(0.06, 2000, "square")), 0.4),
  mission_pass: () => normalize(seq(beep(0.1, 523), beep(0.1, 659), beep(0.1, 784), beep(0.3, 1047)), 0.6),
  mission_fail: () => normalize(seq(beep(0.18, 392, "saw"), beep(0.18, 370, "saw"), beep(0.4, 330, "saw")), 0.5),
  footstep: () => normalize(lowpass(noise(0.06, 25, decay(60)), () => 1200), 0.5),
  punch: () => normalize(mix([tone(0.12, 120, 60, decay(30)), 1], [lowpass(noise(0.1, 26, decay(40)), () => 1500), 0.7])),
  glass_break: () => normalize(mix([lowpass(noise(0.5, 27, decay(8)), () => 9000), 0.6], [tone(0.4, 3100, 3000, decay(10)), 0.3], [tone(0.3, 4700, 4600, decay(14)), 0.3])),
  splash: () => normalize(lowpass(noise(0.7, 28, attackDecay(0.02, 5)), (t) => 3000 * Math.exp(-t * 3) + 300)),
  car_alarm: () => normalize(seq(beep(0.25, 900, "square"), beep(0.25, 1300, "square"), beep(0.25, 900, "square"), beep(0.25, 1300, "square")), 0.5),
  car_fire: () => normalize(lowpass(noise(1, 29, gate(1, 0.1)), () => 700).map((v, i) => v * (0.6 + 0.4 * Math.sin(i * 0.0009) * Math.sin(i * 0.0037)))),
  train: () => normalize(seq(...[0, 1, 2].map(() => seq(lowpass(noise(0.08, 33, decay(30)), () => 1500), rest(0.07), lowpass(noise(0.08, 34, decay(30)), () => 1500), rest(0.3)))), 0.6),

  pistol: () => gunshot(0.25, 22, 6000, 11, 180),
  machine_gun: () => gunshot(0.1, 40, 7000, 12, 220),
  shotgun: () => gunshot(0.45, 11, 4000, 13, 120),
  rocket_launch: () =>
    normalize(mix([lowpass(noise(0.9, 14, attackDecay(0.05, 3)), (t) => 1500 + 2500 * t), 1], [tone(0.9, 90, 300, attackDecay(0.08, 3), "saw"), 0.25])),
  explosion: () => normalize(mix([lowpass(noise(1.6, 15, attackDecay(0.01, 2.6)), (t) => 2500 * Math.exp(-t * 2.5) + 120), 1], [tone(1.2, 70, 30, decay(3)), 0.7])),
  bullet_hit: () => normalize(mix([lowpass(noise(0.08, 16, decay(60)), () => 5000), 1], [tone(0.06, 2400, 1600, decay(70)), 0.3])),
  ped_hurt: () => normalize(tone(0.28, 520, 330, attackDecay(0.02, 9), "saw").map((v, i) => v * (1 + 0.3 * Math.sin((i / RATE) * 2 * Math.PI * 28)))),
  ped_death: () => normalize(tone(0.7, 460, 140, attackDecay(0.03, 4), "saw").map((v, i) => v * (1 + 0.4 * Math.sin((i / RATE) * 2 * Math.PI * 18)))),
  car_crash: () => normalize(mix([lowpass(noise(0.6, 17, decay(7)), (t) => 3000 * Math.exp(-t * 4) + 200), 1], [tone(0.3, 140, 60, decay(10), "square"), 0.35], [noise(0.6, 18, decay(14)), 0.25])),
  car_door: () => normalize(mix([tone(0.15, 110, 70, decay(28), "square"), 0.8], [lowpass(noise(0.12, 19, decay(40)), () => 1800), 1])),
  pickup: () => normalize(mix([tone(0.09, 880, 880, decay(18)), 1], [tone(0.25, 1320, 1320, (t) => (t < 0.08 ? 0 : Math.exp(-(t - 0.08) * 10))), 1])),
  weapon_switch: () => normalize(mix([tone(0.05, 1800, 1200, decay(80), "square"), 0.6], [lowpass(noise(0.05, 20, decay(90)), () => 4000), 1])),
  horn: () => normalize(mix([tone(0.6, 392, 392, (t) => (t < 0.55 ? 1 : (0.6 - t) / 0.05), "square"), 1], [tone(0.6, 494, 494, (t) => (t < 0.55 ? 1 : (0.6 - t) / 0.05), "square"), 1]), 0.6),
  engine: () => engineLoop(),
};

/** Exactly one period-aligned second so it loops without a click. */
function engineLoop(): Float32Array {
  const n = RATE;
  const out = new Float32Array(n);
  const r = rng(21);
  const f = 40; // whole cycles per second, so the loop seam is in phase
  for (let i = 0; i < n; i++) {
    const p = (i * f) / RATE;
    const ph = p - Math.floor(p);
    const pulse = Math.exp(-ph * 6);
    out[i] = (pulse - 0.3) * 0.8 + 0.25 * Math.sin(2 * Math.PI * p * 2) + r() * 0.05;
  }
  return normalize(lowpass(out, () => 900), 0.7);
}

const cache = new Map<Cue, Float32Array>();
/** The cue's built-in sound, or null for a spoken cue (see SPOKEN). */
export function procedural(cue: Cue): Float32Array | null {
  if (SPOKEN.has(cue)) return null;
  let b = cache.get(cue);
  if (!b) {
    const from = fallbackChain(cue).find((c) => BUILD[c]);
    if (!from) return null;
    b = from === cue ? BUILD[cue]!() : procedural(from)!;
    cache.set(cue, b);
  }
  return b;
}
