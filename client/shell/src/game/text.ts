// Game text as the HUD shows it: the .gxt table's markup and the
// single-player HUD's small formatting rules. Pure functions, unit tested.
//
// Text comes from the player's own .gxt (formats/gxt.zig in the game
// module). Markup seen in the player's e.gxt:
//   - '#' toggles highlighted text ("Get #all# the #Yakuza jobs#").
//   - A brief may start with a portrait marker naming who speaks
//     (script-messages.md 2.3): one 16-bit unit whose low byte is a letter
//     and whose high byte is 0x21, i.e. the two bytes "<letter>!".
//   - "%d" and "%s" are filled in by the game (target score, prices).

export interface TextSpan {
  text: string;
  hi: boolean;
}

export interface GameText {
  /** The portrait marker's letter, or null for plain text (a neutral face). */
  portrait: string | null;
  spans: TextSpan[];
  /** All the text, without markup. */
  plain: string;
}

export function parseGameText(s: string): GameText {
  let portrait: string | null = null;
  const c0 = s.charCodeAt(0);
  if (s.length > 0 && c0 >> 8 === 0x21) {
    portrait = String.fromCharCode(c0 & 0xff);
    s = s.slice(1);
  }
  const spans: TextSpan[] = [];
  let hi = false;
  let cur = "";
  for (const ch of s) {
    if (ch === "#") {
      if (cur) spans.push({ text: cur, hi });
      cur = "";
      hi = !hi;
    } else cur += ch;
  }
  if (cur) spans.push({ text: cur, hi });
  return { portrait, spans, plain: spans.map((x) => x.text).join("") };
}

/** The first `n` characters of `t`'s spans (a brief typing itself out). */
export function truncateSpans(spans: readonly TextSpan[], n: number): TextSpan[] {
  const out: TextSpan[] = [];
  let left = Math.max(0, n);
  for (const sp of spans) {
    if (left <= 0) break;
    const t = sp.text.slice(0, left);
    out.push({ text: t, hi: sp.hi });
    left -= t.length;
  }
  return out;
}

/** Fills "%d" and "%s" in order. */
export function fillText(s: string, ...args: (string | number)[]): string {
  let i = 0;
  return s.replace(/%[ds]/g, (m) => (i < args.length ? (m === "%d" && typeof args[i] === "number" ? Number(args[i++]).toLocaleString("en-US") : String(args[i++])) : m));
}

/**
 * Badge colours for the portrait letters seen in the player's text (ours,
 * until the HUD note says how faces are drawn). Unknown letters are neutral.
 */
export const PORTRAIT_COLOURS: Record<string, string> = {
  l: "#3fbf3f",
  y: "#d8d8d8",
  z: "#3f6fe0",
  r: "#d03f2f",
  s: "#9f5fd0",
  k: "#e0a03f",
  m: "#b02020",
};

export const TICKS_PER_SECOND = 30;
/** Ticks per character a brief types itself out at (script-messages.md, the default). */
export const BRIEF_TICKS_PER_CHAR = 3;

/** A countdown in ticks as m:ss, rounding up so it reads 0:00 only at zero. */
export function formatTimer(ticks: number): string {
  const s = Math.max(0, Math.ceil(ticks / TICKS_PER_SECOND));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

/** Thousands-separated points. */
export function formatPoints(n: number): string {
  return Math.trunc(n).toLocaleString("en-US");
}

/** The kill event's weapon numbering, as game.zig and the sim use it. */
export const CAUSE_FIRE = 0x81;
export const WEAPON_ELECTRO = 7;

/**
 * The death message's text key by cause (power-ups-death-and-arrest.md
 * 3.2): burned "fried", electrocuted "shocked", anything else "wasted".
 */
export function deathKey(cause: number): string {
  if (cause === CAUSE_FIRE) return "fried";
  if (cause === WEAPON_ELECTRO) return "shocked";
  return "wasted";
}

/** Shown when the player's own text has no such key (no .gxt imported). Our words. */
export const FALLBACK_TEXT: Record<string, string> = {
  wasted: "WASTED",
  fried: "FRIED",
  shocked: "SHOCKED",
  nicked: "BUSTED",
  g_over: "GAME OVER",
  mfail: "JOB FAILED",
  gam_cmp: "LEVEL COMPLETE",
  loading: "GET READY",
  kfstart: "KILL FRENZY",
  kfpass: "FRENZY PASSED",
  kffail: "FRENZY FAILED",
};

/**
 * Screen angle (radians, 0 = right, clockwise, as CSS rotate) from the
 * player to a target, both in blocks. Sim axes: x east, y south; the
 * top-down camera has north up, so world and screen agree.
 */
export function arrowAngle(px: number, py: number, tx: number, ty: number): number {
  return Math.atan2(ty - py, tx - px);
}
