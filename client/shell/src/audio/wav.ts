// RIFF WAVE files, as the spoken lines in data/audio/Vocals/*.wav ship. Two
// encodings are handled: plain PCM (8-bit unsigned or 16-bit signed) and IMA
// ADPCM (format tag 0x11), which is what the shipped lines use. Both are public
// formats (Microsoft RIFF and the IMA ADPCM recommendation). Stereo is mixed
// down to mono, since every sound is placed in the world by the engine.

export interface WavInfo {
  format: number;
  channels: number;
  rate: number;
  blockAlign: number;
  bits: number;
  /** Byte offset and length of the data chunk. */
  dataOffset: number;
  dataSize: number;
}

const tag = (b: Uint8Array, o: number): string => String.fromCharCode(b[o]!, b[o + 1]!, b[o + 2]!, b[o + 3]!);

/** Reads the header; throws if it is not a WAVE file this can decode. */
export function wavInfo(buf: ArrayBuffer): WavInfo {
  const b = new Uint8Array(buf);
  if (b.length < 12 || tag(b, 0) !== "RIFF" || tag(b, 8) !== "WAVE") throw new Error("not a WAVE file");
  const dv = new DataView(buf);
  let fmt: Omit<WavInfo, "dataOffset" | "dataSize"> | null = null;
  let o = 12;
  while (o + 8 <= b.length) {
    const id = tag(b, o);
    const size = dv.getUint32(o + 4, true);
    if (id === "fmt " && size >= 16) {
      fmt = {
        format: dv.getUint16(o + 8, true),
        channels: dv.getUint16(o + 10, true),
        rate: dv.getUint32(o + 12, true),
        blockAlign: dv.getUint16(o + 20, true),
        bits: dv.getUint16(o + 22, true),
      };
    } else if (id === "data") {
      if (!fmt) throw new Error("data before fmt");
      if (fmt.format !== 1 && fmt.format !== 0x11) throw new Error(`unsupported WAVE format ${fmt.format}`);
      if (fmt.channels < 1 || fmt.channels > 2) throw new Error(`${fmt.channels} channels`);
      if (fmt.format === 1 && fmt.bits !== 8 && fmt.bits !== 16) throw new Error(`${fmt.bits}-bit PCM`);
      if (fmt.format === 0x11 && fmt.blockAlign <= 4 * fmt.channels) throw new Error("bad ADPCM block size");
      return { ...fmt, dataOffset: o + 8, dataSize: Math.min(size, b.length - o - 8) };
    }
    o += 8 + size + (size & 1);
  }
  throw new Error("no data chunk");
}

const STEPS = [
  7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253,
  279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026,
  4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
];
const INDEX_STEP = [-1, -1, -1, -1, 2, 4, 6, 8];

class ImaChannel {
  pred: number;
  index: number;
  constructor(pred: number, index: number) {
    this.pred = pred;
    this.index = index;
  }
  next(nibble: number): number {
    const step = STEPS[this.index]!;
    let diff = step >> 3;
    if (nibble & 1) diff += step >> 2;
    if (nibble & 2) diff += step >> 1;
    if (nibble & 4) diff += step;
    this.pred += nibble & 8 ? -diff : diff;
    this.pred = Math.max(-32768, Math.min(32767, this.pred));
    this.index = Math.max(0, Math.min(88, this.index + INDEX_STEP[nibble & 7]!));
    return this.pred;
  }
}

function decodeIma(b: Uint8Array, w: WavInfo): Float32Array {
  const ch = w.channels;
  const perBlock = ((w.blockAlign - 4 * ch) * 8) / (4 * ch) + 1;
  const blocks = Math.floor(w.dataSize / w.blockAlign);
  const tail = w.dataSize - blocks * w.blockAlign;
  const tailSamples = tail > 4 * ch ? ((tail - 4 * ch) * 8) / (4 * ch) + 1 : 0;
  const out = new Float32Array(blocks * perBlock + Math.floor(tailSamples));
  const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
  let n = 0;
  for (let k = 0; k <= blocks; k++) {
    const start = w.dataOffset + k * w.blockAlign;
    const end = Math.min(start + w.blockAlign, w.dataOffset + w.dataSize);
    if (end - start <= 4 * ch) break;
    const chans: ImaChannel[] = [];
    for (let c = 0; c < ch; c++) chans.push(new ImaChannel(dv.getInt16(start + 4 * c, true), Math.min(88, b[start + 4 * c + 2]!)));
    out[n++] = chans.reduce((s, c) => s + c.pred, 0) / ch / 32768;
    // After the headers: 4 bytes (8 samples) per channel in turn.
    const buf: number[][] = chans.map(() => []);
    for (let o = start + 4 * ch; o + 4 * ch <= end; o += 4 * ch) {
      for (let c = 0; c < ch; c++) {
        for (let j = 0; j < 4; j++) {
          const byte = b[o + 4 * c + j]!;
          buf[c]!.push(chans[c]!.next(byte & 15), chans[c]!.next(byte >> 4));
        }
      }
      for (let j = 0; j < 8 && n < out.length; j++) {
        let s = 0;
        for (let c = 0; c < ch; c++) s += buf[c]![j]!;
        out[n++] = s / ch / 32768;
      }
      for (const x of buf) x.length = 0;
    }
  }
  return n === out.length ? out : out.subarray(0, n);
}

/** Mono samples in -1..1 and their rate. */
export function decodeWav(buf: ArrayBuffer): { data: Float32Array; rate: number } {
  const w = wavInfo(buf);
  const b = new Uint8Array(buf);
  if (w.format === 0x11) return { data: decodeIma(b, w), rate: w.rate };
  const bytes = w.bits / 8;
  const frames = Math.floor(w.dataSize / (bytes * w.channels));
  const out = new Float32Array(frames);
  const dv = new DataView(buf);
  for (let i = 0; i < frames; i++) {
    let s = 0;
    for (let c = 0; c < w.channels; c++) {
      const o = w.dataOffset + (i * w.channels + c) * bytes;
      s += bytes === 1 ? (b[o]! - 128) / 128 : dv.getInt16(o, true) / 32768;
    }
    out[i] = s / w.channels;
  }
  return { data: out, rate: w.rate };
}

/**
 * The spoken lines (data/audio/Vocals/*.wav) as one bank, shaped like a
 * SoundBank so the engine and the board treat it the same. Samples are named
 * by file (without .wav); mappings refer to them by name, since which lines a
 * player has decides the order.
 */
export class VocalBank {
  readonly id = "vocals";
  readonly names: string[];
  readonly entries: { index: number; size: number; rate: number; unknownA: number; loopStart: number; loopEnd: number }[];
  readonly formats: "s16"[];
  private files: ArrayBuffer[];
  private decoded = new Map<number, { data: Float32Array; rate: number }>();

  constructor(files: { name: string; buf: ArrayBuffer }[]) {
    const ok = files
      .map((f) => {
        try {
          return { name: f.name.toLowerCase().replace(/\.wav$/, ""), buf: f.buf, info: wavInfo(f.buf) };
        } catch {
          return null;
        }
      })
      .filter((f) => f !== null)
      .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    this.names = ok.map((f) => f.name);
    this.files = ok.map((f) => f.buf);
    // Length in "16-bit bytes" so size / 2 / rate is the duration, as for .sdt banks.
    this.entries = ok.map((f, index) => {
      const frames = f.info.format === 0x11 ? Math.round((f.info.dataSize * 2) / f.info.channels) : f.info.dataSize / (f.info.bits / 8) / f.info.channels;
      return { index, size: Math.round(frames) * 2, rate: f.info.rate, unknownA: 0, loopStart: 0, loopEnd: -1 };
    });
    this.formats = this.entries.map(() => "s16");
  }

  pcm(i: number): { data: Float32Array; rate: number; loopStart: number } {
    let d = this.decoded.get(i);
    if (!d) this.decoded.set(i, (d = decodeWav(this.files[i]!)));
    return { data: d.data, rate: d.rate, loopStart: 0 };
  }

  duration(i: number): number {
    const e = this.entries[i]!;
    return e.size / 2 / e.rate;
  }
}
