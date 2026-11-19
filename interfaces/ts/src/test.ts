// Cross-language conformance: decode every Zig-generated vector, check the
// fields, re-encode, and require byte equality. Run: npm test
import { readFileSync } from "node:fs";
import * as I from "./index.js";

let failures = 0;
function check(name: string, cond: boolean, msg = ""): void {
  if (!cond) { failures++; console.error(`FAIL ${name} ${msg}`); }
}
const hex = (b: Uint8Array): string => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
const unhex = (s: string): Uint8Array => new Uint8Array(s.match(/../g)!.map((h) => parseInt(h, 16)));

const vectors = new Map<string, Uint8Array>();
for (const line of readFileSync(new URL("../../testdata/vectors.txt", import.meta.url), "utf8").split("\n")) {
  const [k, v] = line.trim().split(" ");
  if (k && v) vectors.set(k, unhex(v));
}
const vec = (k: string): Uint8Array => { const v = vectors.get(k); if (!v) throw new Error("missing vector " + k); return v; };
function same(name: string, w: I.Writer): void {
  const got = hex(w.finish()), want = hex(vec(name));
  check(name, got === want, `re-encode\n got  ${got}\n want ${want}`);
}

// frame
{
  const b = vec("frame");
  const f = I.decodeFrame(new DataView(b.buffer));
  check("frame", f.steer === -100 && f.throttle === 127 && f.buttons === (I.Button.fire | I.Button.direct) && f.aim === 0x4000 && f.seq === 0x1234);
  const w = new I.Writer(8); w.frame(f); same("frame", w);
}
// hello
{
  const m = I.decodeHello(new I.Reader(vec("hello")));
  check("hello", m.layoutHash === 0x0123456789abcdefn && m.names.join(",") === "jeff,p2" && m.mapHash[31] === 31 && m.transport === I.Transport.webtransport);
  const w = new I.Writer(); I.encodeHello(w, m); same("hello", w);
}
// welcome
{
  const m = I.decodeWelcome(new I.Reader(vec("welcome")));
  check("welcome", m.clientId === 42 && m.serverTick === 90000 && m.configName === "dm16" && m.slots.join() === "3,4" && m.snapshotHz === 20 && m.redundancy === 8);
  const w = new I.Writer(); I.encodeWelcome(w, m); same("welcome", w);
}
// stream framing + reject
{
  const { bodies, used } = I.readStreamFrames(vec("stream_reject"));
  check("stream_reject", bodies.length === 1 && used === vec("stream_reject").length);
  const m = I.decodeReject(new I.Reader(bodies[0]));
  check("stream_reject", m.code === I.RejectCode.mapMismatch && m.message === "map differs");
  const w = new I.Writer(); I.encodeReject(w, m);
  check("stream_reject", hex(I.streamFrame(w.finish())) === hex(vec("stream_reject")), "frame");
  // partial frame yields nothing
  check("stream_partial", I.readStreamFrames(vec("stream_reject").subarray(0, 5)).bodies.length === 0);
}
// input
{
  const m = I.decodeInput(new I.Reader(vec("input")));
  check("input", m.ackSeq === 700 && m.ackBits === 0x8000000f && m.players.length === 2);
  check("input", m.players[0].newestTick === 65537 && m.players[0].frames.length === 3 && m.players[0].frames[0].seq === 0xffff && m.players[0].frames[2].steer === -127);
  check("input", m.players[1].frames[0].aim === 49152);
  const w = new I.Writer(); I.encodeInput(w, m); same("input", w);
}
// snapshot
{
  const r = new I.Reader(vec("snapshot"));
  const { header, baseline } = I.decodeSnapshotHeader(r);
  check("snapshot", !baseline && header.seq === 701 && header.tick === 65530 && header.players[0].inputAck === 65536 && header.players[0].slackQ === 7);
  const w = new I.Writer(); I.encodeSnapshotHeader(w, header);
  let prev: number | null = null;
  const seen: string[] = [];
  const carBase = { x: 120 * I.FX_ONE, y: 80 * I.FX_ONE, z: 2 * I.FX_ONE, heading: 1000 };
  while (!r.done()) {
    const h = I.decodeRecordHeader(r, prev);
    I.encodeRecordHeader(w, prev, h);
    prev = h.handle;
    const kind = h.handle >> 12;
    if (h.op === I.RecordOp.remove) { seen.push(`remove:${kind}:${h.handle & 0xfff}`); continue; }
    if (kind === I.Kind.playerRow) {
      const row = I.decodeComponent(r, I.PlayerRowSchema, null);
      check("snapshot.row", row.score === 5000 && row.kills === 5 && row.car === I.ENTITY_NONE && I.entityId.gen(row.ped) === 7);
      I.encodeComponent(w, I.PlayerRowSchema, null, row);
      seen.push(`row:${h.handle & 0xfff}`);
    } else {
      const base = h.op === I.RecordOp.update ? carBase : null;
      const t = I.decodeComponent(r, I.TransformSchema, base);
      if (h.op === I.RecordOp.update) check("snapshot.car", h.baseAge === 3 && t.x === 120 * I.FX_ONE + 30000 && t.y === 80 * I.FX_ONE - 500 && t.heading === 64000);
      else check("snapshot.ped", h.generation === 7 && t.heading === 16384 && t.x === 121 * I.FX_ONE);
      I.encodeComponent(w, I.TransformSchema, base, t);
      seen.push(`${h.op === I.RecordOp.update ? "update" : "create"}:${kind}:${h.handle & 0xfff}`);
    }
  }
  check("snapshot.records", seen.join(" ") === "update:0:2 create:1:3 remove:2:16 row:3", seen.join(" "));
  same("snapshot", w);
}
// event, chat, player_info
{
  const e = I.decodeEvent(new I.Reader(vec("event")));
  check("event", e.kind === I.EventKind.explosion && e.a === 12 && e.x === 120 * I.FX_ONE && e.y === -3);
  const w = new I.Writer(); I.encodeEvent(w, e); same("event", w);
  const c = I.decodeChat(new I.Reader(vec("chat_from")));
  check("chat_from", c.slot === 5 && c.text === "gg ✓");
  const w2 = new I.Writer(); I.encodeChat(w2, c, true); same("chat_from", w2);
  const p = I.decodePlayerInfo(new I.Reader(vec("player_info")));
  check("player_info", p.name === "zaibatsu" && p.flags === I.PlayerInfoFlag.present);
  const w3 = new I.Writer(); I.encodePlayerInfo(w3, p); same("player_info", w3);
}
// svarints
{
  const vals = [0, -1, 1, 63, -64, 64, 300, -300, 2147483647, -2147483648];
  const r = new I.Reader(vec("svarints"));
  check("svarints", vals.every((v) => r.svarint() === v) && r.done());
  const w = new I.Writer(); for (const v of vals) w.svarint(v); same("svarints", w);
}
// I2 helpers
{
  check("expandSeq", I.expandSeq(I.seqOf(70000), 69990) === 70000 && I.expandSeq(0xffff, 65540) === 65535 && I.expandSeq(0, 5) === 0);
  check("quantize", I.quantizeAxis(0.5) === 64 && I.quantizeAxis(-0.5) === -64 && I.quantizeAxis(2) === 127 && I.quantizeAxis(NaN) === 0);
  check("angle", I.angleFromVector(1, 0) === 0 && I.angleFromVector(0, 1) === 16384 && I.angleFromVector(-1, 0) === 32768);
  const s = I.sanitizeFrame({ steer: -128, throttle: 0, buttons: 0xff01, aim: 77, seq: 3 });
  check("sanitize", s.steer === -127 && s.buttons === 1 && s.aim === 0);
}

if (failures) { console.error(`${failures} check(s) failed`); throw new Error("conformance failed"); }
console.log(`ok: ${vectors.size} vectors decoded, re-encoded byte for byte`);
