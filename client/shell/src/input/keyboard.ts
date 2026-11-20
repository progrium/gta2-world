// Keyboard device. Full deflection per key (I2 device rules). Tracks keys by
// KeyboardEvent.code so the layout doesn't move with the user's keymap.

import { BUTTON_ACTIONS, type Action, type KeyBindings, defaultKeyBindings } from "./bindings.ts";
import { ACTION_BIT, type Sample } from "./sample.ts";

export class KeyboardDevice {
  private held = new Set<string>();
  /** Button bits pressed since the last poll, so sub-frame taps survive. */
  private tapped = 0;
  bindings: KeyBindings;
  /** Called on keydown of a bound key; lets the shell prevent page scroll etc. */
  private target: EventTarget | null = null;

  constructor(bindings: KeyBindings = defaultKeyBindings()) {
    this.bindings = bindings;
  }

  attach(target: EventTarget = window): void {
    this.detach();
    this.target = target;
    target.addEventListener("keydown", this.onDown as EventListener);
    target.addEventListener("keyup", this.onUp as EventListener);
    window.addEventListener("blur", this.onBlur);
  }

  detach(): void {
    if (!this.target) return;
    this.target.removeEventListener("keydown", this.onDown as EventListener);
    this.target.removeEventListener("keyup", this.onUp as EventListener);
    window.removeEventListener("blur", this.onBlur);
    this.target = null;
  }

  /** True if this code is bound to anything. */
  isBound(code: string): boolean {
    for (const a in this.bindings.actions) if (this.bindings.actions[a as Action].includes(code)) return true;
    return false;
  }

  keyDown(code: string): void {
    if (this.held.has(code)) return; // auto-repeat
    this.held.add(code);
    for (const a of BUTTON_ACTIONS) if (this.bindings.actions[a].includes(code)) this.tapped |= ACTION_BIT[a];
  }

  keyUp(code: string): void {
    this.held.delete(code);
  }

  releaseAll(): void {
    this.held.clear();
    this.tapped = 0;
  }

  private value(a: Action): number {
    for (const c of this.bindings.actions[a]) if (this.held.has(c)) return 1;
    return 0;
  }

  /** Read the current state and clear the tap accumulator. */
  poll(): Sample {
    let buttons = this.tapped;
    this.tapped = 0;
    for (const a of BUTTON_ACTIONS) if (this.value(a)) buttons |= ACTION_BIT[a];
    // Full deflection on each axis, so a diagonal in a car still steers fully.
    // Direct mode clamps the magnitude to 1 itself.
    return {
      moveX: this.value("right") - this.value("left"),
      moveY: this.value("down") - this.value("up"),
      digitalY: this.value("down") - this.value("up"),
      accelerate: this.value("accelerate"),
      brake: this.value("brake"),
      buttons,
    };
  }

  private onDown = (e: KeyboardEvent): void => {
    // Ctrl is fire, so Ctrl+key must still reach the game; Cmd combos stay with the browser.
    if (e.metaKey) return;
    if (this.isBound(e.code)) {
      e.preventDefault();
      this.keyDown(e.code);
    }
  };

  private onUp = (e: KeyboardEvent): void => {
    this.keyUp(e.code);
  };

  private onBlur = (): void => this.releaseAll();
}
