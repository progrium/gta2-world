// Screen 3: the game. The map and style come from the player's own files
// (OPFS cache), the sim runs in WASM (client/wasm) and the WebGL2 renderer
// (client/render) draws it. M1 is one local player with no server: the
// browser is the authority, so the handling tuning panel can change the
// sim's numbers live.

import { ChaseCamera, Renderer } from "../../../render/ts/src/index.ts";
import type { AssetStore, MapChoice } from "../assets/store.ts";
import { GameModule } from "../game/wasm.ts";
import { Button, type Frame, encodeFrame } from "../input/i2.ts";
import { Effects, rumbleSettings, rumbleSupport } from "../input/rumble.ts";
import type { InputSystem, SchemeSetting } from "../input/system.ts";
import { FixedLoop } from "../loop.ts";
import { clear, h } from "./dom.ts";
import { openRemap } from "./remap.ts";
import { applySavedTuning, tuningPanel } from "./tuning.ts";

export interface GameScreenOpts {
  input: InputSystem;
  store: AssetStore;
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

let modulePromise: Promise<GameModule> | null = null;
const gameModule = (): Promise<GameModule> => (modulePromise ??= GameModule.load());

export function gameScreen(root: HTMLElement, o: GameScreenOpts): () => void {
  clear(root);
  const { input } = o;
  const canvas = h("canvas", { class: "view" });
  const status = h("div", { class: "status" }, "Loading map…");
  const hud = h("div", { class: "hud" });
  const padsLine = h("div", { class: "pads" });
  const playLine = h("div", { class: "mono" });
  const frameLine = h("div", { class: "mono frame small muted" });
  const fpsLine = h("span", { class: "mono small muted" });
  let paused = false;
  let overlay: HTMLElement | null = null;
  let game: GameModule | null = null;
  let renderer: Renderer | null = null;
  const camera = new ChaseCamera();
  let seed = (Date.now() & 0x7fffffff) >>> 0;
  let lastInCar = false;
  let lastSpeed = 0;
  let disposed = false;

  input.inVehicle = (slot) => (game ? game.player(slot).inCar : false);

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

  const closeOverlay = (): void => {
    overlay?.remove();
    overlay = null;
    paused = false;
  };
  const toggleTuning = (): void => {
    if (overlay) return closeOverlay();
    if (!game) return;
    overlay = tuningPanel(game, closeOverlay);
    section.append(overlay);
  };
  const respawn = (): void => {
    if (!game) return;
    seed = (seed * 1103515245 + 12345) >>> 0;
    game.start(seed);
    camera.reset();
  };
  const toggleNight = (): void => {
    if (!renderer) return;
    const night = renderer.lighting.ambient > 0.6;
    renderer.lighting = night ? { ambient: 0.35, lightGain: 1.0 } : { ambient: 1.0, lightGain: 0.35 };
  };

  hud.append(
    h(
      "div",
      { class: "hudtop" },
      h("span", {}, h("strong", {}, o.map.description), " · offline · ", fpsLine),
      h(
        "span",
        { class: "row" },
        schemeSel,
        h("label", {}, rumbleBox, " rumble"),
        h("button", { onclick: toggleTuning }, "Tuning (T)"),
        h("button", { onclick: toggleNight }, "Night (N)"),
        h("button", { onclick: () => game?.spawnCar(0) }, "Car here (V)"),
        h("button", { onclick: respawn }, "Respawn (R)"),
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
    playLine,
    frameLine,
  );

  const renderPads = (): void => {
    clear(padsLine);
    const pads = [...input.pads.pads.values()];
    if (!("getGamepads" in navigator)) padsLine.append(h("span", { class: "muted" }, "This browser has no Gamepad API; keyboard only."));
    else if (!isSecureContext) padsLine.append(h("span", { class: "warn" }, "Controllers need https or localhost."));
    else if (pads.length === 0) padsLine.append(h("span", { class: "prompt" }, "Keyboard: arrows/WASD, Enter/F get in or out, Space handbrake or jump, Shift run. Press a button on a controller to use it."));
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

  const onKey = (e: KeyboardEvent): void => {
    if (e.repeat || (e.target instanceof HTMLElement && /INPUT|SELECT|TEXTAREA/.test(e.target.tagName))) return;
    if (e.code === "KeyT") toggleTuning();
    else if (e.code === "KeyN") toggleNight();
    else if (e.code === "KeyR") respawn();
    else if (e.code === "KeyV") game?.spawnCar(0);
    else if (e.code === "Escape" && overlay) closeOverlay();
  };
  addEventListener("keydown", onKey);

  let frames = 0;
  let fpsT = performance.now();
  let lastNow = performance.now();

  const loop = new FixedLoop({
    frame: () => {
      if (!paused) input.poll();
    },
    tick: (t) => {
      if (paused || !game) return;
      const fr = input.latch(t);
      game.step(fr, t);
      const p = game.player(0);
      if (p.inCar !== lastInCar) input.rumble(0, Effects.enterExit);
      const dv = lastSpeed - p.speed;
      if (p.inCar && lastInCar && dv > 0.12) input.rumble(0, Effects.collisionHeavy);
      else if (p.inCar && lastInCar && dv > 0.05) input.rumble(0, Effects.collisionLight);
      lastInCar = p.inCar;
      lastSpeed = p.speed;
      const f = fr[0]!;
      const names = BUTTON_NAMES.filter(([bit]) => f.buttons & bit).map(([, n]) => n);
      frameLine.textContent = `I2 ${hex(f)}  steer ${f.steer} throttle ${f.throttle} aim ${f.aim} [${names.join(" ")}]`;
      const where = p.respawnTimer > 0 ? "dead, respawning" : p.inCar ? `in car · ${(p.speed * 30).toFixed(1)} blocks/s` : `on foot (${input.schemeOf(input.players[0]!)})`;
      playLine.textContent = `tick ${game.tick} · ${where} · hp ${p.hp} · kills ${p.kills} deaths ${p.deaths}`;
    },
    render: (alpha, now) => draw(alpha, now),
  });

  function draw(alpha: number, now: number): void {
    const dt = Math.min(0.1, (now - lastNow) / 1000);
    lastNow = now;
    if (!renderer || !game) return;
    renderer.resize(canvas.clientWidth, canvas.clientHeight, devicePixelRatio || 1);
    const t = game.camera(paused ? 1 : alpha, 0);
    if (t.found) camera.update({ x: t.x, y: t.y, z: t.z, speed: Math.hypot(t.vx, t.vy) * 30 }, dt);
    const list = game.renderList(paused ? 1 : alpha);
    renderer.draw(camera.view(), list.bytes, list.count, now / 1000);
    frames++;
    if (now - fpsT >= 1000) {
      fpsLine.textContent = `${((frames * 1000) / (now - fpsT)).toFixed(0)} fps`;
      frames = 0;
      fpsT = now;
    }
  }

  async function boot(): Promise<void> {
    try {
      const g = await gameModule();
      const [gmp, sty] = await Promise.all([o.store.read(o.map.gmpRecord.hash), o.store.read(o.map.styRecord.hash)]);
      if (disposed) return;
      renderer = new Renderer(canvas);
      renderer.setStyle(g.loadStyle(new Uint8Array(sty)));
      renderer.setMap(g.loadMap(new Uint8Array(gmp)));
      const tuned = applySavedTuning(g);
      game = g;
      game.start(seed);
      camera.reset();
      status.textContent = tuned ? `${tuned} tuning value${tuned === 1 ? "" : "s"} changed from the defaults (T to see).` : "";
      status.classList.toggle("hidden", !tuned);
      (window as unknown as { __game: unknown }).__game = { game, renderer, camera, input };
    } catch (e) {
      console.error("[game]", e);
      status.textContent = `Could not start: ${(e as Error).message ?? e}`;
      status.classList.add("bad");
    }
  }

  const section = h("section", { class: "screen game" }, h("div", { class: "stage" }, canvas, status), hud);
  root.append(section);
  input.allowLocalJoin = false;
  loop.start();
  void boot();

  return () => {
    disposed = true;
    loop.stop();
    offInput();
    removeEventListener("keydown", onKey);
    input.inVehicle = () => false;
    clear(root);
  };
}
