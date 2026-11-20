import assert from "node:assert/strict";
import { test } from "node:test";
import { kindOf, parseAsset, parseMmp, sha256Hex } from "../src/assets/kinds.ts";
import type { AssetRecord } from "../src/assets/protocol.ts";
import { listMaps } from "../src/assets/store.ts";

function container(magic: string, version: number, chunks: [string, number][]): ArrayBuffer {
  const size = 6 + chunks.reduce((n, [, s]) => n + 8 + s, 0);
  const b = new Uint8Array(size);
  const dv = new DataView(b.buffer);
  b.set([...magic].map((c) => c.charCodeAt(0)), 0);
  dv.setUint16(4, version, true);
  let o = 6;
  for (const [t, s] of chunks) {
    b.set([...t].map((c) => c.charCodeAt(0)), o);
    dv.setUint32(o + 4, s, true);
    o += 8 + s;
  }
  return b.buffer;
}

test("kinds by extension, case-insensitive", () => {
  assert.equal(kindOf("data/WIL.GMP"), "gmp");
  assert.equal(kindOf("MP1-6P.scr"), "scr");
  assert.equal(kindOf("gta2.exe"), null);
  assert.equal(kindOf("README"), null);
});

test("chunked containers: header and chunk index", () => {
  const ok = parseAsset("gmp", container("GBMP", 500, [["UMAP", 16], ["ZONE", 4]]));
  assert.equal(ok.ok, true);
  assert.equal(ok.version, 500);
  assert.deepEqual(ok.chunks!.map((c) => c.type), ["UMAP", "ZONE"]);
  assert.equal(parseAsset("sty", container("GBMP", 500, [])).ok, false, "wrong magic");
  const truncated = container("GBST", 700, [["TILE", 32]]).slice(0, 20);
  assert.match(parseAsset("sty", truncated).error!, /overruns/);
});

test("mmp parsing", () => {
  const r = parseMmp("[MapFiles]\r\nGMPFile = MP1-comp.gmp\r\nSTYFile = bil.sty\r\nSCRFile = MP1-6P.scr\r\nDescription = Tiny Town");
  assert.deepEqual(r.map, { description: "Tiny Town", gmp: "MP1-comp.gmp", sty: "bil.sty", scr: "MP1-6P.scr" });
  assert.equal(parseMmp("[MapFiles]\nDescription = x").ok, false);
});

test("sha256", async () => {
  assert.equal(await sha256Hex(new TextEncoder().encode("abc").buffer as ArrayBuffer), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
});

const rec = (path: string, kind: AssetRecord["kind"], info: AssetRecord["info"] = { ok: true }): AssetRecord => ({
  path, name: path.split("/").pop()!.toLowerCase(), kind, size: 1, hash: path, info, importedAt: 0,
});

test("maps come from .mmp files whose gmp and sty are present (names case-insensitive)", () => {
  const files = [
    rec("data/mp1-comp.gmp", "gmp"),
    rec("data/bil.sty", "sty"),
    rec("data/mp1-6p.scr", "scr"),
    rec("data/mp1-6p.mmp", "mmp", { ok: true, map: { description: "Tiny Town", gmp: "MP1-comp.gmp", sty: "bil.sty", scr: "MP1-6P.scr" } }),
    rec("data/mp2.mmp", "mmp", { ok: true, map: { description: "Missing", gmp: "mp2.gmp", sty: "bil.sty", scr: null } }),
  ];
  const maps = listMaps(files);
  assert.equal(maps.length, 1);
  assert.equal(maps[0]!.description, "Tiny Town");
  assert.equal(maps[0]!.scrRecord?.name, "mp1-6p.scr");
});

test("without .mmp files, gmp/sty pairs with the same base name are offered", () => {
  const maps = listMaps([rec("wil.gmp", "gmp"), rec("wil.sty", "sty"), rec("ste.gmp", "gmp")]);
  assert.deepEqual(maps.map((m) => m.description), ["wil"]);
});
