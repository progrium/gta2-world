// Rumble through Gamepad.vibrationActuator where the browser has it.
// S6: Chrome dual-rumble (trigger-rumble from 126, Xbox One/Series on Windows
// only in practice), Safari dual-rumble from 16.4 with no trigger-rumble,
// Firefox none. Everything here is best-effort and never throws.

export interface RumbleEffect {
  /** 0..1 low-frequency motor. */
  strong: number;
  /** 0..1 high-frequency motor. */
  weak: number;
  durationMs: number;
  /** Optional trigger motors; used only where "trigger-rumble" is listed. */
  leftTrigger?: number;
  rightTrigger?: number;
}

interface Actuator {
  type?: string;
  effects?: readonly string[];
  playEffect?: (type: string, params: Record<string, number>) => Promise<unknown>;
  reset?: () => Promise<unknown>;
}

export type RumbleSupport = "none" | "dual" | "dual+trigger";

const clamp01 = (v: number | undefined): number => Math.max(0, Math.min(1, v ?? 0));

function actuatorOf(gp: unknown): Actuator | null {
  const a = (gp as { vibrationActuator?: Actuator | null } | null)?.vibrationActuator;
  return a && typeof a.playEffect === "function" ? a : null;
}

export function rumbleSupport(gp: unknown): RumbleSupport {
  const a = actuatorOf(gp);
  if (!a) return "none";
  const fx = a.effects ?? (a.type ? [a.type] : []);
  if (fx.includes("trigger-rumble")) return "dual+trigger";
  return fx.length === 0 || fx.includes("dual-rumble") ? "dual" : "none";
}

/** Global switch, for players who don't want it. */
export const rumbleSettings = { enabled: true, scale: 1 };

export function rumble(gp: unknown, e: RumbleEffect): void {
  if (!rumbleSettings.enabled) return;
  const a = actuatorOf(gp);
  if (!a?.playEffect) return;
  const k = rumbleSettings.scale;
  const base = { startDelay: 0, duration: Math.max(0, Math.round(e.durationMs)), strongMagnitude: clamp01(e.strong * k), weakMagnitude: clamp01(e.weak * k) };
  const wantTriggers = (e.leftTrigger ?? 0) > 0 || (e.rightTrigger ?? 0) > 0;
  const kind = wantTriggers && rumbleSupport(gp) === "dual+trigger" ? "trigger-rumble" : "dual-rumble";
  const params = kind === "trigger-rumble" ? { ...base, leftTrigger: clamp01(e.leftTrigger! * k), rightTrigger: clamp01(e.rightTrigger! * k) } : base;
  try {
    a.playEffect(kind, params).catch(() => {});
  } catch {
    /* some builds throw synchronously for unsupported effects */
  }
}

export function stopRumble(gp: unknown): void {
  const a = actuatorOf(gp);
  try {
    a?.reset?.()?.catch(() => {});
  } catch {
    /* ignore */
  }
}

/** Named effects the sim's events will map onto. Tuned by feel later. */
export const Effects = {
  enterExit: { strong: 0.2, weak: 0.4, durationMs: 60 },
  collisionLight: { strong: 0.3, weak: 0.5, durationMs: 90 },
  collisionHeavy: { strong: 1, weak: 0.6, durationMs: 220 },
  fire: { strong: 0.1, weak: 0.5, durationMs: 40, rightTrigger: 0.4 },
  explosion: { strong: 1, weak: 1, durationMs: 450 },
  test: { strong: 0.6, weak: 0.6, durationMs: 300, leftTrigger: 0.5, rightTrigger: 0.5 },
} satisfies Record<string, RumbleEffect>;
