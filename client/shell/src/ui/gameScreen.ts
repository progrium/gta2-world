// Screen 3 (placeholder): the in-game view with a HUD. The renderer (workstream
// B) and the sim (A, via client/wasm) replace the canvas drawing and StubWorld;
// the input path, loop and HUD stay.

import type { MapChoice } from "../assets/store.ts";
import { Button, type Frame, encodeFrame } from "../input/i2.ts";
import { Effects } from "../input/rumble.ts";
import { rumbleSettings, rumbleSupport } from "../input/rumble.ts";
import type { InputSystem, SchemeSetting } from "../input/system.ts";
import { FixedLoop } from "../loop.ts";
import { ARENA, type Body, StubWorld } from "../sim/stub.ts";
import { clear, h } from "./dom.ts";
import { openRemap } from "./remap.ts";

export interface GameScreenOpts {
  input: InputSystem;
  sessionId: string;
  map: MapChoice;
  onBack(): void;
}

const hex = (f: Frame): string => {
  const b = new DataView(new ArrayBuffer(8));
  encodeFrame(f, b);
  return Array.from(new Uint8Array(b.buffer), (x) => x.toString(16).padStart(2, "0")).join(" ");
};

const BUTTON_NAMES: [number, string][] = Object.entries(Button).map(([k, v]) => [v, k]);

export function gameScreen(root: HTMLElement, o: GameScreenOpts): () => void {
  clear(root);
  const { input } = o;
  const world = new StubWorld();
  const canvas = h("canvas", { class: "view" });
  const ctx2d = canvas.getContext("2d")!;
  const hud = h("div", { class: "hud" });
  const padsLine = h("div", { class: "pads" });
  const frameLine = h("div", { class: "mono frame" });
  const tickLine = h("div", { class: "mono" });
  let paused = false;

  input.inVehicle = (slot) => world.players[slot]?.inVehicle ?? false;

  const schemeSel = h(
    "select",
    {
      onchange: (e: Event) => {
        input.players[0]!.scheme = (e.target as HTMLSelectElement).value as SchemeSetting;
      },
    },
    h("option", { value: "auto" }, "On foot: auto (pad direct, keys tank)"),
    h("option", { value: "tank" }, "On foot: tank"),
    h("option", { value: "direct" }, "On foot: direct"),
  ) as HTMLSelectElement;
  schemeSel.value = input.players[0]!.scheme;

  const rumbleBox = h("input", { type: "checkbox", checked: rumbleSettings.enabled, onchange: (e: Event) => (rumbleSettings.enabled = (e.target as HTMLInputElement).checked) });

  hud.append(
    h(
      "div",
      { class: "hudtop" },
      h("span", {}, h("strong", {}, o.map.description), ` · session `, h("code", {}, o.sessionId)),
      h(
        "span",
        { class: "row" },
        schemeSel,
        h("label", {}, rumbleBox, " rumble"),
        h("button", {
          onclick: () => {
            paused = true;
            openRemap(root, input, () => (paused = false));
          },
        }, "Controls"),
        h("button", { onclick: () => o.onBack() }, "Files & maps"),
      ),
    ),
    padsLine,
    tickLine,
    frameLine,
    h("p", { class: "muted small" }, "Placeholder world: a toy car and walker to try the controls. Enter/F or Y gets in and out. Real map, sim and renderer arrive with the other workstreams."),
  );

  const renderPads = (): void => {
    clear(padsLine);
    const pads = [...input.pads.pads.values()];
    if (!("getGamepads" in navigator)) padsLine.append(h("span", { class: "muted" }, "This browser has no Gamepad API; keyboard only."));
    else if (!isSecureContext) padsLine.append(h("span", { class: "warn" }, "Controllers need https or localhost."));
    else if (pads.length === 0) padsLine.append(h("span", { class: "prompt" }, "Press any button on your controller to connect it."));
    for (const p of pads) {
      const owner = input.players.find((pl) => pl.pad === p.index);
      padsLine.append(
        h(
          "span",
          { class: "chip" },
          `${owner ? `P${owner.slot + 1}` : "—"} ${p.key.name}`,
          p.mapping !== "standard" && p.bindingSource !== "saved" ? h("span", { class: "warn" }, " · needs remap") : null,
          rumbleSupport(input.pads.gamepad(p.index)) === "none" ? h("span", { class: "muted" }, " · no rumble") : null,
        ),
      );
    }
  };
  const offInput = input.on(renderPads);
  renderPads();

  const loop = new FixedLoop({
    frame: () => {
      if (!paused) input.poll();
    },
    tick: (t) => {
      if (paused) return;
      const frames = input.latch(t);
      world.step(frames);
      world.players.forEach((p, slot) => {
        if (p.toggled) input.rumble(slot, Effects.enterExit);
        if (p.impact > 6) input.rumble(slot, Effects.collisionHeavy);
        else if (p.impact > 1.5) input.rumble(slot, Effects.collisionLight);
      });
      const f = frames[0]!;
      const names = BUTTON_NAMES.filter(([bit]) => f.buttons & bit).map(([, n]) => n);
      frameLine.textContent = `I2 ${hex(f)}  steer ${f.steer} throttle ${f.throttle} aim ${f.aim} [${names.join(" ")}]`;
      tickLine.textContent = `tick ${t} · seq ${f.seq} · ${world.players[0]?.inVehicle ? "in car" : `on foot (${input.schemeOf(input.players[0]!)})`}`;
    },
    render: (alpha) => draw(alpha),
  });

  const ro = new ResizeObserver(() => {
    const r = canvas.getBoundingClientRect();
    const dpr = devicePixelRatio || 1;
    canvas.width = Math.max(1, Math.round(r.width * dpr));
    canvas.height = Math.max(1, Math.round(r.height * dpr));
  });
  ro.observe(canvas);

  const lerp = (a: Body, b: Body, t: number): Body => {
    let dh = b.heading - a.heading;
    if (dh > Math.PI) dh -= 2 * Math.PI;
    if (dh < -Math.PI) dh += 2 * Math.PI;
    return { x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, heading: a.heading + dh * t, speed: b.speed };
  };

  const css = getComputedStyle(document.documentElement);
  const color = (v: string, d: string): string => css.getPropertyValue(v).trim() || d;

  function draw(alpha: number): void {
    const W = canvas.width;
    const H = canvas.height;
    const s = Math.min(W, H) / (ARENA + 2);
    ctx2d.setTransform(1, 0, 0, 1, 0, 0);
    ctx2d.fillStyle = color("--canvas-bg", "#1b1d22");
    ctx2d.fillRect(0, 0, W, H);
    ctx2d.setTransform(s, 0, 0, s, (W - ARENA * s) / 2, (H - ARENA * s) / 2);
    ctx2d.strokeStyle = color("--grid", "#2c3038");
    ctx2d.lineWidth = 1 / s;
    for (let i = 0; i <= ARENA; i++) {
      ctx2d.beginPath();
      ctx2d.moveTo(i, 0);
      ctx2d.lineTo(i, ARENA);
      ctx2d.moveTo(0, i);
      ctx2d.lineTo(ARENA, i);
      ctx2d.stroke();
    }
    world.players.forEach((p, i) => {
      const q = world.prev[i] ?? p;
      const car = lerp(q.car, p.car, alpha);
      drawBox(car, 1.6, 0.8, i === 0 ? color("--car", "#e0a33a") : "#8a8f99");
      if (!p.inVehicle) drawBox(lerp(q.ped, p.ped, alpha), 0.45, 0.35, color("--ped", "#5ec2ff"));
    });
  }

  function drawBox(b: Body, l: number, w: number, fill: string): void {
    ctx2d.save();
    ctx2d.translate(b.x, b.y);
    ctx2d.rotate(b.heading);
    ctx2d.fillStyle = fill;
    ctx2d.fillRect(-l / 2, -w / 2, l, w);
    ctx2d.fillStyle = "#fff";
    ctx2d.fillRect(l / 2 - 0.15, -w / 4, 0.15, w / 2);
    ctx2d.restore();
  }

  root.append(h("section", { class: "screen game" }, canvas, hud));
  input.allowLocalJoin = false;
  loop.start();

  return () => {
    loop.stop();
    ro.disconnect();
    offInput();
    clear(root);
  };
}
