// A device-neutral reading of one device (or several merged) at one poll.

import { BUTTON_ACTIONS, type ButtonAction } from "./bindings.ts";
import { Button } from "./i2.ts";

export interface Sample {
  /** Move vector after deadzone, -1..1, screen space: +x right, +y down. */
  moveX: number;
  moveY: number;
  /** -1..1 from digital up/down only (keys, d-pad), +y down. Drives a car; the analog stick's y never does. */
  digitalY: number;
  /** 0..1. Analog where the device gives it; digital triggers give 0 or 1. */
  accelerate: number;
  brake: number;
  /** I2 button bits held at this poll (never includes `direct`). */
  buttons: number;
}

export const emptySample = (): Sample => ({ moveX: 0, moveY: 0, digitalY: 0, accelerate: 0, brake: 0, buttons: 0 });

export const ACTION_BIT: Record<ButtonAction, number> = {
  fire: Button.fire,
  enterExit: Button.enterExit,
  handbrakeJump: Button.handbrakeJump,
  weaponNext: Button.weaponNext,
  weaponPrev: Button.weaponPrev,
  special: Button.special,
  run: Button.run,
};
export { BUTTON_ACTIONS };

/** Merge devices driving one player: the larger move vector wins, pedals take the max, buttons OR. */
export function mergeSamples(samples: readonly Sample[]): Sample {
  const out = emptySample();
  let best = 0;
  for (const s of samples) {
    const m = s.moveX * s.moveX + s.moveY * s.moveY;
    if (m > best) {
      best = m;
      out.moveX = s.moveX;
      out.moveY = s.moveY;
    }
    if (Math.abs(s.digitalY) > Math.abs(out.digitalY)) out.digitalY = s.digitalY;
    out.accelerate = Math.max(out.accelerate, s.accelerate);
    out.brake = Math.max(out.brake, s.brake);
    out.buttons |= s.buttons;
  }
  return out;
}

/** Clamp a vector to the unit circle (S6: square-ish gates reach 1.22 on diagonals). */
export function clampUnit(x: number, y: number): [number, number] {
  const m = Math.hypot(x, y);
  return m > 1 ? [x / m, y / m] : [x, y];
}
