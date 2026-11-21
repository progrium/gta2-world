// Fixed 30 Hz sim clock driven by requestAnimationFrame. Input is polled every
// frame and latched at each tick; rendering gets the fraction into the next
// tick for interpolation.

import { TICK_HZ } from "../../../interfaces/ts/src/abi.ts";

export const TICK_MS = 1000 / TICK_HZ;
/** After a long stall (tab hidden, debugger) don't try to catch up more than this. */
export const MAX_CATCHUP_TICKS = 5;

export interface LoopHooks {
  /** Once per animation frame, before any tick. Poll input here. */
  frame(now: number): void;
  /** Once per sim tick. */
  tick(tick: number): void;
  /** After ticks; alpha in [0,1) is the fraction toward the next tick. */
  render(alpha: number, now: number): void;
  /** Instead of render while the tab is hidden: keep work that must not stop (online input), draw nothing. */
  background?(now: number): void;
}

export class FixedLoop {
  tick = 0;
  private acc = 0;
  private last = -1;
  private raf = 0;
  running = false;

  private hooks: LoopHooks;

  constructor(hooks: LoopHooks) {
    this.hooks = hooks;
  }

  start(): void {
    if (this.running) return;
    this.running = true;
    this.last = -1;
    const step = (now: number): void => {
      if (!this.running) return;
      this.advance(now);
      this.raf = requestAnimationFrame(step);
    };
    this.raf = requestAnimationFrame(step);
    this.startBackground();
  }

  stop(): void {
    this.running = false;
    cancelAnimationFrame(this.raf);
    this.beat?.terminate();
    this.beat = null;
  }

  // A hidden tab gets no animation frames, so the sim (and, online, the
  // input datagrams that keep the connection alive) would stop. While the
  // page is hidden a tiny Worker's timer, which browsers don't throttle like
  // page timers, keeps ticking it without rendering. Two tabs of one browser
  // (host and joiner) are always one hidden and one visible.
  private beat: Worker | null = null;

  private startBackground(): void {
    if (typeof Worker === "undefined" || typeof document === "undefined" || typeof Blob === "undefined") return;
    try {
      const src = `setInterval(() => postMessage(0), ${Math.floor(TICK_MS)});`;
      const url = URL.createObjectURL(new Blob([src], { type: "text/javascript" }));
      this.beat = new Worker(url);
      URL.revokeObjectURL(url);
      this.beat.onmessage = () => {
        if (this.running && document.hidden) this.advance(performance.now(), false);
      };
    } catch (e) {
      console.warn("[loop] no background ticking", e);
    }
  }

  /** One animation frame. Public for tests. Returns ticks run. */
  advance(now: number, render = true): number {
    if (this.last < 0) this.last = now;
    this.acc += Math.max(0, now - this.last);
    this.last = now;
    if (this.acc > MAX_CATCHUP_TICKS * TICK_MS) this.acc = MAX_CATCHUP_TICKS * TICK_MS;
    this.hooks.frame(now);
    let n = 0;
    while (this.acc >= TICK_MS - 1e-6) {
      this.hooks.tick(this.tick);
      this.tick = (this.tick + 1) >>> 0;
      this.acc = Math.max(0, this.acc - TICK_MS);
      n++;
    }
    if (render) this.hooks.render(this.acc / TICK_MS, now);
    else this.hooks.background?.(now);
    return n;
  }
}
