// Deathmatch: an arrow at the screen edge for each other player who is off
// screen, pointing toward them, in that player's colour, with their name and
// distance. The camera looks straight down (north up), so a world point
// projects with the eye height and the vertical field of view alone. Our own
// design; the sim doesn't change.

import type { CameraView } from "../../../render/ts/src/index.ts";
import { h } from "./dom.ts";

/** One colour per player slot, for the arrows and the scoreboard. */
export const PLAYER_COLOURS = [
  "#ffd54f", "#4fc3f7", "#ef5350", "#66bb6a", "#ba68c8", "#ff8a65", "#4dd0e1", "#f06292",
  "#aed581", "#9575cd", "#ffb74d", "#90a4ae", "#e57373", "#81c784", "#64b5f6", "#fff176",
];
export const playerColour = (slot: number): string => PLAYER_COLOURS[slot % PLAYER_COLOURS.length]!;

/** Screen position in CSS pixels of world point (x, y, z) under a top-down `view`. */
export function projectTopDown(view: CameraView, x: number, y: number, z: number, w: number, hgt: number): { x: number; y: number } {
  const halfH = Math.max(0.5, view.eye[2] - z) * Math.tan(view.fovY / 2);
  const s = hgt / 2 / halfH;
  return { x: w / 2 + (x - view.target[0]) * s, y: hgt / 2 + (y - view.target[1]) * s };
}

/**
 * Where the edge arrow for a target at screen point (sx, sy) goes, on a
 * `w` x `hgt` screen inset by `margin`: null while the target is on screen,
 * else the point where the line from the centre leaves the inset box, and the
 * angle (radians, 0 = right, clockwise as screen y grows down).
 */
export function edgeArrow(sx: number, sy: number, w: number, hgt: number, margin: number): { x: number; y: number; angle: number } | null {
  if (sx >= 0 && sx <= w && sy >= 0 && sy <= hgt) return null;
  const cx = w / 2;
  const cy = hgt / 2;
  const dx = sx - cx;
  const dy = sy - cy;
  const hx = Math.max(1, cx - margin);
  const hy = Math.max(1, cy - margin);
  const t = Math.min(dx === 0 ? Infinity : hx / Math.abs(dx), dy === 0 ? Infinity : hy / Math.abs(dy));
  return { x: cx + dx * t, y: cy + dy * t, angle: Math.atan2(dy, dx) };
}

export interface ArrowTarget {
  slot: number;
  name: string;
  x: number;
  y: number;
  z: number;
}

export class PlayerArrows {
  readonly el = h("div", { class: "player-arrows" });
  private items = new Map<number, { el: HTMLElement; head: HTMLElement; label: HTMLElement }>();

  /** Shows arrows for `targets` (other live players) seen from `me` under `view`. */
  update(view: CameraView, me: { x: number; y: number } | null, targets: ArrowTarget[], w: number, hgt: number): void {
    const seen = new Set<number>();
    for (const t of targets) {
      const p = projectTopDown(view, t.x, t.y, t.z, w, hgt);
      const a = edgeArrow(p.x, p.y, w, hgt, 32);
      if (!a) continue;
      seen.add(t.slot);
      let it = this.items.get(t.slot);
      if (!it) {
        const head = h("div", { class: "pa-head" });
        const label = h("div", { class: "pa-label" });
        const el = h("div", { class: "pa" }, head, label);
        el.style.setProperty("--pc", playerColour(t.slot));
        this.el.append(el);
        it = { el, head, label };
        this.items.set(t.slot, it);
      }
      it.el.style.transform = `translate(${a.x.toFixed(1)}px, ${a.y.toFixed(1)}px)`;
      it.head.style.transform = `translate(-50%, -50%) rotate(${a.angle.toFixed(3)}rad)`;
      const d = me ? Math.round(Math.hypot(t.x - me.x, t.y - me.y)) : null;
      const text = d === null ? t.name : `${t.name} · ${d}`;
      if (it.label.textContent !== text) it.label.textContent = text;
      // Keep the label inside the screen: below the arrow at the top edge, above it elsewhere.
      it.label.classList.toggle("below", a.y < hgt / 2);
      it.label.classList.toggle("left", a.x > w - 80);
      it.label.classList.toggle("right", a.x < 80);
    }
    for (const [slot, it] of this.items) {
      if (seen.has(slot)) continue;
      it.el.remove();
      this.items.delete(slot);
    }
  }

  clear(): void {
    for (const it of this.items.values()) it.el.remove();
    this.items.clear();
  }
}
