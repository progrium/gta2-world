import assert from "node:assert/strict";
import { test } from "node:test";
import { FixedLoop, MAX_CATCHUP_TICKS, TICK_MS } from "../src/loop.ts";
import { FIXED_SESSION_ID, sessionIdFromUrl } from "../src/session.ts";

test("fixed loop: 30 Hz ticks from 60 Hz frames, input polled before ticks, catch-up capped", () => {
  const log: string[] = [];
  const loop = new FixedLoop({ frame: () => log.push("f"), tick: (t) => log.push(`t${t}`), render: () => log.push("r") });
  for (let i = 0; i <= 6; i++) loop.advance(i * (1000 / 60));
  assert.equal(loop.tick, 3);
  assert.deepEqual(log.slice(0, 7), ["f", "r", "f", "r", "f", "t0", "r"]);
  const n = loop.advance(6 * (1000 / 60) + 10_000);
  assert.equal(n, MAX_CATCHUP_TICKS);
  assert.ok(TICK_MS > 33 && TICK_MS < 34);
});

test("session id: fixed unless the link names one", () => {
  assert.equal(sessionIdFromUrl("https://x.test/"), FIXED_SESSION_ID);
  assert.equal(sessionIdFromUrl("https://x.test/#s=abc_1"), "abc_1");
  assert.equal(sessionIdFromUrl("https://x.test/?s=../../etc"), FIXED_SESSION_ID);
});
