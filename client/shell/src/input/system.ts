// The input layer as the rest of the shell sees it: devices in, one I2 frame
// per local player per tick out.
//
// Slot 0 is the keyboard plus the first pad. Each further pad joins as another
// local player (split-screen, I3 add_local) when it presses Start. A pad that
// unplugs and comes back with the same controller key returns to its slot.

import { Std } from "./bindings.ts";
import { type ComposeOptions, type FootScheme, defaultComposeOptions } from "./compose.ts";
import { GamepadManager, type PadEvent } from "./gamepad.ts";
import { type Frame, seqOf } from "./i2.ts";
import { KeyboardDevice } from "./keyboard.ts";
import { TickLatch } from "./latch.ts";
import { RemapStore } from "./remapStore.ts";
import { Effects, type RumbleEffect, rumble } from "./rumble.ts";
import { type Sample, mergeSamples } from "./sample.ts";

export const MAX_LOCAL_PLAYERS = 4;

const PADS_KEY = "gta2.padsEnabled";

function loadPadsEnabled(): boolean {
  try {
    return globalThis.sessionStorage?.getItem(PADS_KEY) !== "0";
  } catch {
    return true;
  }
}

export type SchemeSetting = "auto" | FootScheme;

export interface LocalPlayer {
  slot: number;
  keyboard: boolean;
  /** Gamepad index currently driving this slot, or null. */
  pad: number | null;
  /** Controller key last seen on this slot, to reclaim it on reconnect. */
  padKey: string | null;
  scheme: SchemeSetting;
  /** Which device moved last; decides the "auto" scheme. */
  lastDevice: "keyboard" | "pad";
  latch: TickLatch;
  lastAim: number;
  lastFrame: Frame | null;
}

export type InputEvent =
  | PadEvent
  | { type: "player-joined" | "player-left"; player: LocalPlayer }
  | { type: "pads-toggled"; enabled: boolean };

const active = (s: Sample): boolean => s.buttons !== 0 || s.accelerate > 0 || s.brake > 0 || s.moveX !== 0 || s.moveY !== 0;

export class InputSystem {
  readonly store: RemapStore;
  readonly keyboard: KeyboardDevice;
  readonly pads: GamepadManager;
  readonly players: LocalPlayer[] = [];
  options: ComposeOptions = { ...defaultComposeOptions };
  /** Supplied by the sim host: is this slot's ped in a vehicle? */
  inVehicle: (slot: number) => boolean = () => false;
  /** When false, pads beyond the first never join (single-player screens). */
  allowLocalJoin = false;
  private listeners = new Set<(e: InputEvent) => void>();
  private startHeld = new Set<number>();

  constructor(store = new RemapStore(), pads?: GamepadManager) {
    this.store = store;
    this.keyboard = new KeyboardDevice(store.keyboard());
    this.pads = pads ?? new GamepadManager(store);
    this.players.push(this.newPlayer(0, true));
    this.pads.on((e) => this.onPad(e));
  }

  attach(target: EventTarget = window): void {
    this.keyboard.attach(target);
    if (GamepadManager.supported()) this.pads.attach();
  }

  detach(): void {
    this.keyboard.detach();
    this.pads.detach();
  }

  on(fn: (e: InputEvent) => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  /** Call once per animation frame. */
  poll(): void {
    const kb = this.keyboard.poll();
    const havePads = GamepadManager.supported() || this.padsInjected;
    let padSamples = new Map<number, Sample>();
    if (havePads) {
      // Hot-plug bookkeeping always runs so slots keep their pads; readings
      // are dropped while this tab has pads switched off or isn't focused.
      if (this.padsLive()) padSamples = this.pads.poll();
      else this.pads.sync();
    }
    this.handleJoins(padSamples);
    for (const p of this.players) {
      const parts: Sample[] = [];
      if (p.keyboard) {
        parts.push(kb);
        if (active(kb)) p.lastDevice = "keyboard";
      }
      if (p.pad !== null) {
        const s = padSamples.get(p.pad);
        if (s) {
          parts.push(s);
          if (active(s)) p.lastDevice = "pad";
        }
      }
      p.latch.observe(mergeSamples(parts));
    }
  }

  /** Call once per sim tick, after poll(). Returns one frame per local player, in slot order. */
  latch(tick: number): Frame[] {
    const seq = seqOf(tick);
    return this.players.map((p) => {
      const ctx = { inVehicle: this.inVehicle(p.slot), footScheme: this.schemeOf(p), lastAim: p.lastAim };
      const f = p.latch.take(ctx, seq, this.options);
      p.lastAim = ctx.lastAim;
      p.lastFrame = f;
      return f;
    });
  }

  schemeOf(p: LocalPlayer): FootScheme {
    if (p.scheme !== "auto") return p.scheme;
    // Design doc: direct mode is the gamepad default, tank the keyboard default.
    return p.lastDevice === "pad" ? "direct" : "tank";
  }

  /** Rumble whatever pad drives a slot. Silently does nothing without one. */
  rumble(slot: number, e: RumbleEffect): void {
    const p = this.players[slot];
    if (p?.pad == null || !this.padsLive()) return;
    rumble(this.pads.gamepad(p.pad), e);
  }

  /**
   * Controllers on or off for this tab. A pad is shared by every tab that
   * polls it, so two windows testing multiplayer would both drive from it.
   * Stored in sessionStorage: per tab, kept across reloads of that tab.
   */
  get padsEnabled(): boolean {
    return this._padsEnabled;
  }
  set padsEnabled(on: boolean) {
    if (on === this._padsEnabled) return;
    this._padsEnabled = on;
    try {
      sessionStorage.setItem(PADS_KEY, on ? "1" : "0");
    } catch {
      /* no storage: lasts for this page */
    }
    this.emit({ type: "pads-toggled", enabled: on });
  }
  private _padsEnabled = loadPadsEnabled();

  /** Ignore pads while the window isn't focused (another window has the player's attention). */
  padsNeedFocus = true;
  /** For tests: stands in for document.hasFocus(). */
  hasFocus: () => boolean = () => (typeof document === "undefined" ? true : document.hasFocus());

  /** Whether pad input reaches the game right now. */
  padsLive(): boolean {
    return this._padsEnabled && (!this.padsNeedFocus || this.hasFocus());
  }

  /** For tests: allow poll() to read pads without navigator.getGamepads. */
  padsInjected = false;

  private newPlayer(slot: number, keyboard: boolean): LocalPlayer {
    return { slot, keyboard, pad: null, padKey: null, scheme: "auto", lastDevice: keyboard ? "keyboard" : "pad", latch: new TickLatch(), lastAim: 0, lastFrame: null };
  }

  private onPad(e: PadEvent): void {
    const { pad } = e;
    if (e.type === "connected") {
      // Reclaim a slot that last held this controller, else give slot 0 its first pad.
      const owner = this.players.find((p) => p.pad === null && p.padKey === pad.key.key) ?? (this.players[0]!.pad === null ? this.players[0]! : undefined);
      if (owner) {
        owner.pad = pad.index;
        owner.padKey = pad.key.key;
        rumble(this.pads.gamepad(pad.index), Effects.enterExit);
      }
    } else if (e.type === "disconnected") {
      for (const p of this.players) if (p.pad === pad.index) p.pad = null;
    }
    this.emit(e);
  }

  private handleJoins(samples: Map<number, Sample>): void {
    for (const [index] of samples) {
      const gp = this.pads.gamepad(index);
      const start = !!gp?.buttons[Std.Start]?.pressed;
      const was = this.startHeld.has(index);
      if (start) this.startHeld.add(index);
      else this.startHeld.delete(index);
      if (!start || was || !this.allowLocalJoin) continue;
      if (this.players.some((p) => p.pad === index)) continue;
      if (this.players.length >= MAX_LOCAL_PLAYERS) continue;
      const used = new Set(this.players.map((q) => q.slot));
      let slot = 0;
      while (used.has(slot)) slot++;
      const p = this.newPlayer(slot, false);
      p.pad = index;
      p.padKey = this.pads.pads.get(index)?.key.key ?? null;
      this.players.push(p);
      this.players.sort((a, b) => a.slot - b.slot);
      this.emit({ type: "player-joined", player: p });
    }
  }

  /** Remove a local player (not slot 0). Remaining slots keep their numbers; the next join takes the lowest free one. */
  leave(slot: number): void {
    if (slot === 0) return;
    const i = this.players.findIndex((p) => p.slot === slot);
    if (i < 0) return;
    const [p] = this.players.splice(i, 1);
    this.emit({ type: "player-left", player: p! });
  }

  private emit(e: InputEvent): void {
    for (const fn of this.listeners) fn(e);
  }
}
