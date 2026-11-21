// On-screen gamepad for touch screens. The overlay (ui/touchPad.ts) writes
// into this device; poll() turns it into a Sample like the keyboard and pads,
// so it reaches the sim through the same latch and compose step.
//
// One virtual stick: on foot it points the ped (direct scheme by default);
// in a car x steers and y is the pedal, pushed up to accelerate and down to
// brake or reverse, the same as up/down on the keyboard.

import type { ButtonAction } from "./bindings.ts";
import { ACTION_BIT, type Sample, clampUnit } from "./sample.ts";

/** Stick travel below this fraction of the radius reads as centred. */
export const TOUCH_DEADZONE = 0.15;

export class TouchDevice {
  private x = 0;
  private y = 0;
  private held = new Set<ButtonAction>();
  /** Button bits pressed since the last poll, so a quick tap still lands. */
  private tapped = 0;

  /** Stick deflection, screen space (+x right, +y down), any length; clamped to the unit circle. */
  setStick(x: number, y: number): void {
    const [cx, cy] = clampUnit(x, y);
    const m = Math.hypot(cx, cy);
    if (m < TOUCH_DEADZONE) {
      this.x = 0;
      this.y = 0;
      return;
    }
    // Rescale so the edge of the deadzone is 0 and the rim is 1.
    const k = (m - TOUCH_DEADZONE) / (1 - TOUCH_DEADZONE) / m;
    this.x = cx * k;
    this.y = cy * k;
  }

  press(a: ButtonAction): void {
    if (this.held.has(a)) return;
    this.held.add(a);
    this.tapped |= ACTION_BIT[a];
  }

  release(a: ButtonAction): void {
    this.held.delete(a);
  }

  releaseAll(): void {
    this.x = 0;
    this.y = 0;
    this.held.clear();
    this.tapped = 0;
  }

  /** Read the current state and clear the tap accumulator. */
  poll(): Sample {
    let buttons = this.tapped;
    this.tapped = 0;
    for (const a of this.held) buttons |= ACTION_BIT[a];
    return { moveX: this.x, moveY: this.y, digitalY: this.y, accelerate: 0, brake: 0, buttons };
  }
}

/** Whether this device's main pointer is a finger; decides the overlay's default. */
export function coarsePointer(): boolean {
  try {
    return !!globalThis.matchMedia?.("(pointer: coarse)").matches;
  } catch {
    return false;
  }
}
