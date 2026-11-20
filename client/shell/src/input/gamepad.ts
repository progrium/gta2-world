// Gamepads: polled once per animation frame, hot-plugged, read through
// per-controller bindings. Browsers expose a pad only after a button press in a
// secure context (S6 gap 5), so the UI prompts for one while `pads` is empty.

import { ANALOG_ACTIONS, BUTTON_ACTIONS, type PadBindings, readPadSource } from "./bindings.ts";
import { type ControllerKey, type PadFamily, normalizeControllerId, padFamily } from "./controllerId.ts";
import { radialDeadzone } from "./i2.ts";
import type { RemapStore } from "./remapStore.ts";
import { ACTION_BIT, type Sample, emptySample } from "./sample.ts";

/** Digital threshold for analog sources bound to button actions. */
export const BUTTON_THRESHOLD = 0.5;

export interface PadState {
  index: number;
  id: string;
  key: ControllerKey;
  family: PadFamily;
  mapping: string;
  bindings: PadBindings;
  bindingSource: "saved" | "table" | "default";
  /** Axes that have moved at least once; untouched axes read as NaN (see readPadSource). */
  axisMoved: boolean[];
  /** Button bits seen by raw-input events since the last poll. */
  tapped: number;
  /** Last pad.timestamp, for the HUD's staleness readout. */
  timestamp: number;
  connected: boolean;
}

export interface MinimalGamepad {
  index: number;
  id: string;
  mapping: string;
  connected: boolean;
  timestamp: number;
  axes: readonly number[];
  buttons: readonly { pressed: boolean; value: number }[];
}

export type PadEvent = { type: "connected" | "disconnected" | "remapped"; pad: PadState };

export class GamepadManager {
  readonly pads = new Map<number, PadState>();
  deadzone = 0.15;
  private listeners = new Set<(e: PadEvent) => void>();
  private live: (MinimalGamepad | null)[] = [];

  private store: RemapStore;
  private source: () => readonly (MinimalGamepad | null)[];

  constructor(store: RemapStore, source: () => readonly (MinimalGamepad | null)[] = defaultSource) {
    this.store = store;
    this.source = source;
  }

  static supported(): boolean {
    return typeof navigator !== "undefined" && typeof navigator.getGamepads === "function";
  }

  attach(): void {
    window.addEventListener("gamepadconnected", this.onEvent as EventListener);
    window.addEventListener("gamepaddisconnected", this.onEvent as EventListener);
    // Chromium experimental: per-report events, so taps between frames are not lost.
    window.addEventListener("gamepadrawinputchanged", this.onRaw as EventListener);
  }

  detach(): void {
    window.removeEventListener("gamepadconnected", this.onEvent as EventListener);
    window.removeEventListener("gamepaddisconnected", this.onEvent as EventListener);
    window.removeEventListener("gamepadrawinputchanged", this.onRaw as EventListener);
  }

  on(fn: (e: PadEvent) => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  /** The live Gamepad for an index, from the latest poll (for rumble and the remap screen). */
  gamepad(index: number): MinimalGamepad | null {
    return this.live[index] ?? null;
  }

  /**
   * Poll every pad. Hot-plug is detected here as well as from events, since
   * connect events can be late or missing while the tab is hidden (S6 gap 11).
   */
  poll(): Map<number, Sample> {
    const out = new Map<number, Sample>();
    for (const gp of this.sync()) out.set(gp.index, this.read(this.pads.get(gp.index)!, gp));
    return out;
  }

  /** Hot-plug bookkeeping only: add new pads, drop missing ones. Returns the connected pads. */
  sync(): MinimalGamepad[] {
    let list: readonly (MinimalGamepad | null)[] = [];
    try {
      list = this.source();
    } catch {
      list = [];
    }
    this.live = Array.from(list);
    const present: MinimalGamepad[] = [];
    for (const gp of list) {
      if (!gp || !gp.connected) continue;
      present.push(gp);
      const st = this.pads.get(gp.index);
      if (!st || st.id !== gp.id) {
        if (st) this.drop(st);
        this.add(gp);
      }
    }
    const idx = new Set(present.map((g) => g.index));
    for (const st of [...this.pads.values()]) if (!idx.has(st.index)) this.drop(st);
    return present;
  }

  setBindings(index: number, b: PadBindings, persist = true): void {
    const st = this.pads.get(index);
    if (!st) return;
    st.bindings = b;
    st.bindingSource = "saved";
    if (persist) this.store.savePad(st.key, b);
    this.emit({ type: "remapped", pad: st });
  }

  resetBindings(index: number): void {
    const st = this.pads.get(index);
    if (!st) return;
    this.store.resetPad(st.key);
    const r = this.store.pad(st.key, st.mapping);
    st.bindings = r.bindings;
    st.bindingSource = r.source;
    this.emit({ type: "remapped", pad: st });
  }

  /** Read a pad through its bindings. Exposed for tests. */
  read(st: PadState, gp: MinimalGamepad): Sample {
    st.timestamp = gp.timestamp;
    const axes = gp.axes.map((v, i) => {
      if (!st.axisMoved[i] && v !== 0) st.axisMoved[i] = true;
      return st.axisMoved[i] ? v : Number.NaN;
    });
    const b = st.bindings;
    const ax = (i: number): number => {
      const v = axes[i];
      return v === undefined || !Number.isFinite(v) ? 0 : v;
    };
    const sy = b.stick.invertY ? -ax(b.stick.y) : ax(b.stick.y);
    const sx = b.stick.invertX ? -ax(b.stick.x) : ax(b.stick.x);
    let [x, y] = radialDeadzone(sx, sy, this.deadzone);

    const val = (a: (typeof ANALOG_ACTIONS)[number]): number => {
      let m = 0;
      for (const s of b.actions[a]) m = Math.max(m, readPadSource(s, gp.buttons, axes));
      return m;
    };
    const dy = val("down") - val("up");
    x = Math.max(-1, Math.min(1, x + val("right") - val("left")));
    y = Math.max(-1, Math.min(1, y + dy));

    let buttons = st.tapped;
    st.tapped = 0;
    for (const a of BUTTON_ACTIONS) {
      for (const s of b.actions[a]) {
        if (readPadSource(s, gp.buttons, axes) >= BUTTON_THRESHOLD) {
          buttons |= ACTION_BIT[a];
          break;
        }
      }
    }
    return { moveX: x, moveY: y, digitalY: dy, accelerate: val("accelerate"), brake: val("brake"), buttons };
  }

  private add(gp: MinimalGamepad): PadState {
    const key = normalizeControllerId(gp.id);
    const r = this.store.pad(key, gp.mapping);
    const st: PadState = {
      index: gp.index,
      id: gp.id,
      key,
      family: padFamily(key),
      mapping: gp.mapping,
      bindings: r.bindings,
      bindingSource: r.source,
      axisMoved: [],
      tapped: 0,
      timestamp: gp.timestamp,
      connected: true,
    };
    this.pads.set(gp.index, st);
    this.emit({ type: "connected", pad: st });
    return st;
  }

  private drop(st: PadState): void {
    st.connected = false;
    this.pads.delete(st.index);
    this.emit({ type: "disconnected", pad: st });
  }

  private emit(e: PadEvent): void {
    for (const fn of this.listeners) fn(e);
  }

  private onEvent = (): void => {
    // Events only nudge; polling is the source of truth (events can be late or missing).
    this.sync();
  };

  private onRaw = (e: Event): void => {
    const gp = (e as Event & { gamepad?: MinimalGamepad }).gamepad;
    if (!gp) return;
    const st = this.pads.get(gp.index);
    if (!st) return;
    const s = this.read(st, gp);
    // read() consumed st.tapped; keep it plus the new bits for the next poll.
    st.tapped = s.buttons;
  };
}

function defaultSource(): readonly (MinimalGamepad | null)[] {
  return navigator.getGamepads();
}

export { emptySample };
