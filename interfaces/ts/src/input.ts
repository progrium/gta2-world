// I2. Input frame: 8 bytes per player per tick.
// Frozen interface. Spec: interfaces/I2-input-frame.md. Twin of zig/src/input.zig.

export interface Frame {
  /** -127..127, + = turn clockwise (right on screen). */
  steer: number;
  /** -127..127, + = accelerate / walk forward, - = brake / reverse. */
  throttle: number;
  /** Bit mask, see Button. */
  buttons: number;
  /** Binary angle (65536 = one turn). Meaningful only with Button.direct. */
  aim: number;
  /** Low 16 bits of the tick this frame drives. */
  seq: number;
}

export const FRAME_SIZE = 8;

export const Button = {
  fire: 1 << 0,
  enterExit: 1 << 1,
  handbrakeJump: 1 << 2,
  weaponNext: 1 << 3,
  weaponPrev: 1 << 4,
  special: 1 << 5,
  direct: 1 << 6,
  run: 1 << 7,
} as const;

export const BUTTON_DEFINED_MASK = 0x00ff;
export const BUTTON_EDGE_MASK = Button.enterExit | Button.weaponNext | Button.weaponPrev;

export function neutralFrame(seq: number): Frame {
  return { steer: 0, throttle: 0, buttons: 0, aim: 0, seq: seq & 0xffff };
}

export function encodeFrame(f: Frame, out: DataView, offset = 0): void {
  out.setInt8(offset, f.steer);
  out.setInt8(offset + 1, f.throttle);
  out.setUint16(offset + 2, f.buttons, true);
  out.setUint16(offset + 4, f.aim, true);
  out.setUint16(offset + 6, f.seq, true);
}

export function decodeFrame(dv: DataView, offset = 0): Frame {
  return {
    steer: dv.getInt8(offset),
    throttle: dv.getInt8(offset + 1),
    buttons: dv.getUint16(offset + 2, true),
    aim: dv.getUint16(offset + 4, true),
    seq: dv.getUint16(offset + 6, true),
  };
}

/** Same rules as Frame.sanitize in Zig. */
export function sanitizeFrame(f: Frame): Frame {
  const buttons = f.buttons & BUTTON_DEFINED_MASK;
  return {
    steer: f.steer === -128 ? -127 : f.steer,
    throttle: f.throttle === -128 ? -127 : f.throttle,
    buttons,
    aim: buttons & Button.direct ? f.aim & 0xffff : 0,
    seq: f.seq & 0xffff,
  };
}

export const seqOf = (tick: number): number => tick & 0xffff;

/** Expand a 16-bit seq to the full tick nearest `reference` (serial arithmetic). */
export function expandSeq(seq: number, reference: number): number {
  let diff = (seq - (reference & 0xffff)) & 0xffff;
  if (diff >= 0x8000) diff -= 0x10000;
  return (reference + diff) >>> 0;
}

/**
 * Quantise an analog value in [-1, 1] to an axis: round half away from zero,
 * clamp to -127..127. Every device path goes through this.
 */
export function quantizeAxis(v: number): number {
  if (!Number.isFinite(v)) return 0;
  const s = v * 127;
  const q = s < 0 ? -Math.round(-s) : Math.round(s);
  return Math.max(-127, Math.min(127, q));
}

/** Radial deadzone for a stick, then rescale so output starts at 0 at the edge of the zone. */
export function radialDeadzone(x: number, y: number, zone = 0.15): [number, number] {
  const m = Math.hypot(x, y);
  if (m <= zone) return [0, 0];
  const k = Math.min(1, (m - zone) / (1 - zone)) / m;
  return [x * k, y * k];
}

/** Convert a direction vector (screen space: +x right, +y down) to a binary angle. */
export function angleFromVector(x: number, y: number): number {
  const a = Math.atan2(y, x); // y down => clockwise positive, matching I1
  return Math.round((a / (2 * Math.PI)) * 65536) & 0xffff;
}
