// GTA2 sound banks: a .sdt index and a .raw blob of samples.
//
// The layout here was read off the player's own files (data/audio/*.sdt), not
// from any decompiled code. Every .sdt is a flat array of 24-byte little-endian
// entries, with no header:
//
//   u32 offset      byte offset of the sample in the paired .raw
//   u32 size        length in bytes
//   u32 rate        sample rate in Hz (4500 to 22050 in the shipped banks)
//   i32 unknownA    0, 500, 700 … 2500; meaning not known, shown on the board
//   i32 loopStart   byte offset into the sample where a loop starts, or 0
//   i32 loopEnd     always -1 in the shipped banks (loop to the end)
//
// Entries are contiguous: entry n+1 starts where n ends, and the last one ends
// at the end of the .raw. Samples are mono PCM, but two encodings are mixed in
// one bank with no flag in the entry: 16-bit signed (most) and 8-bit unsigned
// (the 5500 Hz block in the map banks, and every odd-sized entry).
// `guessFormat` tells them apart from the bytes; the sound board can override.

export const SDT_ENTRY = 24;

export type SampleFormat = "s16" | "u8";

export interface SdtEntry {
  index: number;
  offset: number;
  size: number;
  rate: number;
  unknownA: number;
  loopStart: number;
  loopEnd: number;
}

export interface SdtCheck {
  ok: boolean;
  error?: string;
  count: number;
  /** Bytes the paired .raw must have: end of the last entry. */
  rawSize: number;
}

export function parseSdt(buf: ArrayBuffer): SdtEntry[] {
  const dv = new DataView(buf);
  const n = Math.floor(buf.byteLength / SDT_ENTRY);
  const out: SdtEntry[] = [];
  for (let i = 0; i < n; i++) {
    const o = i * SDT_ENTRY;
    out.push({
      index: i,
      offset: dv.getUint32(o, true),
      size: dv.getUint32(o + 4, true),
      rate: dv.getUint32(o + 8, true),
      unknownA: dv.getInt32(o + 12, true),
      loopStart: dv.getInt32(o + 16, true),
      loopEnd: dv.getInt32(o + 20, true),
    });
  }
  return out;
}

/** Structural check used on import: whole entries, contiguous, sane rates. */
export function checkSdt(buf: ArrayBuffer): SdtCheck {
  if (buf.byteLength === 0) return { ok: false, error: "empty file", count: 0, rawSize: 0 };
  if (buf.byteLength % SDT_ENTRY !== 0) return { ok: false, error: `size is not a multiple of ${SDT_ENTRY}`, count: 0, rawSize: 0 };
  const e = parseSdt(buf);
  let end = 0;
  for (const x of e) {
    if (x.offset !== end) return { ok: false, error: `entry ${x.index} is not contiguous`, count: e.length, rawSize: 0 };
    if (x.rate < 1000 || x.rate > 96000) return { ok: false, error: `entry ${x.index} has rate ${x.rate}`, count: e.length, rawSize: 0 };
    end = x.offset + x.size;
  }
  return { ok: true, count: e.length, rawSize: end };
}

const smooth = (b: Uint8Array, start: number, signed: boolean): number => {
  let sum = 0;
  let n = 0;
  let prev = signed ? (b[start]! << 24) >> 24 : b[start]!;
  for (let i = start + 2; i < b.length; i += 2) {
    const v = signed ? (b[i]! << 24) >> 24 : b[i]!;
    sum += Math.abs(v - prev);
    prev = v;
    n++;
  }
  return n ? sum / n : 0;
};

/**
 * 16-bit audio read as bytes has noisy low bytes and smooth high bytes; 8-bit
 * audio has both byte lanes alike (and its high lane, read as signed, jumps
 * across the 0x80 midpoint). Odd sizes can only be 8-bit.
 */
export function guessFormat(bytes: Uint8Array): SampleFormat {
  if (bytes.length % 2 === 1) return "u8";
  if (bytes.length < 8) return "s16";
  let all80 = true;
  for (let i = 0; i < bytes.length && all80; i++) all80 = bytes[i] === 0x80;
  if (all80) return "u8";
  const q = (smooth(bytes, 0, false) + 0.5) / (smooth(bytes, 1, true) + 0.5);
  return q < 0.7 ? "u8" : "s16";
}

export function decodeSample(bytes: Uint8Array, format: SampleFormat): Float32Array {
  if (format === "u8") {
    const out = new Float32Array(bytes.length);
    for (let i = 0; i < bytes.length; i++) out[i] = (bytes[i]! - 128) / 128;
    return out;
  }
  const n = bytes.length >> 1;
  const out = new Float32Array(n);
  const dv = new DataView(bytes.buffer, bytes.byteOffset, n * 2);
  for (let i = 0; i < n; i++) out[i] = dv.getInt16(i * 2, true) / 32768;
  return out;
}

/** One bank: its entries and the raw bytes they index. */
export class SoundBank {
  readonly entries: SdtEntry[];
  readonly formats: SampleFormat[];
  readonly id: string;
  private raw: Uint8Array;

  constructor(id: string, sdt: ArrayBuffer, raw: ArrayBuffer) {
    this.id = id;
    this.raw = new Uint8Array(raw);
    this.entries = parseSdt(sdt).filter((e) => e.offset + e.size <= this.raw.length);
    this.formats = this.entries.map((e) => guessFormat(this.bytes(e.index)));
  }

  bytes(i: number): Uint8Array {
    const e = this.entries[i]!;
    return this.raw.subarray(e.offset, e.offset + e.size);
  }

  /** Decoded PCM, its rate, and the loop start in samples (0 when none). */
  pcm(i: number, format: SampleFormat = this.formats[i]!): { data: Float32Array; rate: number; loopStart: number } {
    const e = this.entries[i]!;
    const data = decodeSample(this.bytes(i), format);
    const bps = format === "s16" ? 2 : 1;
    const ls = e.loopStart > 0 ? Math.min(data.length - 1, Math.floor(e.loopStart / bps)) : 0;
    return { data, rate: e.rate, loopStart: ls };
  }

  /** Length in seconds as guessed. */
  duration(i: number): number {
    const e = this.entries[i]!;
    return e.size / (this.formats[i] === "s16" ? 2 : 1) / e.rate;
  }
}
