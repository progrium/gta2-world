// Turn a latched Sample into an I2 frame for the player's current context.
// Pure: the tick latch calls it once per sim tick.

import { Button, type Frame, angleFromVector, quantizeAxis, sanitizeFrame } from "./i2.ts";
import type { Sample } from "./sample.ts";

export type FootScheme = "tank" | "direct";

export interface ComposeContext {
  /** True while the player's ped rides a vehicle (PlayerRow.car != ENTITY_NONE once the sim lands). */
  inVehicle: boolean;
  footScheme: FootScheme;
  /** Last heading sent in direct mode, kept while the stick is centred so the ped doesn't turn to 0. */
  lastAim: number;
}

export interface ComposeOptions {
  /** On foot the accelerate trigger also fires (twin-trigger habit). Default true. */
  triggerFiresOnFoot: boolean;
}

export const defaultComposeOptions: ComposeOptions = { triggerFiresOnFoot: true };

/** Threshold at which an analog pedal counts as a button. */
const PEDAL_AS_BUTTON = 0.5;

export function composeFrame(s: Sample, ctx: ComposeContext, seq: number, opt: ComposeOptions = defaultComposeOptions): Frame {
  let buttons = s.buttons;
  let steer = 0;
  let throttle = 0;
  let aim = 0;

  if (ctx.inVehicle) {
    steer = quantizeAxis(s.moveX);
    // Pedals, plus digital up/down so the keyboard and d-pad drive too. The
    // stick's y is left out: pushing the stick while on the trigger must not brake.
    const pedal = s.accelerate - s.brake;
    const fromMove = -s.digitalY;
    throttle = quantizeAxis(Math.abs(pedal) >= Math.abs(fromMove) ? pedal : fromMove);
  } else {
    if (opt.triggerFiresOnFoot && s.accelerate >= PEDAL_AS_BUTTON) buttons |= Button.fire;
    if (ctx.footScheme === "tank") {
      steer = quantizeAxis(s.moveX);
      throttle = quantizeAxis(-s.moveY);
    } else {
      buttons |= Button.direct;
      const mag = Math.min(1, Math.hypot(s.moveX, s.moveY));
      throttle = quantizeAxis(mag);
      aim = throttle > 0 ? angleFromVector(s.moveX, s.moveY) : ctx.lastAim & 0xffff;
      ctx.lastAim = aim;
    }
  }
  return sanitizeFrame({ steer, throttle, buttons, aim, seq });
}
