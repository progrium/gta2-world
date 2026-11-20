// What each physical control does. One binding set per controller key (pads)
// and one for the keyboard. Remaps replace these and are stored by remapStore.

/** A gamepad source. `b` = button value (analog where the pad gives it).
 *  `a` = one half of an axis: value = max(0, dir * axis). `full` axes rest at -1
 *  and run to +1 (triggers on non-standard Firefox mappings); they are rescaled to 0..1. */
export type PadSource =
  | { t: "b"; i: number }
  | { t: "a"; i: number; dir: 1 | -1; full?: boolean };

/** Digital actions; each maps onto one I2 button bit. `direct` is not here: it is a mode. */
export const BUTTON_ACTIONS = ["fire", "enterExit", "handbrakeJump", "weaponNext", "weaponPrev", "special", "run"] as const;
export type ButtonAction = (typeof BUTTON_ACTIONS)[number];

/** Analog-capable actions. up/down/left/right add to the move stick (d-pad, keys). */
export const ANALOG_ACTIONS = ["accelerate", "brake", "up", "down", "left", "right"] as const;
export type AnalogAction = (typeof ANALOG_ACTIONS)[number];

export type Action = ButtonAction | AnalogAction;

export interface StickBinding {
  x: number;
  y: number;
  /** Multiply an axis by -1 (some pads report up as +1). */
  invertX?: boolean;
  invertY?: boolean;
}

export interface PadBindings {
  version: 1;
  stick: StickBinding;
  actions: Record<Action, PadSource[]>;
}

export interface KeyBindings {
  version: 1;
  /** KeyboardEvent.code values. */
  actions: Record<Action, string[]>;
}

const b = (i: number): PadSource => ({ t: "b", i });

/** W3C standard mapping indices. */
export const Std = {
  A: 0, B: 1, X: 2, Y: 3, LB: 4, RB: 5, LT: 6, RT: 7, Back: 8, Start: 9, LS: 10, RS: 11,
  Up: 12, Down: 13, Left: 14, Right: 15, Home: 16,
} as const;

/**
 * Defaults for a pad with mapping "standard". Positions, not labels (S6 gap 7):
 * Std.A is Cross on PlayStation and B on Switch. Home is never bound (S6 gap 10).
 * On foot the right trigger also fires; see ComposeOptions.triggerFiresOnFoot.
 */
export function defaultPadBindings(): PadBindings {
  return {
    version: 1,
    stick: { x: 0, y: 1 },
    actions: {
      accelerate: [b(Std.RT)],
      brake: [b(Std.LT)],
      up: [b(Std.Up)],
      down: [b(Std.Down)],
      left: [b(Std.Left)],
      right: [b(Std.Right)],
      fire: [b(Std.X)],
      enterExit: [b(Std.Y)],
      handbrakeJump: [b(Std.A)],
      weaponNext: [b(Std.RB)],
      weaponPrev: [b(Std.LB)],
      special: [b(Std.LS)],
      run: [b(Std.B)],
    },
  };
}

/**
 * Best guess for mapping "" (S6 gap 8: Firefox on Linux/macOS, Chrome on Linux
 * with Switch Pro over Bluetooth). Buttons follow the common HID order and the
 * d-pad is not bound. The UI asks the player to remap these pads.
 */
export function defaultNonStandardBindings(): PadBindings {
  const d = defaultPadBindings();
  d.actions.up = [];
  d.actions.down = [];
  d.actions.left = [];
  d.actions.right = [];
  return d;
}

/**
 * Built-in per-controller table, consulted before the generic defaults.
 * Empty until probe runs on real hardware show a pad that needs one
 * (S6 accepted with only the Xbox 360 / Brave run).
 */
export const KNOWN_PADS: Record<string, () => PadBindings> = {};

/** Keyboard defaults, close to the original's layout. Alt is avoided: browsers use it. */
export function defaultKeyBindings(): KeyBindings {
  return {
    version: 1,
    actions: {
      accelerate: [],
      brake: [],
      up: ["ArrowUp", "KeyW"],
      down: ["ArrowDown", "KeyS"],
      left: ["ArrowLeft", "KeyA"],
      right: ["ArrowRight", "KeyD"],
      fire: ["ControlLeft", "ControlRight", "KeyJ"],
      enterExit: ["Enter", "KeyF"],
      handbrakeJump: ["Space"],
      weaponNext: ["KeyX", "KeyE"],
      weaponPrev: ["KeyZ", "KeyQ"],
      special: ["KeyC"],
      run: ["ShiftLeft", "ShiftRight"],
    },
  };
}

export const ACTION_LABELS: Record<Action, string> = {
  accelerate: "Accelerate",
  brake: "Brake / reverse",
  up: "Up",
  down: "Down",
  left: "Left",
  right: "Right",
  fire: "Fire",
  enterExit: "Enter / exit vehicle",
  handbrakeJump: "Handbrake / jump",
  weaponNext: "Next weapon",
  weaponPrev: "Previous weapon",
  special: "Horn / special",
  run: "Run",
};

/** Read one pad source as 0..1. */
export function readPadSource(s: PadSource, buttons: readonly { value: number; pressed: boolean }[], axes: readonly number[]): number {
  if (s.t === "b") {
    const btn = buttons[s.i];
    if (!btn) return 0;
    // Some browsers report a digital button as pressed with value 0.
    if (btn.pressed && !(btn.value > 0)) return 1;
    return Math.max(0, Math.min(1, btn.value || 0));
  }
  // The gamepad layer passes NaN for axes that have never moved: Firefox reports
  // an untouched full-range trigger as 0, which would read as half pressed.
  const raw = axes[s.i];
  if (raw === undefined || !Number.isFinite(raw)) return 0;
  const v = s.full ? (raw * s.dir + 1) / 2 : raw * s.dir;
  return Math.max(0, Math.min(1, v));
}
