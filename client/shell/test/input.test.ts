import assert from "node:assert/strict";
import { test } from "node:test";
import { defaultPadBindings, readPadSource, Std } from "../src/input/bindings.ts";
import { composeFrame } from "../src/input/compose.ts";
import { normalizeControllerId, padFamily } from "../src/input/controllerId.ts";
import { GamepadManager, type MinimalGamepad } from "../src/input/gamepad.ts";
import { Button } from "../src/input/i2.ts";
import { KeyboardDevice } from "../src/input/keyboard.ts";
import { TickLatch } from "../src/input/latch.ts";
import { type KV, RemapStore } from "../src/input/remapStore.ts";
import { emptySample, mergeSamples } from "../src/input/sample.ts";
import { InputSystem } from "../src/input/system.ts";

class MemKV implements KV {
  m = new Map<string, string>();
  getItem(k: string) { return this.m.get(k) ?? null; }
  setItem(k: string, v: string) { this.m.set(k, v); }
  removeItem(k: string) { this.m.delete(k); }
}

test("controller ids normalise across browsers (S6 gap 9)", () => {
  const chrome = normalizeControllerId("Xbox Wireless Controller (STANDARD GAMEPAD Vendor: 045e Product: 0b13)");
  const firefox = normalizeControllerId("45e-b13-Xbox Wireless Controller");
  const safari = normalizeControllerId("Xbox Wireless Controller Extended Gamepad");
  assert.equal(chrome.key, "045e:0b13");
  assert.equal(firefox.key, "045e:0b13");
  assert.equal(chrome.name, "Xbox Wireless Controller");
  assert.equal(firefox.name, "Xbox Wireless Controller");
  assert.equal(safari.key, "name:xbox wireless controller");
  const macChrome = normalizeControllerId("DualSense Wireless Controller (STANDARD GAMEPAD)");
  assert.equal(macChrome.key, "name:dualsense wireless controller");
  assert.equal(macChrome.name, "DualSense Wireless Controller");
  assert.equal(padFamily(macChrome), "playstation");
  // Safari 27 on macOS, same pad: same key as Chrome on macOS, so remaps carry over.
  assert.equal(normalizeControllerId("DualSense Wireless Controller Extended Gamepad").key, macChrome.key);
  const xinput = normalizeControllerId("Xbox 360 Controller (XInput STANDARD GAMEPAD)");
  assert.equal(xinput.key, "name:xbox 360 controller");
  assert.equal(padFamily(chrome), "xbox");
  assert.equal(padFamily(normalizeControllerId("054c-0ce6-DualSense Wireless Controller")), "playstation");
  assert.equal(padFamily(normalizeControllerId("Pro Controller (STANDARD GAMEPAD Vendor: 057e Product: 2009)")), "nintendo");
});

test("remaps saved under vid:pid are found by Safari's name-only key", () => {
  const store = new RemapStore(new MemKV());
  const chrome = normalizeControllerId("Xbox Wireless Controller (STANDARD GAMEPAD Vendor: 045e Product: 0b13)");
  const b = defaultPadBindings();
  b.actions.fire = [{ t: "b", i: Std.RB }];
  store.savePad(chrome, b);
  const safari = store.pad(normalizeControllerId("Xbox Wireless Controller"), "standard");
  assert.equal(safari.source, "saved");
  assert.deepEqual(safari.bindings.actions.fire, [{ t: "b", i: Std.RB }]);
  assert.equal(store.pad(normalizeControllerId("Other Pad"), "").source, "default");
});

test("vehicle: steer from stick, throttle from analog triggers", () => {
  const s = { ...emptySample(), moveX: 0.5, accelerate: 0.75, brake: 0.25 };
  const f = composeFrame(s, { inVehicle: true, footScheme: "direct", lastAim: 0 }, 7);
  assert.equal(f.steer, 64); // 63.5 rounds half away from zero
  assert.equal(f.throttle, 64);
  assert.equal(f.buttons & Button.direct, 0, "direct is never set in a vehicle");
  assert.equal(f.aim, 0);
  assert.equal(f.seq, 7);
});

test("vehicle: digital trigger gives full deflection; keyboard up drives", () => {
  const ctx = { inVehicle: true, footScheme: "tank" as const, lastAim: 0 };
  assert.equal(composeFrame({ ...emptySample(), accelerate: 1 }, ctx, 0).throttle, 127);
  assert.equal(composeFrame({ ...emptySample(), moveY: -1, digitalY: -1 }, ctx, 0).throttle, 127);
  assert.equal(composeFrame({ ...emptySample(), moveY: 1, accelerate: 0.5 }, ctx, 0).throttle, 64, "stick y never brakes");
  assert.equal(composeFrame({ ...emptySample(), brake: 1 }, ctx, 0).throttle, -127);
});

test("on foot tank: steer and walk from the move vector", () => {
  const f = composeFrame({ ...emptySample(), moveX: -1, moveY: -1 }, { inVehicle: false, footScheme: "tank", lastAim: 0 }, 0);
  assert.equal(f.steer, -127);
  assert.equal(f.throttle, 127);
  assert.equal(f.buttons & Button.direct, 0);
});

test("on foot direct: aim from stick, speed from magnitude, heading kept at rest", () => {
  const ctx = { inVehicle: false, footScheme: "direct" as const, lastAim: 0 };
  const down = composeFrame({ ...emptySample(), moveX: 0, moveY: 1 }, ctx, 0);
  assert.ok(down.buttons & Button.direct);
  assert.equal(down.aim, 16384, "+y (down on screen) is a quarter turn clockwise");
  assert.equal(down.throttle, 127);
  assert.equal(down.steer, 0);
  const rest = composeFrame(emptySample(), ctx, 1);
  assert.equal(rest.throttle, 0);
  assert.equal(rest.aim, 16384, "keeps facing the last direction");
  const half = composeFrame({ ...emptySample(), moveX: -0.5 }, ctx, 2);
  assert.equal(half.aim, 32768);
  assert.equal(half.throttle, 64);
});

test("on foot the accelerate trigger also fires", () => {
  const f = composeFrame({ ...emptySample(), accelerate: 0.9 }, { inVehicle: false, footScheme: "direct", lastAim: 0 }, 0);
  assert.ok(f.buttons & Button.fire);
  const g = composeFrame({ ...emptySample(), accelerate: 0.9 }, { inVehicle: true, footScheme: "direct", lastAim: 0 }, 0);
  assert.equal(g.buttons & Button.fire, 0);
});

test("latch ORs taps between ticks, then clears", () => {
  const l = new TickLatch();
  const ctx = { inVehicle: true, footScheme: "tank" as const, lastAim: 0 };
  l.observe({ ...emptySample(), buttons: Button.enterExit });
  l.observe(emptySample()); // released before the tick
  assert.ok(l.take(ctx, 1).buttons & Button.enterExit);
  assert.equal(l.take(ctx, 2).buttons, 0, "a second frame doesn't repeat the tap");
});

test("keyboard: sub-frame tap survives, auto-repeat ignored, full deflection on diagonals", () => {
  const k = new KeyboardDevice();
  k.keyDown("Enter");
  k.keyUp("Enter");
  assert.ok(k.poll().buttons & Button.enterExit);
  assert.equal(k.poll().buttons, 0);
  k.keyDown("ArrowUp");
  k.keyDown("ArrowRight");
  k.keyDown("ArrowRight");
  const s = k.poll();
  assert.equal(s.moveX, 1);
  assert.equal(s.moveY, -1);
});

test("merge: the larger stick wins, buttons OR", () => {
  const m = mergeSamples([
    { ...emptySample(), moveX: 0.2, buttons: Button.fire },
    { ...emptySample(), moveY: -0.9, buttons: Button.run, accelerate: 0.4 },
  ]);
  assert.equal(m.moveX, 0);
  assert.equal(m.moveY, -0.9);
  assert.equal(m.buttons, Button.fire | Button.run);
  assert.equal(m.accelerate, 0.4);
});

function pad(over: Partial<MinimalGamepad> = {}): MinimalGamepad {
  return {
    index: 0,
    id: "Xbox 360 Controller (XInput STANDARD GAMEPAD)",
    mapping: "standard",
    connected: true,
    timestamp: 1,
    axes: [0, 0, 0, 0],
    buttons: Array.from({ length: 17 }, () => ({ pressed: false, value: 0 })),
    ...over,
  };
}

test("rumble: trigger effects go only to pads that list trigger-rumble (DualSense lists only dual-rumble)", async () => {
  const { rumble, rumbleSupport } = await import("../src/input/rumble.ts");
  const played: string[] = [];
  const mk = (effects: string[]) => ({ vibrationActuator: { type: "dual-rumble", effects, playEffect: (t: string) => (played.push(t), Promise.resolve("complete")) } });
  const ds = mk(["dual-rumble"]);
  assert.equal(rumbleSupport(ds), "dual");
  rumble(ds, { strong: 0, weak: 0, durationMs: 100, rightTrigger: 1 });
  assert.equal(rumbleSupport(mk(["dual-rumble", "trigger-rumble"])), "dual+trigger");
  rumble(mk(["dual-rumble", "trigger-rumble"]), { strong: 0, weak: 0, durationMs: 100, rightTrigger: 1 });
  assert.deepEqual(played, ["dual-rumble", "trigger-rumble"]);
  assert.equal(rumbleSupport({}), "none");
  // Safari 27 reports effects: null with type "dual-rumble" (S6).
  assert.equal(rumbleSupport({ vibrationActuator: { type: "dual-rumble", effects: null, playEffect: () => Promise.resolve() } }), "dual");
});

test("gamepad: radial deadzone and clamp on a square gate (S6: diagonals reach 1.22)", () => {
  let list: (MinimalGamepad | null)[] = [pad({ axes: [0.1, 0.1, 0, 0] })];
  const m = new GamepadManager(new RemapStore(new MemKV()), () => list);
  assert.deepEqual([...m.poll().values()][0]!.moveX, 0);
  list = [pad({ axes: [0.86, 0.86, 0, 0] })];
  const s = m.poll().get(0)!;
  assert.ok(Math.abs(Math.hypot(s.moveX, s.moveY) - 1) < 1e-9);
});

test("gamepad: analog triggers, threshold buttons, hot-plug events", () => {
  const events: string[] = [];
  const b = Array.from({ length: 17 }, () => ({ pressed: false, value: 0 }));
  b[Std.RT] = { pressed: true, value: 0.6 };
  b[Std.Y] = { pressed: true, value: 1 };
  let list: (MinimalGamepad | null)[] = [pad({ buttons: b })];
  const m = new GamepadManager(new RemapStore(new MemKV()), () => list);
  m.on((e) => events.push(e.type));
  const s = m.poll().get(0)!;
  assert.equal(s.accelerate, 0.6);
  assert.ok(s.buttons & Button.enterExit);
  list = [null];
  assert.equal(m.poll().size, 0);
  list = [pad({ index: 0 })];
  m.poll();
  assert.deepEqual(events, ["connected", "disconnected", "connected"]);
});

test("gamepad: untouched full-range trigger axis reads 0, not half (Firefox non-standard)", () => {
  const store = new RemapStore(new MemKV());
  let list: (MinimalGamepad | null)[] = [pad({ id: "045e-028e-Microsoft X-Box 360 pad", mapping: "", axes: [0, 0, 0, 0, 0, 0] })];
  const m = new GamepadManager(store, () => list);
  m.poll();
  const bnd = defaultPadBindings();
  bnd.actions.accelerate = [{ t: "a", i: 5, dir: 1, full: true }];
  m.setBindings(0, bnd, false);
  assert.equal(m.poll().get(0)!.accelerate, 0);
  list = [pad({ id: "045e-028e-Microsoft X-Box 360 pad", mapping: "", axes: [0, 0, 0, 0, 0, -1] })];
  assert.equal(m.poll().get(0)!.accelerate, 0);
  list = [pad({ id: "045e-028e-Microsoft X-Box 360 pad", mapping: "", axes: [0, 0, 0, 0, 0, 1] })];
  assert.equal(m.poll().get(0)!.accelerate, 1);
});

test("readPadSource: pressed digital button with value 0 counts as 1", () => {
  assert.equal(readPadSource({ t: "b", i: 0 }, [{ pressed: true, value: 0 }], []), 1);
  assert.equal(readPadSource({ t: "a", i: 0, dir: -1 }, [], [-0.5]), 0.5);
});

test("input system: pad reconnecting returns to its slot; Start joins a second local player", () => {
  const kv = new MemKV();
  let list: (MinimalGamepad | null)[] = [pad()];
  const store = new RemapStore(kv);
  const sys = new InputSystem(store, new GamepadManager(store, () => list));
  sys.padsInjected = true;
  sys.allowLocalJoin = true;
  sys.poll();
  assert.equal(sys.players[0]!.pad, 0);
  // second pad presses Start
  const start = Array.from({ length: 17 }, () => ({ pressed: false, value: 0 }));
  start[Std.Start] = { pressed: true, value: 1 };
  list = [pad(), pad({ index: 1, id: "054c-0ce6-DualSense Wireless Controller", buttons: start })];
  sys.poll();
  assert.equal(sys.players.length, 2);
  assert.equal(sys.players[1]!.pad, 1);
  // unplug both, replug in swapped order: each pad returns to its own slot
  list = [];
  sys.poll();
  list = [pad({ index: 0, id: "054c-0ce6-DualSense Wireless Controller" }), pad({ index: 1 })];
  sys.poll();
  assert.equal(sys.players[1]!.pad, 0);
  assert.equal(sys.players[0]!.pad, 1);
  const frames = sys.latch(70000);
  assert.equal(frames.length, 2);
  assert.equal(frames[0]!.seq, 70000 & 0xffff);
});

test("input system: auto scheme is direct after pad input, tank after keys", () => {
  let list: (MinimalGamepad | null)[] = [pad({ axes: [0, 1, 0, 0] })];
  const store = new RemapStore(new MemKV());
  const sys = new InputSystem(store, new GamepadManager(store, () => list));
  sys.padsInjected = true;
  sys.poll();
  let f = sys.latch(0)[0]!;
  assert.ok(f.buttons & Button.direct);
  assert.equal(f.aim, 16384);
  list = [pad()];
  sys.keyboard.keyDown("ArrowUp");
  sys.poll();
  f = sys.latch(1)[0]!;
  assert.equal(f.buttons & Button.direct, 0);
  assert.equal(f.throttle, 127);
});

test("input system: controllers can be switched off for this tab, and pause while unfocused", () => {
  const b = Array.from({ length: 17 }, () => ({ pressed: false, value: 0 }));
  b[Std.RT] = { pressed: true, value: 1 };
  const list: (MinimalGamepad | null)[] = [pad({ buttons: b })];
  const store = new RemapStore(new MemKV());
  const sys = new InputSystem(store, new GamepadManager(store, () => list));
  sys.padsInjected = true;
  sys.inVehicle = () => true;
  sys.poll();
  assert.equal(sys.latch(0)[0]!.throttle, 127);
  const seen: string[] = [];
  sys.on((e) => seen.push(e.type));
  sys.padsEnabled = false;
  sys.poll();
  assert.equal(sys.latch(1)[0]!.throttle, 0, "pad ignored while off");
  assert.equal(sys.players[0]!.pad, 0, "the slot keeps its pad for when it's switched back on");
  sys.keyboard.keyDown("ArrowUp");
  sys.poll();
  assert.equal(sys.latch(2)[0]!.throttle, 127, "keyboard still works");
  sys.keyboard.keyUp("ArrowUp");
  sys.padsEnabled = true;
  let focused = false;
  sys.hasFocus = () => focused;
  sys.poll();
  assert.equal(sys.latch(3)[0]!.throttle, 0, "pad ignored while the window isn't focused");
  focused = true;
  sys.poll();
  assert.equal(sys.latch(4)[0]!.throttle, 127);
  assert.deepEqual(seen, ["pads-toggled", "pads-toggled"]);
});
