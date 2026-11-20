import assert from "node:assert/strict";
import { test } from "node:test";
import { parseAsset } from "../src/assets/kinds.ts";
import { CUES, emptyMapping, engineRate, loadMapping, normalizeMapping, saveMapping, STORE_KEY } from "../src/audio/cues.ts";
import { spatial, upsample } from "../src/audio/engine.ts";
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
  assert.deepEqual(loadMapping(st), emptyMapping());
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

test("every cue has a short, non-silent, clean procedural fallback", () => {
  for (const c of CUES) {
    const b = procedural(c);
    assert.ok(b.length > RATE * 0.03 && b.length <= RATE * 2, `${c} length ${b.length}`);
    let peak = 0;
    for (const v of b) {
      assert.ok(Number.isFinite(v), c);
      peak = Math.max(peak, Math.abs(v));
    }
    assert.ok(peak > 0.3 && peak <= 1, `${c} peak ${peak}`);
  }
  assert.equal(procedural("engine").length, RATE, "the engine loop is exactly one second");
  assert.equal(procedural("pistol"), procedural("pistol"), "cached");
});
