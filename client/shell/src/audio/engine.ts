// WebAudio sound for the game screen. One master gain (volume and mute), one
// stereo panner and gain per voice placed relative to the listener (the
// camera), and one looping source per engine whose pitch follows car speed.
//
// The camera looks straight down, so a sound to the right of the listener
// pans right and distance in blocks sets the level; nothing is behind you.

import { type Cue, type SampleRef, type SoundMapping, engineRate, loadMapping, saveMapping } from "./cues.ts";
import { RATE as PROC_RATE, procedural } from "./procedural.ts";
import type { SampleFormat, SoundBank } from "./sdt.ts";

/** Full level inside this many blocks, then falling off. */
const NEAR = 3;
/** Silent beyond this many blocks. */
const FAR = 24;
/** Blocks to the side for a full pan. */
const PAN_SPAN = 10;
const MAX_VOICES = 32;
const MAX_PER_CUE = 6;
/** An engine not updated for this long is stopped (car left, out of view). */
const ENGINE_STALE_MS = 500;
const VOLUME_KEY = "gta2.sound.volume";
/** Lowest buffer rate every browser accepts; slower banks are upsampled. */
const MIN_RATE = 8000;

export type BankId = SampleRef["bank"];

interface Voice {
  cue: Cue | null;
  src: AudioBufferSourceNode;
  ended: boolean;
}

interface Engine {
  src: AudioBufferSourceNode;
  gain: GainNode;
  pan: StereoPannerNode;
  seen: number;
  key: string;
}

export interface Listener {
  x: number;
  y: number;
  z: number;
}

/** Level and pan for a sound at (x, y, z) heard from the listener. Pure. */
export function spatial(l: Listener, x: number, y: number, z: number): { gain: number; pan: number } {
  const dx = x - l.x;
  const dy = y - l.y;
  const dz = (z - l.z) * 0.5;
  const d = Math.hypot(dx, dy, dz);
  let gain = d <= NEAR ? 1 : d >= FAR ? 0 : NEAR / d;
  if (d > FAR * 0.75) gain *= (FAR - d) / (FAR * 0.25);
  const pan = Math.max(-1, Math.min(1, dx / PAN_SPAN));
  return { gain: Math.max(0, gain), pan };
}

/** Integer-factor linear upsample so a bank at 5500 Hz still makes a valid AudioBuffer. */
export function upsample(data: Float32Array, rate: number): { data: Float32Array; rate: number; factor: number } {
  if (rate >= MIN_RATE) return { data, rate, factor: 1 };
  const k = Math.ceil(MIN_RATE / rate);
  const out = new Float32Array(data.length * k);
  for (let i = 0; i < data.length; i++) {
    const a = data[i]!;
    const b = data[i + 1] ?? a;
    for (let j = 0; j < k; j++) out[i * k + j] = a + ((b - a) * j) / k;
  }
  return { data: out, rate: rate * k, factor: k };
}

export class AudioEngine {
  mapping: SoundMapping;
  banks: Partial<Record<BankId, SoundBank>> = {};
  /** Names of the files the banks came from, for the board. */
  bankNames: Partial<Record<BankId, string>> = {};
  private ctx: AudioContext | null = null;
  private master: GainNode | null = null;
  private listener: Listener = { x: 0, y: 0, z: 0 };
  private voices: Voice[] = [];
  private engines = new Map<number, Engine>();
  private buffers = new Map<string, { buf: AudioBuffer; loopStart: number }>();
  private previewVoice: AudioBufferSourceNode | null = null;
  private volume_ = 0.8;
  private muted_ = false;
  private listeners = new Set<() => void>();
  private unlockHandler: (() => void) | null = null;

  constructor() {
    this.mapping = loadMapping();
    try {
      const v = JSON.parse(localStorage.getItem(VOLUME_KEY) ?? "null") as { volume?: number; muted?: boolean } | null;
      if (v && typeof v.volume === "number") this.volume_ = Math.min(1, Math.max(0, v.volume));
      if (v && typeof v.muted === "boolean") this.muted_ = v.muted;
    } catch {
      /* defaults */
    }
  }

  // ---- lifecycle --------------------------------------------------------

  /** Browsers start audio suspended until a gesture; resume on the first one. */
  attach(target: EventTarget = window): void {
    if (this.unlockHandler) return;
    const h = (): void => {
      void this.resume();
    };
    this.unlockHandler = h;
    for (const ev of ["pointerdown", "keydown", "touchstart"]) target.addEventListener(ev, h, { capture: true });
  }

  async resume(): Promise<void> {
    const c = this.context();
    if (c && c.state === "suspended") {
      try {
        await c.resume();
      } catch {
        /* needs a gesture */
      }
    }
  }

  get running(): boolean {
    return this.ctx?.state === "running";
  }

  private context(): AudioContext | null {
    if (this.ctx) return this.ctx;
    const AC = (globalThis as { AudioContext?: typeof AudioContext; webkitAudioContext?: typeof AudioContext }).AudioContext ?? (globalThis as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!AC) return null;
    this.ctx = new AC({ latencyHint: "interactive" });
    this.master = this.ctx.createGain();
    this.master.gain.value = this.muted_ ? 0 : this.volume_;
    this.master.connect(this.ctx.destination);
    return this.ctx;
  }

  /** Stops every voice and engine; keeps the context for the next screen. */
  stopAll(): void {
    for (const v of this.voices) stop(v.src);
    this.voices = [];
    for (const id of [...this.engines.keys()]) this.stopEngine(id);
    this.stopPreview();
  }

  // ---- settings ---------------------------------------------------------

  get volume(): number {
    return this.volume_;
  }
  set volume(v: number) {
    this.volume_ = Math.min(1, Math.max(0, v));
    this.applyMaster();
  }
  get muted(): boolean {
    return this.muted_;
  }
  set muted(m: boolean) {
    this.muted_ = m;
    this.applyMaster();
  }
  toggleMute(): boolean {
    this.muted = !this.muted_;
    return this.muted_;
  }

  private applyMaster(): void {
    if (this.master && this.ctx) this.master.gain.setTargetAtTime(this.muted_ ? 0 : this.volume_, this.ctx.currentTime, 0.02);
    try {
      localStorage.setItem(VOLUME_KEY, JSON.stringify({ volume: this.volume_, muted: this.muted_ }));
    } catch {
      /* ignore */
    }
    this.emit();
  }

  setMapping(m: SoundMapping): void {
    this.mapping = m;
    saveMapping(m);
    // Engines pick up a new sample on their next update.
    for (const [id, e] of this.engines) if (e.key !== this.engineKey()) this.stopEngine(id);
    this.emit();
  }

  setBanks(banks: Partial<Record<BankId, SoundBank>>, names: Partial<Record<BankId, string>> = {}): void {
    this.banks = banks;
    this.bankNames = names;
    this.buffers.clear();
    for (const id of [...this.engines.keys()]) this.stopEngine(id);
    this.emit();
  }

  on(fn: () => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }
  private emit(): void {
    for (const f of this.listeners) f();
  }

  // ---- the game API -----------------------------------------------------

  setListener(x: number, y: number, z: number): void {
    this.listener = { x, y, z };
    this.reapEngines();
  }

  /** Plays a cue at a world position in blocks; without one it plays centred. */
  play(cue: Cue, x?: number, y?: number, z?: number): void {
    const c = this.context();
    if (!c || !this.master || c.state !== "running") return;
    const sp = x === undefined || y === undefined ? { gain: 1, pan: 0 } : spatial(this.listener, x, y, z ?? this.listener.z);
    if (sp.gain <= 0.01) return;
    const m = this.mapping.cues[cue];
    const b = this.bufferForCue(cue);
    if (!b) return;
    this.voices = this.voices.filter((v) => !v.ended);
    const same = this.voices.filter((v) => v.cue === cue);
    if (same.length >= MAX_PER_CUE) this.kill(same[0]!);
    if (this.voices.length >= MAX_VOICES) this.kill(this.voices[0]!);
    const src = c.createBufferSource();
    src.buffer = b.buf;
    src.playbackRate.value = 0.96 + Math.random() * 0.08;
    const g = c.createGain();
    g.gain.value = sp.gain * m.gain;
    const p = c.createStereoPanner();
    p.pan.value = sp.pan;
    src.connect(g).connect(p).connect(this.master);
    const v: Voice = { cue, src, ended: false };
    src.onended = () => {
      v.ended = true;
      src.disconnect();
      g.disconnect();
      p.disconnect();
    };
    this.voices.push(v);
    src.start();
  }

  /**
   * Keeps engine `id` (a car or player slot) running at `speed` blocks per
   * tick, optionally at a position (else at the listener). Call every tick
   * the car is driven; it stops by itself when the calls stop.
   */
  setEngine(id: number, speed: number, x?: number, y?: number, z?: number): void {
    const c = this.context();
    if (!c || !this.master || c.state !== "running") return;
    let e = this.engines.get(id);
    const key = this.engineKey();
    if (e && e.key !== key) {
      this.stopEngine(id);
      e = undefined;
    }
    const sp = x === undefined || y === undefined ? { gain: 1, pan: 0 } : spatial(this.listener, x, y, z ?? this.listener.z);
    if (!e) {
      const b = this.bufferForCue("engine");
      if (!b) return;
      const src = c.createBufferSource();
      src.buffer = b.buf;
      src.loop = true;
      src.loopStart = b.loopStart;
      src.loopEnd = b.buf.duration;
      const gain = c.createGain();
      gain.gain.value = 0;
      const pan = c.createStereoPanner();
      src.connect(gain).connect(pan).connect(this.master);
      src.start();
      e = { src, gain, pan, seen: 0, key };
      this.engines.set(id, e);
    }
    e.seen = performance.now();
    const t = c.currentTime;
    e.src.playbackRate.setTargetAtTime(engineRate(this.mapping, speed), t, 0.08);
    e.gain.gain.setTargetAtTime(sp.gain * this.mapping.cues.engine.gain * 0.6, t, 0.05);
    e.pan.pan.setTargetAtTime(sp.pan, t, 0.05);
  }

  stopEngine(id: number): void {
    const e = this.engines.get(id);
    if (!e) return;
    this.engines.delete(id);
    const c = this.ctx!;
    e.gain.gain.setTargetAtTime(0, c.currentTime, 0.04);
    e.src.stop(c.currentTime + 0.2);
    e.src.onended = () => {
      e.src.disconnect();
      e.gain.disconnect();
      e.pan.disconnect();
    };
  }

  private reapEngines(): void {
    const now = performance.now();
    for (const [id, e] of this.engines) if (now - e.seen > ENGINE_STALE_MS) this.stopEngine(id);
  }

  // ---- board helpers ----------------------------------------------------

  /** Plays one bank sample centred, replacing any preview. Returns its length in seconds. */
  async preview(ref: SampleRef): Promise<number> {
    await this.resume();
    const c = this.context();
    const b = this.bufferForRef(ref);
    if (!c || !this.master || !b) return 0;
    this.stopPreview();
    const src = c.createBufferSource();
    src.buffer = b.buf;
    src.connect(this.master);
    src.onended = () => src.disconnect();
    src.start();
    this.previewVoice = src;
    return b.buf.duration;
  }

  async previewCue(cue: Cue): Promise<void> {
    await this.resume();
    if (cue === "engine") return this.previewEngine();
    this.play(cue);
  }

  /** Two seconds of engine sweeping from idle to top speed. */
  private previewEngine(): void {
    const c = this.context();
    const b = this.bufferForCue("engine");
    if (!c || !this.master || !b) return;
    this.stopPreview();
    const src = c.createBufferSource();
    src.buffer = b.buf;
    src.loop = true;
    src.loopStart = b.loopStart;
    src.loopEnd = b.buf.duration;
    const g = c.createGain();
    g.gain.value = 0.6 * this.mapping.cues.engine.gain;
    const t = c.currentTime;
    src.playbackRate.setValueAtTime(engineRate(this.mapping, 0), t);
    src.playbackRate.linearRampToValueAtTime(engineRate(this.mapping, this.mapping.engine.topSpeed), t + 1.5);
    src.playbackRate.linearRampToValueAtTime(engineRate(this.mapping, 0), t + 2.5);
    g.gain.setValueAtTime(g.gain.value, t + 2.3);
    g.gain.linearRampToValueAtTime(0, t + 2.6);
    src.connect(g).connect(this.master);
    src.onended = () => {
      src.disconnect();
      g.disconnect();
    };
    src.start();
    src.stop(t + 2.7);
    this.previewVoice = src;
  }

  stopPreview(): void {
    if (this.previewVoice) stop(this.previewVoice);
    this.previewVoice = null;
  }

  // ---- buffers ----------------------------------------------------------

  private engineKey(): string {
    const s = this.mapping.cues.engine.samples[0];
    return s ? `${s.bank}:${s.index}:${s.format ?? ""}` : "proc";
  }

  private bufferForCue(cue: Cue): { buf: AudioBuffer; loopStart: number } | null {
    const refs = this.mapping.cues[cue].samples.filter((r) => this.banks[r.bank]?.entries[r.index]);
    // The engine always uses its first sample so the loop doesn't change under you.
    const ref = refs.length ? (cue === "engine" ? refs[0]! : refs[Math.floor(Math.random() * refs.length)]!) : null;
    if (ref) {
      const b = this.bufferForRef(ref);
      if (b) return b;
    }
    const key = `proc:${cue}`;
    let b = this.buffers.get(key);
    if (!b) {
      const c = this.context();
      if (!c) return null;
      const data = procedural(cue);
      const buf = c.createBuffer(1, data.length, PROC_RATE);
      buf.copyToChannel(data as Float32Array<ArrayBuffer>, 0);
      b = { buf, loopStart: 0 };
      this.buffers.set(key, b);
    }
    return b;
  }

  private bufferForRef(ref: SampleRef): { buf: AudioBuffer; loopStart: number } | null {
    const bank = this.banks[ref.bank];
    if (!bank || !bank.entries[ref.index]) return null;
    const format: SampleFormat = ref.format ?? bank.formats[ref.index]!;
    const key = `${ref.bank}:${ref.index}:${format}`;
    let b = this.buffers.get(key);
    if (b) return b;
    const c = this.context();
    if (!c) return null;
    const pcm = bank.pcm(ref.index, format);
    if (pcm.data.length === 0) return null;
    const up = upsample(pcm.data, pcm.rate);
    const buf = c.createBuffer(1, up.data.length, up.rate);
    buf.copyToChannel(up.data as Float32Array<ArrayBuffer>, 0);
    b = { buf, loopStart: (pcm.loopStart * up.factor) / up.rate };
    this.buffers.set(key, b);
    return b;
  }

  private kill(v: Voice): void {
    stop(v.src);
    v.ended = true;
    this.voices = this.voices.filter((x) => x !== v);
  }
}

function stop(src: AudioBufferSourceNode): void {
  try {
    src.stop();
  } catch {
    /* not started or already stopped */
  }
}
