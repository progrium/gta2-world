import assert from "node:assert/strict";
import { test } from "node:test";
import { edgeArrow, playerColour, projectTopDown } from "../src/ui/playerArrows.ts";

const view = { eye: [10, 20, 9] as [number, number, number], target: [10, 20, 2] as [number, number, number], up: [0, -1, 0] as [number, number, number], fovY: Math.PI / 2 };

test("top-down projection: centre, then one screen-half per eye height", () => {
  assert.deepEqual(projectTopDown(view, 10, 20, 2, 800, 600), { x: 400, y: 300 });
  // fovY 90°, eye 7 above: the screen's half height covers 7 blocks.
  const p = projectTopDown(view, 17, 13, 2, 800, 600);
  assert.ok(Math.abs(p.x - 700) < 1e-9 && Math.abs(p.y - 0) < 1e-9);
});

test("edge arrow: none on screen, clamped to the inset edge off it", () => {
  assert.equal(edgeArrow(400, 300, 800, 600, 20), null);
  assert.equal(edgeArrow(0, 600, 800, 600, 20), null);
  const r = edgeArrow(2000, 300, 800, 600, 20)!;
  assert.deepEqual([r.x, r.y, r.angle], [780, 300, 0]);
  const u = edgeArrow(400, -1000, 800, 600, 20)!;
  assert.deepEqual([u.x, u.y], [400, 20]);
  assert.ok(Math.abs(u.angle + Math.PI / 2) < 1e-9);
  // Down-left corner direction hits the bottom edge first on a wide screen.
  const c = edgeArrow(-600, 1300, 800, 600, 20)!;
  assert.ok(Math.abs(c.y - 580) < 1e-9 && c.x > 20 && c.x < 400);
});

test("each slot has its own colour", () => {
  assert.equal(new Set(Array.from({ length: 16 }, (_, i) => playerColour(i))).size, 16);
});
