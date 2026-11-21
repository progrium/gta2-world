import assert from "node:assert/strict";
import { test } from "node:test";
import { deflateRawSync } from "node:zlib";
import { InstallerReader, parseCabHeader, wanted } from "../src/assets/installer.ts";

const enc = (s: string): Uint8Array => new Uint8Array([...s].map((c) => c.charCodeAt(0)));

function cat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

/** Stored form of a compressed file: chunks of u16 length + raw deflate. */
function compress(data: Uint8Array, chunk: number): Uint8Array {
  const parts: Uint8Array[] = [];
  for (let o = 0; o < data.length; o += chunk) {
    const z = new Uint8Array(deflateRawSync(data.subarray(o, o + chunk)));
    parts.push(new Uint8Array([z.length & 0xff, z.length >> 8]), z);
  }
  return cat(...parts);
}

interface Spec {
  dir: number;
  name: string;
  data: Uint8Array;
  compressed: boolean;
  volume: number;
}

/** A minimal InstallShield 6+ header and its volumes. */
function cabinet(dirs: string[], files: Spec[]): { hdr: Uint8Array; volumes: Map<number, Uint8Array> } {
  const stored = files.map((f) => (f.compressed ? compress(f.data, 1000) : f.data));
  const volumes = new Map<number, Uint8Array>();
  const offsets: number[] = [];
  files.forEach((f, i) => {
    const v = volumes.get(f.volume) ?? cat(enc("ISc("), new Uint8Array(0x100));
    offsets.push(v.length);
    volumes.set(f.volume, cat(v, stored[i]!));
  });
  // File table: directory name offsets, then the strings, then the descriptors.
  const names = [...dirs, ...files.map((f) => f.name)];
  let strings = new Uint8Array(0);
  const strOff: number[] = [];
  const tableHead = 4 * dirs.length;
  for (const n of names) {
    strOff.push(tableHead + strings.length);
    strings = cat(strings, enc(n), new Uint8Array(1));
  }
  const descStart = tableHead + strings.length;
  const table = new Uint8Array(descStart + files.length * 0x57);
  const tv = new DataView(table.buffer);
  dirs.forEach((_, i) => tv.setUint32(4 * i, strOff[i]!, true));
  table.set(strings, tableHead);
  files.forEach((f, i) => {
    const p = descStart + i * 0x57;
    tv.setUint16(p, f.compressed ? 4 : 0, true);
    tv.setUint32(p + 2, f.data.length, true);
    tv.setUint32(p + 10, stored[i]!.length, true);
    tv.setUint32(p + 18, offsets[i]!, true);
    tv.setUint32(p + 0x3a, strOff[dirs.length + i]!, true);
    tv.setUint16(p + 0x3e, f.dir, true);
    tv.setUint16(p + 0x55, f.volume, true);
  });
  const desc = 0x200;
  const hdr = new Uint8Array(desc + 0x100 + table.length);
  const hv = new DataView(hdr.buffer);
  hdr.set(enc("ISc("));
  hv.setUint32(12, desc, true);
  hv.setUint32(desc + 0x0c, 0x100, true);
  hv.setUint32(desc + 0x1c, dirs.length, true);
  hv.setUint32(desc + 0x28, files.length, true);
  hv.setUint32(desc + 0x2c, descStart, true);
  hdr.set(table, desc + 0x100);
  return { hdr, volumes };
}

/** A PE stub with one section, then the installer's entry list. */
function installer(entries: [string, Uint8Array][]): Uint8Array {
  const stub = new Uint8Array(0x800);
  const sv = new DataView(stub.buffer);
  stub.set(enc("MZ"));
  sv.setUint32(0x3c, 0x80, true);
  stub.set(enc("PE\0\0"), 0x80);
  sv.setUint16(0x86, 1, true);
  sv.setUint16(0x94, 0xe0, true);
  const sec = 0x80 + 24 + 0xe0;
  sv.setUint32(sec + 16, 0x400, true); // raw size
  sv.setUint32(sec + 20, 0x400, true); // raw pointer
  const parts: Uint8Array[] = [stub];
  for (const [name, data] of entries) parts.push(enc(`${name}\0Disk1\\${name}\x000.0.0.0\0${data.length}\0`), data);
  return cat(...parts);
}

const bytes = (n: number, seed: number): Uint8Array => Uint8Array.from({ length: n }, (_, i) => (i * seed + (i >> 7)) & 0xff);

test("cabinet header: paths, sizes and which files the game keeps", () => {
  const { hdr } = cabinet(["App Executables\\data", "data\\GTAudio", "Support"], [
    { dir: 0, name: "wil.gmp", data: bytes(10, 3), compressed: false, volume: 1 },
    { dir: 1, name: "1.wav", data: bytes(10, 5), compressed: false, volume: 1 },
    { dir: 2, name: "readme.txt", data: bytes(10, 7), compressed: false, volume: 1 },
  ]);
  const files = parseCabHeader(hdr);
  assert.deepEqual(files.map((f) => f.path), ["App Executables/data/wil.gmp", "data/GTAudio/1.wav", "Support/readme.txt"]);
  assert.deepEqual(wanted(files).map((f) => f.path), ["App Executables/data/wil.gmp"]);
  assert.throws(() => parseCabHeader(new Uint8Array(64)), /not an InstallShield/);
});

test("installer streamed in small pieces: files come out whole", async () => {
  const sty = bytes(5000, 11);
  const gxt = bytes(700, 13);
  const vocal = bytes(3000, 17);
  const { hdr, volumes } = cabinet(["App Executables\\data", "App Executables\\data\\Audio\\Vocals"], [
    { dir: 0, name: "e.gxt", data: gxt, compressed: true, volume: 1 },
    { dir: 0, name: "wil.sty", data: sty, compressed: true, volume: 2 },
    { dir: 1, name: "wasted.wav", data: vocal, compressed: false, volume: 2 },
  ]);
  // The real installer puts data1.cab before data1.hdr, then data2.cab.
  const exe = installer([["autorun.inf", enc("x")], ["data1.cab", volumes.get(1)!], ["data1.hdr", hdr], ["data2.cab", volumes.get(2)!], ["setup.ini", enc("[x]")]]);
  for (const step of [7, 4096, exe.length]) {
    const r = new InstallerReader();
    for (let o = 0; o < exe.length; o += step) r.push(exe.subarray(o, o + step));
    const out = await r.finish();
    assert.deepEqual(out.map((f) => f.path).sort(), ["data/Audio/Vocals/wasted.wav", "data/e.gxt", "data/wil.sty"]);
    assert.deepEqual(out.find((f) => f.path === "data/wil.sty")!.data, sty);
    assert.deepEqual(out.find((f) => f.path === "data/e.gxt")!.data, gxt);
    assert.deepEqual(out.find((f) => f.path === "data/Audio/Vocals/wasted.wav")!.data, vocal);
  }
});

test("installer cut short or not an installer", async () => {
  const { hdr, volumes } = cabinet(["data"], [{ dir: 0, name: "e.gxt", data: bytes(100, 3), compressed: true, volume: 1 }]);
  const exe = installer([["data1.hdr", hdr], ["data1.cab", volumes.get(1)!]]);
  const r = new InstallerReader();
  r.push(exe.subarray(0, exe.length - 10));
  await assert.rejects(r.finish(), /ended early/);
  assert.throws(() => new InstallerReader().push(new Uint8Array(0x400)), /not a Windows installer/);
});
