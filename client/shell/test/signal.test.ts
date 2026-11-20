import assert from "node:assert/strict";
import { test } from "node:test";
import { BcSignaller } from "../src/net/signal-bc.ts";
import { joinHash, parseJoinHash } from "../src/net/signal.ts";
import { newRoom, signalSetting } from "../src/net/signaller.ts";

const wait = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

test("room names fit the join link", () => {
  for (let i = 0; i < 50; i++) {
    const room = newRoom();
    const h = joinHash(room, "ab".repeat(32));
    assert.deepEqual(parseJoinHash(h), { room, mapHash12: "abababababab" });
  }
});

test("?signal= picks the signaller; bc or nothing means BroadcastChannel", () => {
  assert.equal(signalSetting(""), null);
  assert.equal(signalSetting("?signal=bc"), null);
  assert.equal(signalSetting("?signal=wss://sig.example/r"), "wss://sig.example/r");
});

test("BroadcastChannel signalling: a peer that arrives before the host is heard once the host opens", async () => {
  const room = newRoom();
  const peer = BcSignaller.peer(room);
  const fromHost: unknown[] = [];
  peer.onMessage = (from, m) => fromHost.push([from, m]);
  peer.send("host", { kind: "offer", sdp: "v=0 test" }); // queued: no host yet
  await wait(50);
  const host = BcSignaller.host(room);
  const seen: unknown[] = [];
  const joined: string[] = [];
  host.onPeer = (p) => joined.push(p);
  host.onMessage = (from, m) => {
    seen.push([from, m]);
    host.send(from, { kind: "answer", sdp: "v=0 answer" });
  };
  await wait(700);
  assert.deepEqual(joined, [peer.id]);
  assert.deepEqual(seen, [[peer.id, { kind: "offer", sdp: "v=0 test" }]]);
  assert.deepEqual(fromHost, [["host", { kind: "answer", sdp: "v=0 answer" }]]);
  const left: string[] = [];
  host.onPeerLeft = (p) => left.push(p);
  let closedWith = "";
  const peer2 = BcSignaller.peer(room);
  peer2.onClose = (r) => (closedWith = r);
  await wait(100);
  peer.close();
  await wait(50);
  assert.deepEqual(left, [peer.id]);
  host.close();
  await wait(50);
  assert.match(closedWith, /closed the room/);
  peer2.close();
});
