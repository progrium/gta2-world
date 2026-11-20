// Short synthesized stand-ins for every cue, so the game has sound before the
// player maps samples from their own banks. Pure: each returns mono PCM at
// RATE, deterministic (seeded noise), so it can be tested without WebAudio.

import type { Cue } from "./cues.ts";

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

const BUILD: Record<Cue, () => Float32Array> = {
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
export function procedural(cue: Cue): Float32Array {
  let b = cache.get(cue);
  if (!b) cache.set(cue, (b = BUILD[cue]()));
  return b;
}
