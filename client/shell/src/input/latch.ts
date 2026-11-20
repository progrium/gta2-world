// Polls happen once per animation frame; ticks happen at 30 Hz. The latch keeps
// the newest sample for the axes and ORs every button seen since the last tick,
// so a tap that starts and ends between two ticks still reaches the sim (I2,
// device rules; S6 caveat: 26% of pad updates fall between frame polls).

import type { Frame } from "./i2.ts";
import { type ComposeContext, type ComposeOptions, composeFrame, defaultComposeOptions } from "./compose.ts";
import { type Sample, emptySample } from "./sample.ts";

export class TickLatch {
  private latest: Sample = emptySample();
  private seen = 0;

  /** Record a poll. Call once per animation frame (and from raw-input events if available). */
  observe(s: Sample): void {
    this.latest = s;
    this.seen |= s.buttons;
  }

  /** Add button bits seen outside a poll, e.g. a key pressed and released inside one frame. */
  observeButtons(bits: number): void {
    this.seen |= bits;
  }

  /** Produce the frame for `seq` and start a new tick window. */
  take(ctx: ComposeContext, seq: number, opt: ComposeOptions = defaultComposeOptions): Frame {
    const s: Sample = { ...this.latest, buttons: this.latest.buttons | this.seen };
    this.seen = 0;
    return composeFrame(s, ctx, seq, opt);
  }

  /** Drop everything, e.g. on focus loss, so a key released while blurred doesn't stay held. */
  reset(): void {
    this.latest = emptySample();
    this.seen = 0;
  }
}
