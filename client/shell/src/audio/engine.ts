// WebAudio sound for the game screen. One master gain (volume and mute), one
// stereo panner and gain per voice placed relative to the listener (the
// camera), and one looping source per engine whose pitch follows car speed.
//
// The camera looks straight down, so a sound to the right of the listener
// pans right and distance in blocks sets the level; nothing is behind you.

import { type Cue, type SampleRef, type SoundMapping, engineRate, fallbackChain, loadMapping, saveMapping } from "./cues.ts";
import { RATE as PROC_RATE, procedural } from "./procedural.ts";
import type { SampleFormat, SoundBank } from "./sdt.ts";
import type { VocalBank } from "./wav.ts";

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
/**
 * Lowest buffer rate every browser accepts; slower banks are upsampled.
 * Safari before 14.1 refused buffers under 22050 Hz (NotSupportedError), so
 * that, not the 8000 Hz the spec allows, is the floor.
 */
const MIN_RATE = 22050;

export type BankId = SampleRef["bank"];
export type Bank = SoundBank | VocalBank;

/** Where a reference points in its bank, or -1 when the bank lacks it. */
export function refIndex(bank: Bank | undefined, ref: SampleRef): number {
  if (!bank) return -1;
  if (ref.bank === "vocals") return "names" in bank ? bank.names.indexOf(ref.name ?? "") : -1;
  return bank.entries[ref.index] ? ref.index : -1;
}

interface Voice {
  cue: Cue | null;
  src: AudioBufferSourceNode;
  ended: boolean;
}

interface Engine {
  src: AudioBufferSourceNode;
  gain: GainNode;
  pan: StereoPannerNode | Panless;
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
  banks: Partial<Record<BankId, Bank>> = {};
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
      if (!this.running) this.unlock();
    };
    this.unlockHandler = h;
    // Safari only unlocks audio from some events (touchend and click, not
    // touchstart; pointerdown not on every version), so listen to all of them.
    for (const ev of ["pointerdown", "pointerup", "mousedown", "click", "keydown", "touchstart", "touchend"]) target.addEventListener(ev, h, { capture: true });
    // Coming back to the tab: Safari leaves the context suspended or interrupted.
    if (typeof document !== "undefined") document.addEventListener("visibilitychange", () => document.visibilityState === "visible" && void this.resume());
  }

  async resume(): Promise<void> {
    const c = this.context();
    // Safari also has "interrupted" (a call, another app took the audio).
    if (c && c.state !== "running" && c.state !== "closed") {
      try {
        await c.resume();
      } catch {
        /* needs a gesture */
      }
    }
  }

  /**
   * Call from inside a user gesture (a tap, click or key; a gamepad button
   * isn't one). iOS needs the context made, resumed and a sound started all
   * in the same gesture before it lets any audio out, so this starts a
   * one-sample silent buffer too.
   */
  unlock(): void {
    const c = this.context();
    if (!c || c.state === "closed") return;
    if (c.state !== "running") Promise.resolve(c.resume?.()).catch((e: unknown) => this.note(e));
    this.unlockSilentMode();
    try {
      const src = c.createBufferSource();
      src.buffer = c.createBuffer(1, 1, c.sampleRate);
      src.connect(c.destination);
      src.start(0);
    } catch {
      /* not yet */
    }
  }

  private silentEl: HTMLAudioElement | null = null;
  /**
   * iOS before 17 puts web audio in the "ambient" category, which the silent
   * switch (or Silent Mode in Control Center) mutes, while a playing <audio>
   * element moves the page to "playback". So, from the gesture, loop a
   * silent one for as long as the page lives.
   */
  private unlockSilentMode(): void {
    if (typeof Audio === "undefined" || typeof URL === "undefined" || typeof Blob === "undefined") return;
    try {
      if (!this.silentEl) {
        const el = new Audio();
        el.setAttribute("playsinline", "");
        el.setAttribute("x-webkit-airplay", "deny");
        el.loop = true;
        el.preload = "auto";
        el.src = URL.createObjectURL(new Blob([wavBytes(new Float32Array(4410), 44100)], { type: "audio/wav" }));
        this.silentEl = el;
      }
      if (this.silentEl.paused) this.silentEl.play().catch((e: unknown) => this.note(e));
    } catch (e) {
      this.note(e);
    }
  }

  // ---- diagnostics (the sound check panel) -------------------------------

  private stats = { plays: 0, lastCue: "", lastPeak: 0, lastGain: 0, errors: [] as string[] };
  private note(e: unknown): void {
    const m = e instanceof Error ? `${e.name}: ${e.message}` : String(e);
    this.stats.errors = [...this.stats.errors.slice(-4), m];
  }

  /** What a player can read out when they hear nothing. */
  diagnostics(): Record<string, string> {
    const c = this.ctx;
    const n = (v: number | undefined): string => (v === undefined ? "n/a" : v.toFixed(3));
    const banks = (Object.keys(this.banks) as BankId[]).map((k) => `${k} ${this.banks[k]!.entries.length}`).join(", ") || "none";
    const session = (navigator as { audioSession?: { type: string; state?: string } }).audioSession;
    return {
      "Context": c ? c.state : "not made yet",
      "Sample rate": c ? `${c.sampleRate} Hz` : "n/a",
      "Clock": c ? `${c.currentTime.toFixed(2)} s` : "n/a",
      "Output latency": c ? n((c as { outputLatency?: number }).outputLatency) : "n/a",
      "Volume": `${Math.round(this.volume_ * 100)}%${this.muted_ ? " (muted)" : ""}`,
      "Master gain": this.master ? n(this.master.gain.value) : "n/a",
      "Audio session": session ? `${session.type}${session.state ? `, ${session.state}` : ""}` : "not available",
      "Silent-mode loop": this.silentEl ? (this.silentEl.paused ? "paused" : "playing") : "not started",
      "Banks": banks,
      "Buffers made": String(this.buffers.size),
      "Voices": `${this.voices.filter((v) => !v.ended).length} playing, ${this.engines.size} engines`,
      "Sounds played": String(this.stats.plays),
      "Last sound": this.stats.lastCue ? `${this.stats.lastCue}, peak ${this.stats.lastPeak < 0 ? "no buffer" : n(this.stats.lastPeak)}, gain ${n(this.stats.lastGain)}` : "none",
      "Errors": this.stats.errors.join(" | ") || "none",
      "Browser": navigator.userAgent,
    };
  }

  /** A plain 440 Hz beep straight to the speakers, past the mapping and banks. */
  testTone(): void {
    this.unlock();
    const c = this.ctx;
    if (!c) return;
    try {
      const o = c.createOscillator();
      const g = c.createGain();
      o.frequency.value = 440;
      g.gain.setValueAtTime(0.3, c.currentTime);
      g.gain.setTargetAtTime(0, c.currentTime + 0.5, 0.05);
      o.connect(g).connect(c.destination);
      o.start();
      o.stop(c.currentTime + 0.8);
    } catch (e) {
      this.note(e);
    }
  }

  /** The same beep through an <audio> element, which the silent switch doesn't mute. */
  testToneHtml(): void {
    try {
      const d = new Float32Array(26460);
      for (let i = 0; i < d.length; i++) d[i] = 0.3 * Math.sin((2 * Math.PI * 440 * i) / 44100) * Math.min(1, (d.length - i) / 2000);
      const el = new Audio(URL.createObjectURL(new Blob([wavBytes(d, 44100)], { type: "audio/wav" })));
      el.play().catch((e: unknown) => this.note(e));
    } catch (e) {
      this.note(e);
    }
  }

  get running(): boolean {
    return this.ctx?.state === "running";
  }

  private context(): AudioContext | null {
    if (this.ctx) return this.ctx;
    const AC = (globalThis as { AudioContext?: typeof AudioContext; webkitAudioContext?: typeof AudioContext }).AudioContext ?? (globalThis as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!AC) return null;
    // iOS: play through the ring/silent switch like a game, not like a ringtone.
    try {
      const s = (navigator as { audioSession?: { type: string } }).audioSession;
      if (s) s.type = "playback";
    } catch {
      /* older Safari */
    }
    try {
      this.ctx = new AC({ latencyHint: "interactive" });
    } catch {
      this.ctx = new AC();
    }
    // Let the screens show or hide their "tap for sound" prompt.
    this.ctx.onstatechange = () => this.emit();
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

  setBanks(banks: Partial<Record<BankId, Bank>>, names: Partial<Record<BankId, string>> = {}): void {
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

  /** Where the listener is, in blocks. */
  get listenerAt(): Readonly<Listener> {
    return this.listener;
  }

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
    this.stats.lastCue = cue;
    if (!b) {
      this.stats.lastPeak = -1;
      return;
    }
    this.stats.plays++;
    this.stats.lastPeak = peakOf(b.buf);
    this.stats.lastGain = sp.gain * m.gain;
    try {
      this.startVoice(c, cue, b, sp, m.gain);
    } catch (e) {
      this.note(e);
    }
  }

  private startVoice(c: AudioContext, cue: Cue, b: { buf: AudioBuffer }, sp: { gain: number; pan: number }, gain: number): void {
    this.voices = this.voices.filter((v) => !v.ended);
    const same = this.voices.filter((v) => v.cue === cue);
    if (same.length >= MAX_PER_CUE) this.kill(same[0]!);
    if (this.voices.length >= MAX_VOICES) this.kill(this.voices[0]!);
    const src = c.createBufferSource();
    src.buffer = b.buf;
    src.playbackRate.value = 0.96 + Math.random() * 0.08;
    const g = c.createGain();
    g.gain.value = sp.gain * gain;
    const p = panner(c);
    p.pan.value = sp.pan;
    src.connect(g).connect(p).connect(this.master!);
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
      const pan = panner(c);
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
    return s ? `${s.bank}:${s.index}:${s.name ?? ""}:${s.format ?? ""}` : "proc";
  }

  private bufferForCue(cue: Cue): { buf: AudioBuffer; loopStart: number } | null {
    // A cue with no usable samples borrows from its fallbacks (dual pistol → pistol).
    let refs: SampleRef[] = [];
    for (const c of fallbackChain(cue)) {
      refs = this.mapping.cues[c].samples.filter((r) => refIndex(this.banks[r.bank], r) >= 0);
      if (refs.length) break;
    }
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
      if (!data) return null;
      const buf = c.createBuffer(1, data.length, PROC_RATE);
      buf.copyToChannel(data as Float32Array<ArrayBuffer>, 0);
      b = { buf, loopStart: 0 };
      this.buffers.set(key, b);
    }
    return b;
  }

  private bufferForRef(ref: SampleRef): { buf: AudioBuffer; loopStart: number } | null {
    const bank = this.banks[ref.bank];
    const i = refIndex(bank, ref);
    if (!bank || i < 0) return null;
    const format: SampleFormat = ref.format ?? bank.formats[i]!;
    const key = `${ref.bank}:${i}:${format}`;
    let b = this.buffers.get(key);
    if (b) return b;
    const c = this.context();
    if (!c) return null;
    const pcm = bank.pcm(i, format);
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

/** Stands in for a StereoPannerNode on Safari before 14.1, which lacks it. */
type Panless = GainNode & { pan: AudioParam };
function panner(c: AudioContext): StereoPannerNode | Panless {
  if (typeof c.createStereoPanner === "function") return c.createStereoPanner();
  const g = c.createGain() as Panless;
  // A param nothing listens to, so callers can still set .pan.
  (g as { pan: AudioParam }).pan = c.createGain().gain;
  return g;
}

function peakOf(b: AudioBuffer): number {
  const d = b.getChannelData(0);
  let m = 0;
  for (let i = 0; i < d.length; i++) m = Math.max(m, Math.abs(d[i]!));
  return m;
}

/** Mono 16-bit PCM WAVE bytes. */
export function wavBytes(d: Float32Array, rate: number): ArrayBuffer {
  const buf = new ArrayBuffer(44 + d.length * 2);
  const v = new DataView(buf);
  const str = (o: number, t: string): void => {
    for (let i = 0; i < 4; i++) v.setUint8(o + i, t.charCodeAt(i));
  };
  str(0, "RIFF");
  v.setUint32(4, 36 + d.length * 2, true);
  str(8, "WAVE");
  str(12, "fmt ");
  v.setUint32(16, 16, true);
  v.setUint16(20, 1, true);
  v.setUint16(22, 1, true);
  v.setUint32(24, rate, true);
  v.setUint32(28, rate * 2, true);
  v.setUint16(32, 2, true);
  v.setUint16(34, 16, true);
  str(36, "data");
  v.setUint32(40, d.length * 2, true);
  for (let i = 0; i < d.length; i++) v.setInt16(44 + i * 2, Math.round(Math.max(-1, Math.min(1, d[i]!)) * 32767), true);
  return buf;
}

function stop(src: AudioBufferSourceNode): void {
  try {
    src.stop();
  } catch {
    /* not started or already stopped */
  }
}
