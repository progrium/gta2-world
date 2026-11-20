import assert from "node:assert/strict";
import { test } from "node:test";
import { ChaseCamera } from "../../render/ts/src/camera.ts";
import { parseSeq } from "../src/assets/kinds.ts";
import type { AssetRecord } from "../src/assets/protocol.ts";
import { levelScripts, listLevels, listMaps } from "../src/assets/store.ts";
import { arrowAngle, deathKey, fillText, formatPoints, formatTimer, parseGameText, truncateSpans } from "../src/game/text.ts";

const rec = (path: string, kind: AssetRecord["kind"], info: AssetRecord["info"] = { ok: true }): AssetRecord => ({
  path,
  name: path.toLowerCase().split("/").pop()!,
  kind,
  size: 1,
  hash: path,
  info,
  importedAt: 0,
});

// A made-up level list in the .seq form (not the game's own file).
const SEQ = `MainOrBonus = MAIN
GMPFile = town.gmp
STYFile = town.sty
SCRFile = town.scr
Description = Area One

MainOrBonus = BONUS
GMPFile = extra.gmp
STYFile = town.sty
SCRFile = extra.scr
Description = Area One Bonus
`;

test(".seq lists main areas and bonus stages in order", () => {
  const p = parseSeq(SEQ);
  assert.ok(p.ok);
  assert.deepEqual(p.levels, [
    { description: "Area One", gmp: "town.gmp", sty: "town.sty", scr: "town.scr", bonus: false },
    { description: "Area One Bonus", gmp: "extra.gmp", sty: "town.sty", scr: "extra.scr", bonus: true },
  ]);
  assert.equal(parseSeq("nothing here").ok, false);
});

test("levels need their map, style and script; mission sub-scripts come from the level's folder", () => {
  const files = [
    rec("data/test.seq", "seq", parseSeq(SEQ)),
    rec("data/town.gmp", "gmp"),
    rec("data/town.sty", "sty"),
    rec("data/town.scr", "scr"),
    rec("data/town/town_j1.scr", "scr"),
    rec("data/town/town_j2.scr", "scr"),
    rec("data/other/other_j1.scr", "scr"),
    rec("data/extra.gmp", "gmp"),
  ];
  const levels = listLevels(files);
  assert.deepEqual(levels.map((l) => l.description), ["Area One"]);
  assert.deepEqual(levels[0]!.story, { bonus: false, index: 0 });
  assert.deepEqual(levelScripts(files, levels[0]!).map((f) => f.name), ["town.scr", "town_j1.scr", "town_j2.scr"]);
  // With the bonus script too, both are listed; deathmatch maps are separate.
  const more = listLevels([...files, rec("data/extra.scr", "scr")]);
  assert.deepEqual(more.map((l) => [l.description, l.story?.bonus]), [["Area One", false], ["Area One Bonus", true]]);
  assert.equal(listMaps(files).every((m) => !m.story), true);
});

test("without a .seq, a map with same-named style and script is a level", () => {
  const files = [rec("a.gmp", "gmp"), rec("a.sty", "sty"), rec("a.scr", "scr"), rec("b.gmp", "gmp"), rec("b.sty", "sty")];
  assert.deepEqual(listLevels(files).map((l) => l.gmp), ["a.gmp"]);
});

test("game text markup: highlights, portrait marker, typing out", () => {
  const t = parseGameText(String.fromCharCode(0x2179) + "Go to #the bank# now");
  assert.equal(t.portrait, "y");
  assert.equal(t.plain, "Go to the bank now");
  assert.deepEqual(t.spans, [
    { text: "Go to ", hi: false },
    { text: "the bank", hi: true },
    { text: " now", hi: false },
  ]);
  assert.deepEqual(truncateSpans(t.spans, 8), [
    { text: "Go to ", hi: false },
    { text: "th", hi: true },
  ]);
  assert.equal(parseGameText("plain").portrait, null);
  assert.equal(fillText("Target Score: %d", 1000000), "Target Score: 1,000,000");
  assert.equal(fillText("%s Jobs: %d/%d", "Gang", 3, 9), "Gang Jobs: 3/9");
});

test("HUD numbers: timer rounds up, points grouped, death messages by cause", () => {
  assert.equal(formatTimer(0), "0:00");
  assert.equal(formatTimer(1), "0:01");
  assert.equal(formatTimer(30 * 75), "1:15");
  assert.equal(formatPoints(1234567), "1,234,567");
  assert.equal(deathKey(0x81), "fried");
  assert.equal(deathKey(7), "shocked");
  assert.equal(deathKey(0), "wasted");
  assert.equal(deathKey(0x80), "wasted");
  // North is up: a target due south points down the screen.
  assert.ok(Math.abs(arrowAngle(0, 0, 0, 5) - Math.PI / 2) < 1e-9);
});

test("camera: dead pulls back, suspicion shortens the lead", () => {
  const settle = (cam: ChaseCamera, t: Parameters<ChaseCamera["update"]>[0]): ReturnType<ChaseCamera["view"]> => {
    for (let i = 0; i < 400; i++) cam.update(t, 1 / 30);
    return cam.view();
  };
  const dead = settle(new ChaseCamera(), { x: 10, y: 10, z: 2, dead: true });
  const alive = settle(new ChaseCamera(), { x: 10, y: 10, z: 2 });
  assert.ok(dead.eye[2] - alive.eye[2] > 15, `dead ${dead.eye[2]} alive ${alive.eye[2]}`);
  const car = { x: 10, y: 10, z: 2, vx: 0.2, vy: 0, inCar: true };
  const calm = settle(new ChaseCamera(), car);
  const chasedCam = new ChaseCamera();
  const chased = settle(chasedCam, { ...car, chased: true });
  assert.equal(chasedCam.suspicion, 80);
  const leadCalm = calm.target[0] - 10;
  const leadChased = chased.target[0] - 10;
  assert.ok(leadCalm > 0 && Math.abs(leadChased - leadCalm / 2) < 1e-6, `lead ${leadCalm} chased ${leadChased}`);
  const up = settle(new ChaseCamera(), { x: 10, y: 10, z: 2, elevation: 4 });
  assert.ok(Math.abs(up.eye[2] - alive.eye[2] - 4) < 1e-6);
});
