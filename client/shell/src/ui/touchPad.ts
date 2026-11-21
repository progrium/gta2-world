// The on-screen gamepad overlay: a floating move stick on the left half of
// the view and the action buttons bottom right. It only writes into
// input.touch; the input system merges that into local player 1.

import type { ButtonAction } from "../input/bindings.ts";
import type { InputSystem } from "../input/system.ts";
import { h } from "./dom.ts";

/** Stick radius in CSS pixels: a drag this far from where the finger landed is full deflection. */
const STICK_RADIUS = 56;

const BUTTONS: { action: ButtonAction; label: string; cls: string; title: string }[] = [
  { action: "fire", label: "Fire", cls: "tp-fire", title: "Fire" },
  { action: "handbrakeJump", label: "Jump", cls: "tp-jump", title: "Jump on foot, handbrake in a car" },
  { action: "enterExit", label: "Car", cls: "tp-enter", title: "Get in or out of a car" },
  { action: "weaponPrev", label: "◀", cls: "tp-prev", title: "Previous weapon" },
  { action: "weaponNext", label: "▶", cls: "tp-next", title: "Next weapon" },
];

export interface TouchPadView {
  el: HTMLElement;
  /** Show or hide; hiding lets go of everything held. */
  setVisible(on: boolean): void;
  dispose(): void;
}

export function touchPad(input: InputSystem): TouchPadView {
  const knob = h("div", { class: "tp-knob" });
  const base = h("div", { class: "tp-base" }, knob);
  const zone = h("div", { class: "tp-stickzone" }, base);
  const cluster = h("div", { class: "tp-buttons" });
  const el = h("div", { class: "touchpad hidden", "aria-hidden": "true" }, zone, cluster);

  // Stick: the base jumps to where the finger lands, so the player never has
  // to find it, and drifts back to its resting spot when they let go.
  let stickId: number | null = null;
  let ox = 0;
  let oy = 0;
  const place = (x: number, y: number): void => {
    base.style.left = `${x}px`;
    base.style.top = `${y}px`;
  };
  const rest = (): void => {
    base.style.left = "";
    base.style.top = "";
    knob.style.transform = "";
    base.classList.remove("on");
  };
  const onStickDown = (e: PointerEvent): void => {
    e.preventDefault();
    if (stickId !== null) return;
    stickId = e.pointerId;
    zone.setPointerCapture?.(e.pointerId);
    const r = zone.getBoundingClientRect();
    ox = e.clientX - r.left;
    oy = e.clientY - r.top;
    place(ox, oy);
    base.classList.add("on");
    input.touch.setStick(0, 0);
  };
  const onStickMove = (e: PointerEvent): void => {
    if (e.pointerId !== stickId) return;
    e.preventDefault();
    const r = zone.getBoundingClientRect();
    let dx = e.clientX - r.left - ox;
    let dy = e.clientY - r.top - oy;
    const m = Math.hypot(dx, dy);
    if (m > STICK_RADIUS) {
      dx *= STICK_RADIUS / m;
      dy *= STICK_RADIUS / m;
    }
    knob.style.transform = `translate(${dx}px, ${dy}px)`;
    input.touch.setStick(dx / STICK_RADIUS, dy / STICK_RADIUS);
  };
  const onStickUp = (e: PointerEvent): void => {
    if (e.pointerId !== stickId) return;
    stickId = null;
    input.touch.setStick(0, 0);
    rest();
  };
  zone.addEventListener("pointerdown", onStickDown);
  zone.addEventListener("pointermove", onStickMove);
  zone.addEventListener("pointerup", onStickUp);
  zone.addEventListener("pointercancel", onStickUp);
  zone.addEventListener("lostpointercapture", onStickUp);

  // Buttons: held while any finger is on them; sliding off lets go.
  const releasers: (() => void)[] = [];
  for (const b of BUTTONS) {
    const btn = h("div", { class: `tp-btn ${b.cls}`, title: b.title, role: "button", "aria-label": b.title }, b.label);
    const fingers = new Set<number>();
    const down = (e: PointerEvent): void => {
      e.preventDefault();
      fingers.add(e.pointerId);
      btn.classList.add("on");
      input.touch.press(b.action);
    };
    const up = (e: PointerEvent): void => {
      if (!fingers.delete(e.pointerId) || fingers.size > 0) return;
      btn.classList.remove("on");
      input.touch.release(b.action);
    };
    btn.addEventListener("pointerdown", down);
    btn.addEventListener("pointerup", up);
    btn.addEventListener("pointercancel", up);
    btn.addEventListener("pointerleave", up);
    releasers.push(() => {
      fingers.clear();
      btn.classList.remove("on");
    });
    cluster.append(btn);
  }

  // No long-press menu, text selection or double-tap zoom on the overlay.
  const noMenu = (e: Event): void => e.preventDefault();
  el.addEventListener("contextmenu", noMenu);

  const letGo = (): void => {
    stickId = null;
    rest();
    for (const r of releasers) r();
    input.touch.releaseAll();
  };
  const onBlur = (): void => letGo();
  addEventListener("blur", onBlur);

  return {
    el,
    setVisible(on) {
      el.classList.toggle("hidden", !on);
      if (!on) letGo();
    },
    dispose() {
      letGo();
      removeEventListener("blur", onBlur);
      el.remove();
    },
  };
}
