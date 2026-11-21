import assert from "node:assert/strict";
import { test } from "node:test";
import { parseAsset } from "../src/assets/kinds.ts";
import { CUE_INFO, CUES, SPOKEN, defaultMapping, emptyMapping, engineRate, fallbackChain, loadMapping, normalizeMapping, saveMapping, STORE_KEY } from "../src/audio/cues.ts";
import { refIndex, spatial, upsample } from "../src/audio/engine.ts";
import { VocalBank, decodeWav, wavInfo } from "../src/audio/wav.ts";
import { procedural, RATE } from "../src/audio/procedural.ts";
import { SDT_ENTRY, SoundBank, checkSdt, decodeSample, guessFormat, parseSdt } from "../src/audio/sdt.ts";

/** Synthetic bank (no game data): a 16-bit tone, an 8-bit tone, a looped 16-bit tone. */
function bank(): { sdt: ArrayBuffer; raw: ArrayBuffer } {
  const s16 = (n: number, f: number, rate: number): Uint8Array => {
    const b = new Uint8Array(n * 2);
    const dv = new DataView(b.buffer);
    for (let i = 0; i < n; i++) dv.setInt16(i * 2, Math.round(Math.sin((2 * Math.PI * f * i) / rate) * 12000), true);
    return b;
  };
  const u8 = (n: number, f: number, rate: number): Uint8Array => Uint8Array.from({ length: n }, (_, i) => 128 + Math.round(Math.sin((2 * Math.PI * f * i) / rate) * 90));
  const parts: [Uint8Array, number, number][] = [
    [s16(2205, 440, 22050), 22050, 0],
    [u8(1101, 300, 5500), 5500, 0],
    [s16(800, 110, 8000), 8000, 400],
  ];
  const sdt = new ArrayBuffer(parts.length * SDT_ENTRY);
  const dv = new DataView(sdt);
  let off = 0;
  parts.forEach(([b, rate, loop], i) => {
    const o = i * SDT_ENTRY;
    dv.setUint32(o, off, true);
    dv.setUint32(o + 4, b.length, true);
    dv.setUint32(o + 8, rate, true);
    dv.setInt32(o + 12, i === 1 ? 500 : 0, true);
    dv.setInt32(o + 16, loop, true);
    dv.setInt32(o + 20, -1, true);
    off += b.length;
  });
  const raw = new Uint8Array(off);
  let p = 0;
  for (const [b] of parts) {
    raw.set(b, p);
    p += b.length;
  }
  return { sdt, raw: raw.buffer };
}

test("sdt: 24-byte entries, contiguous check, import info", () => {
  const { sdt, raw } = bank();
  const e = parseSdt(sdt);
  assert.equal(e.length, 3);
  assert.deepEqual(e[1], { index: 1, offset: 4410, size: 1101, rate: 5500, unknownA: 500, loopStart: 0, loopEnd: -1 });
  assert.deepEqual(checkSdt(sdt), { ok: true, count: 3, rawSize: raw.byteLength });
  assert.equal(checkSdt(sdt.slice(0, 30)).ok, false);
  const broken = sdt.slice(0);
  new DataView(broken).setUint32(SDT_ENTRY, 9, true);
  assert.match(checkSdt(broken).error!, /not contiguous/);
  const info = parseAsset("sdt", sdt);
  assert.equal(info.ok, true);
  assert.equal(info.samples, 3);
});

test("sdt: 16-bit and 8-bit samples told apart and decoded", () => {
  const { sdt, raw } = bank();
  const b = new SoundBank("t", sdt, raw);
  assert.deepEqual(b.formats, ["s16", "u8", "s16"]);
  assert.equal(guessFormat(new Uint8Array(10).fill(0x80)), "u8");
  const a = b.pcm(0);
  assert.equal(a.data.length, 2205);
  assert.ok(Math.abs(Math.max(...a.data) - 12000 / 32768) < 0.01);
  const c = b.pcm(1);
  assert.equal(c.data.length, 1101);
  assert.ok(Math.max(...c.data) < 0.75 && Math.min(...c.data) > -0.75);
  assert.equal(b.pcm(2).loopStart, 200, "loop start is in bytes; 16-bit halves it");
  assert.ok(Math.abs(b.duration(1) - 1101 / 5500) < 1e-9);
  assert.deepEqual([...decodeSample(Uint8Array.from([0, 128, 255]), "u8")], [-1, 0, 127 / 128]);
});

test("mapping: defaults, junk dropped, saved and loaded", () => {
  const m = emptyMapping();
  assert.deepEqual(Object.keys(m.cues), [...CUES]);
  const n = normalizeMapping({ cues: { pistol: { samples: [{ bank: "map", index: 3 }, { bank: "x", index: 1 }, { bank: "fstyle", index: -1 }, { bank: "fstyle", index: 2, format: "u8" }], gain: 9 }, nope: {} }, engine: { idleRate: "fast" } });
  assert.deepEqual(n.cues.pistol, { samples: [{ bank: "map", index: 3 }, { bank: "fstyle", index: 2, format: "u8" }], gain: 2 });
  assert.equal(n.engine.idleRate, m.engine.idleRate);
  const mem = new Map<string, string>();
  const st = { getItem: (k: string) => mem.get(k) ?? null, setItem: (k: string, v: string) => void mem.set(k, v) };
  saveMapping(n, st);
  assert.ok(mem.has(STORE_KEY));
  assert.deepEqual(loadMapping(st), n);
  mem.set(STORE_KEY, "{not json");
  assert.deepEqual(loadMapping(st), defaultMapping());
  mem.clear();
  assert.deepEqual(loadMapping(st), defaultMapping(), "nothing saved: the shipped mapping");
});

test("mapping: cues missing from a saved or imported file keep the default", () => {
  const old = normalizeMapping({ cues: { pistol: { samples: [{ bank: "map", index: 1 }], gain: 1 }, horn: { samples: [], gain: 1 } } });
  assert.deepEqual(old.cues.pistol.samples, [{ bank: "map", index: 1 }]);
  assert.deepEqual(old.cues.horn.samples, [], "an emptied cue stays empty");
  assert.deepEqual(old.cues.explosion, defaultMapping().cues.explosion);
  const cleared = normalizeMapping(JSON.parse(JSON.stringify(emptyMapping())));
  assert.ok(CUES.every((c) => cleared.cues[c].samples.length === 0), "a cleared mapping round-trips as cleared");
});

test("cue fallbacks end, and point at real cues", () => {
  for (const c of CUES) {
    const ch = fallbackChain(c);
    assert.equal(ch[0], c);
    assert.equal(new Set(ch).size, ch.length, c);
    for (const f of ch) assert.ok(CUE_INFO[f], `${c} → ${f}`);
  }
  assert.deepEqual(fallbackChain("dual_pistol"), ["dual_pistol", "pistol"]);
  assert.deepEqual(fallbackChain("game_over"), ["game_over", "mission_fail"]);
});

test("engine pitch follows speed and saturates", () => {
  const m = emptyMapping();
  assert.equal(engineRate(m, 0), m.engine.idleRate);
  assert.equal(engineRate(m, m.engine.topSpeed), m.engine.topRate);
  assert.equal(engineRate(m, 10), m.engine.topRate);
  assert.ok(engineRate(m, m.engine.topSpeed / 2) > m.engine.idleRate);
});

test("spatial: full level close, quieter far, silent past range, pans by x", () => {
  const l = { x: 10, y: 10, z: 2 };
  assert.deepEqual(spatial(l, 10, 10, 2), { gain: 1, pan: 0 });
  const mid = spatial(l, 16, 10, 2);
  assert.ok(mid.gain < 1 && mid.gain > 0.2 && mid.pan > 0.5);
  assert.ok(spatial(l, 4, 10, 2).pan < -0.5);
  assert.equal(spatial(l, 40, 10, 2).gain, 0);
  assert.ok(spatial(l, 10, 30, 2).gain < spatial(l, 10, 20, 2).gain);
});

test("upsample keeps slow banks above the lowest buffer rate", () => {
  const u = upsample(Float32Array.from([0, 1, 0]), 5500);
  assert.equal(u.rate, 11000);
  assert.deepEqual([...u.data], [0, 0.5, 1, 0.5, 0, 0]);
  assert.equal(upsample(new Float32Array(4), 22050).factor, 1);
});

test("every cue but the spoken ones has a short, non-silent, clean procedural fallback", () => {
  for (const c of CUES) {
    const b = procedural(c);
    if (SPOKEN.has(c)) {
      assert.equal(b, null, `${c} is spoken: silent until mapped`);
      continue;
    }
    assert.ok(b, `${c} has no built-in sound`);
    assert.ok(b.length > RATE * 0.03 && b.length <= RATE * 2, `${c} length ${b.length}`);
    let peak = 0;
    for (const v of b) {
      assert.ok(Number.isFinite(v), c);
      peak = Math.max(peak, Math.abs(v));
    }
    assert.ok(peak > 0.3 && peak <= 1, `${c} peak ${peak}`);
  }
  assert.equal(procedural("engine")!.length, RATE, "the engine loop is exactly one second");
  assert.equal(procedural("pistol"), procedural("pistol"), "cached");
});

/** A WAVE file from parts (synthetic, no game data). */
function wav(format: number, channels: number, rate: number, blockAlign: number, bits: number, data: number[]): ArrayBuffer {
  const fmt = new Uint8Array(16);
  const f = new DataView(fmt.buffer);
  f.setUint16(0, format, true);
  f.setUint16(2, channels, true);
  f.setUint32(4, rate, true);
  f.setUint16(12, blockAlign, true);
  f.setUint16(14, bits, true);
  const parts = [new TextEncoder().encode("RIFF"), new Uint8Array(4), new TextEncoder().encode("WAVEfmt "), Uint8Array.of(16, 0, 0, 0), fmt, new TextEncoder().encode("data"), Uint8Array.of(data.length, 0, 0, 0), Uint8Array.from(data)];
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out.buffer;
}

test("wav: PCM and IMA ADPCM decode to mono", () => {
  const pcm = decodeWav(wav(1, 2, 11025, 4, 16, [0x00, 0x40, 0x00, 0x20, 0x00, 0xc0, 0x00, 0xe0]));
  assert.equal(pcm.rate, 11025);
  assert.deepEqual([...pcm.data], [0.375, -0.375], "stereo mixed down");
  // One mono block: predictor 1000, step index 0, then nibbles 7, 7 and six 0s.
  const ima = decodeWav(wav(0x11, 1, 22050, 8, 4, [0xe8, 0x03, 0, 0, 0x77, 0, 0, 0]));
  assert.deepEqual([...ima.data].map((v) => Math.round(v * 32768)), [1000, 1011, 1041, 1045, 1048, 1051, 1054, 1056, 1058]);
  assert.throws(() => wavInfo(new ArrayBuffer(12)), /not a WAVE/);
  assert.equal(parseAsset("wav", wav(1, 1, 8000, 1, 8, [128])).ok, true);
  assert.equal(parseAsset("wav", new ArrayBuffer(4)).ok, false);
});

test("vocals: lines are referred to by name, whatever order the files come in", () => {
  const a = wav(1, 1, 8000, 1, 8, [128, 255]);
  const bank = new VocalBank([{ name: "Wasted.wav", buf: a }, { name: "busted.wav", buf: a }, { name: "junk.wav", buf: new ArrayBuffer(3) }]);
  assert.deepEqual(bank.names, ["busted", "wasted"]);
  assert.equal(refIndex(bank, { bank: "vocals", index: 0, name: "wasted" }), 1);
  assert.equal(refIndex(bank, { bank: "vocals", index: 0, name: "gone" }), -1);
  assert.equal(bank.pcm(1).data.length, 2);
  const m = normalizeMapping({ cues: { wasted: { samples: [{ bank: "vocals", name: "Wasted" }, { bank: "vocals" }], gain: 1 } } });
  assert.deepEqual(m.cues.wasted.samples, [{ bank: "vocals", index: 0, name: "wasted" }]);
  assert.ok(defaultMapping().cues.say_pistol.samples.every((r) => r.bank === "vocals" && r.name));
});
