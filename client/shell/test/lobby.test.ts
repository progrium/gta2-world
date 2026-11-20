import assert from "node:assert/strict";
import { test } from "node:test";
import {
  Assembler,
  CHUNK,
  type FileInfo,
  Limiter,
  chunks,
  decodeChunk,
  encodeChunk,
  parseLobbyMsg,
  safeName,
  sha256Hex,
} from "../src/lobby/files.ts";
import { type FileChannel, type HostFiles, type JoinStore, LobbyHost, LobbyJoin } from "../src/lobby/lobby.ts";

// Random bytes stand in for files; no game data is used.
const randomBytes = (n: number): Uint8Array => {
  const b = new Uint8Array(n);
  for (let o = 0; o < n; o += 65536) crypto.getRandomValues(b.subarray(o, Math.min(n, o + 65536)));
  return b;
};

async function fakeFile(name: string, kind: FileInfo["kind"], size: number): Promise<{ info: FileInfo; data: Uint8Array }> {
  const data = randomBytes(size);
  return { info: { name, kind, size, sha256: await sha256Hex(data) }, data };
}

test("chunk framing round-trips the id and bytes", () => {
  const b = Uint8Array.from([1, 2, 3, 250]);
  const c = decodeChunk(encodeChunk(0xdeadbeef, b))!;
  assert.equal(c.id, 0xdeadbeef);
  assert.deepEqual([...c.bytes], [1, 2, 3, 250]);
  assert.equal(decodeChunk(new Uint8Array(3)), null);
});

test("files split into 16 KB chunks and reassemble with a SHA-256 check", async () => {
  const { info, data } = await fakeFile("test.sty", "sty", CHUNK * 3 + 123);
  const parts = [...chunks(7, data)];
  assert.equal(parts.length, 4);
  assert.deepEqual(parts.map((p) => p.length - 4), [CHUNK, CHUNK, CHUNK, 123]);
  const a = new Assembler(info);
  for (const p of parts) {
    const c = decodeChunk(p)!;
    assert.equal(c.id, 7);
    a.add(c.bytes);
  }
  assert.deepEqual(await a.finish(), data);
});

test("reassembly rejects a changed byte, a short file and extra data", async () => {
  const { info, data } = await fakeFile("test.gmp", "gmp", 40000);
  const bad = data.slice();
  bad[20000]! ^= 1;
  const a = new Assembler(info);
  for (const p of chunks(1, bad)) a.add(decodeChunk(p)!.bytes);
  await assert.rejects(a.finish(), /SHA-256 mismatch/);

  const short = new Assembler(info);
  short.add(data.subarray(0, 1000));
  await assert.rejects(short.finish(), /got 1000 of 40000/);

  const extra = new Assembler({ ...info, size: 10 });
  extra.add(data.subarray(0, 11));
  await assert.rejects(extra.finish(), /more data/);

  const big = new Assembler({ ...info, size: CHUNK * 2 });
  big.add(new Uint8Array(CHUNK + 1));
  await assert.rejects(big.finish(), /chunk too large/);
});

test("lobby messages are validated", () => {
  const sha = "a".repeat(64);
  assert.deepEqual(parseLobbyMsg(JSON.stringify({ t: "want", map: "0123456789ab" })), { t: "want", map: "0123456789ab" });
  assert.equal(parseLobbyMsg(JSON.stringify({ t: "want", map: "xyz" })), null);
  assert.equal(parseLobbyMsg("not json"), null);
  assert.equal(parseLobbyMsg(JSON.stringify({ t: "get", files: ["short"] })), null);
  assert.ok(parseLobbyMsg(JSON.stringify({ t: "file", id: 1, name: "wil.gmp", kind: "gmp", size: 5, sha256: sha })));
  assert.equal(parseLobbyMsg(JSON.stringify({ t: "file", id: 1, name: "wil.gmp", kind: "gmp", size: -1, sha256: sha })), null);
  assert.equal(parseLobbyMsg(JSON.stringify({ t: "match", description: "x", share: true, files: [{ name: "../x.gmp", kind: "gmp", size: 1, sha256: sha }] })), null);
  assert.equal(safeName("WIL.GMP", "gmp"), "wil.gmp");
  assert.equal(safeName("data/wil.gmp", "gmp"), null);
  assert.equal(safeName("wil.exe", "gmp"), null);
  assert.equal(safeName("wil.gmp", "exe"), null);
  assert.equal(safeName(".gmp", "gmp"), null);
});

test("limiter runs at most n tasks at once, in order", async () => {
  const l = new Limiter(2);
  let running = 0;
  let peak = 0;
  const order: number[] = [];
  await Promise.all(
    [0, 1, 2, 3, 4].map((i) =>
      l.run(async () => {
        running++;
        peak = Math.max(peak, running);
        order.push(i);
        await new Promise((r) => setTimeout(r, 5));
        running--;
      }),
    ),
  );
  assert.equal(peak, 2);
  assert.deepEqual(order, [0, 1, 2, 3, 4]);
});

// --- host <-> joiner over an in-memory channel pair -------------------------

function pair(): [FileChannel, FileChannel] {
  const mk = (): FileChannel & { peer?: FileChannel } => ({ send: () => {}, bufferedAmount: () => 0, onMessage: null });
  const a = mk();
  const b = mk();
  const deliver = (to: FileChannel, d: string | Uint8Array): void => {
    const copy = typeof d === "string" ? d : d.slice();
    setTimeout(() => to.onMessage?.(copy), 0);
  };
  a.send = (d) => deliver(b, d);
  b.send = (d) => deliver(a, d);
  return [a, b];
}

async function setup(opts: { share: boolean; have?: string[]; corrupt?: boolean; peers?: number }) {
  const gmp = await fakeFile("test.gmp", "gmp", 70000);
  const sty = await fakeFile("test.sty", "sty", 50001);
  const all = [gmp, sty];
  const limiter = new Limiter(2);
  let peak = 0;
  const files: HostFiles = {
    mapHash: gmp.info.sha256,
    description: "Test map",
    files: all.map((f) => f.info),
    share: () => opts.share,
    read: async (sha) => {
      peak = Math.max(peak, limiter.active);
      const f = all.find((x) => x.info.sha256 === sha)!;
      const d = f.data.slice();
      if (opts.corrupt) d[5]! ^= 0xff;
      return d;
    },
  };
  const joins = [];
  for (let i = 0; i < (opts.peers ?? 1); i++) {
    const [h, j] = pair();
    const host = new LobbyHost(h, files, limiter);
    const saved = new Map<string, Uint8Array>();
    const store: JoinStore = {
      has: (sha) => (opts.have ?? []).includes(sha) || saved.has(sha),
      save: async (info, bytes) => void saved.set(info.sha256, bytes.slice()),
    };
    joins.push({ host, join: new LobbyJoin(j, store), saved });
  }
  return { gmp, sty, joins, peak: () => peak };
}

test("lobby: sharing on, missing files are sent, verified and saved", async () => {
  const s = await setup({ share: true, peers: 3 });
  const progress: number[] = [];
  s.joins[0]!.join.onProgress = (p) => progress.push(p.received);
  const results = await Promise.all(s.joins.map((j) => j.join.run(s.gmp.info.sha256.slice(0, 12))));
  for (const [i, r] of results.entries()) {
    assert.equal(r.description, "Test map");
    assert.equal(r.downloaded.length, 2);
    assert.deepEqual(s.joins[i]!.saved.get(s.gmp.info.sha256), s.gmp.data);
    assert.deepEqual(s.joins[i]!.saved.get(s.sty.info.sha256), s.sty.data);
  }
  assert.ok(progress.length >= 8, "progress per chunk");
  assert.ok(s.peak() <= 2, `at most 2 transfers at once on the host, saw ${s.peak()}`);
  await new Promise((r) => setTimeout(r, 10));
  assert.equal(s.joins[0]!.host.state, "ready");
});

test("lobby: files already present are not sent", async () => {
  const s2 = await setup({ share: false });
  const [h, j] = pair();
  const files: HostFiles = {
    mapHash: s2.gmp.info.sha256, description: "d", files: [s2.gmp.info, s2.sty.info], share: () => false,
    read: async () => assert.fail("nothing should be read"),
  };
  new LobbyHost(h, files, new Limiter(2));
  const r = await new LobbyJoin(j, { has: () => true, save: async () => assert.fail("nothing to save") }).run(s2.gmp.info.sha256.slice(0, 12));
  assert.equal(r.downloaded.length, 0);
});

test("lobby: sharing off names the missing file", async () => {
  const s = await setup({ share: false });
  const j = s.joins[0]!;
  await assert.rejects(j.join.run(s.gmp.info.sha256.slice(0, 12)), /not sharing.*test\.gmp and test\.sty/);
  assert.equal(j.saved.size, 0);
});

test("lobby: sharing off, only the style missing", async () => {
  const s = await setup({ share: false, have: [] });
  const [h, jc] = pair();
  new LobbyHost(h, { mapHash: s.gmp.info.sha256, description: "d", files: [s.gmp.info, s.sty.info], share: () => false, read: async () => new Uint8Array() }, new Limiter(2));
  const join = new LobbyJoin(jc, { has: (sha) => sha === s.gmp.info.sha256, save: async () => {} });
  await assert.rejects(join.run(s.gmp.info.sha256.slice(0, 12)), (e: Error) => e.message.includes("test.sty") && !e.message.includes("test.gmp"));
});

test("lobby: a corrupted transfer fails the SHA-256 check and is not saved", async () => {
  const s = await setup({ share: true, corrupt: true });
  const j = s.joins[0]!;
  await assert.rejects(j.join.run(s.gmp.info.sha256.slice(0, 12)), /SHA-256 mismatch/);
  assert.equal(j.saved.size, 0);
});

test("lobby: a link for another map gets a clear error", async () => {
  const s = await setup({ share: true });
  await assert.rejects(s.joins[0]!.join.run("000000000000"), /no longer playing the map/);
});
