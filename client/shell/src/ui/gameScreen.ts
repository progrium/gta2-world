// Screen 3: the game. The map and style come from the player's own files
// (OPFS cache), the sim runs in WASM (client/wasm) and the WebGL2 renderer
// (client/render) draws it. Offline the browser is the authority, so the
// handling tuning panel can change the sim's numbers live; online
// (?server=) the game server is. M3 adds the deathmatch HUD: weapon and
// rounds, kill feed, scoreboard (Tab), round winner, and sounds for shots,
// hits, explosions and pickups.

import { ChaseCamera, Renderer } from "../../../render/ts/src/index.ts";
import type { AssetStore, MapChoice } from "../assets/store.ts";
import { audio, loadBanks } from "../audio/index.ts";
import { type Cue, type GameEvent, GameModule, MAX_PLAYERS, PICKUP_NAMES, type PlayerInfo, WEAPON_NAMES } from "../game/wasm.ts";
import type { Cue as CueName } from "../audio/cues.ts";
import { Connection } from "../net/connection.ts";
import { Button, type Frame, encodeFrame } from "../input/i2.ts";
import { Effects, rumbleSettings, rumbleSupport } from "../input/rumble.ts";
import type { InputSystem, SchemeSetting } from "../input/system.ts";
import { FixedLoop } from "../loop.ts";
import { clear, h } from "./dom.ts";
import { openRemap } from "./remap.ts";
import { soundBoard } from "./soundBoard.ts";
import { applySavedTuning, tuningPanel } from "./tuning.ts";

export interface GameScreenOpts {
  input: InputSystem;
  store: AssetStore;
  sessionId: string;
  /** Game server base URL (ws:// or http://); offline when absent. */
  server?: string | null;
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
  const weaponLine = h("div", { class: "weaponhud" });
  const feed = h("div", { class: "feed" });
  const banner = h("div", { class: "banner hidden" });
  const scores = h("div", { class: "scores hidden" });
  let showScores = false;
  let bannerUntil = 0;
  let paused = false;
  let crashed = false;
  let overlay: HTMLElement | null = null;
  let game: GameModule | null = null;
  let renderer: Renderer | null = null;
  const camera = new ChaseCamera();
  let seed = (Date.now() & 0x7fffffff) >>> 0;
  let lastInCar = false;
  let lastSpeed = 0;
  let lastButtons = 0;
  let disposed = false;
  // Online state
  let conn: Connection | null = null;
  let online = false;
  let ownSlot = 0;
  let pendingButtons = 0;
  let netLine = "";
  const names = new Map<number, string>();

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
    (overlay as (HTMLElement & { dispose?: () => void }) | null)?.dispose?.();
    overlay?.remove();
    overlay = null;
    paused = false;
  };
  const toggleTuning = (): void => {
    if (overlay) return closeOverlay();
    if (!game || o.server) return;
    overlay = tuningPanel(game, closeOverlay);
    section.append(overlay);
  };
  const toggleSound = (): void => {
    if (overlay) return closeOverlay();
    overlay = soundBoard(audio, closeOverlay);
    // Offline the board pauses the game; online the world keeps going.
    paused = !o.server;
    section.append(overlay);
  };
  const respawn = (): void => {
    if (!game || o.server) return;
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
      h("span", {}, h("strong", {}, o.map.description), o.server ? h("span", {}, " · online ", h("code", {}, o.sessionId), " · ") : " · offline · ", fpsLine),
      h(
        "span",
        { class: "row" },
        schemeSel,
        h("label", {}, rumbleBox, " rumble"),
        o.server ? null : h("button", { onclick: toggleTuning }, "Tuning (T)"),
        h("button", { onclick: toggleNight }, "Night (N)"),
        h("button", { onclick: toggleSound }, "Sound (B)"),
        o.server ? null : h("button", { onclick: () => game?.spawnCar(0) }, "Car here (V)"),
        o.server ? null : h("button", { onclick: () => dropPickup() }, "Pickup here (P)"),
        o.server ? null : h("button", { onclick: respawn }, "Respawn (R)"),
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
    else if (pads.length === 0) padsLine.append(h("span", { class: "prompt" }, "Keyboard: arrows/WASD, Enter/F get in or out, Ctrl/J fire, Z/X weapons, Space handbrake or jump, Shift run, Tab scores. Press a button on a controller to use it."));
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

  const onKeyUp = (e: KeyboardEvent): void => {
    if (e.code === "Tab") showScores = false;
  };
  addEventListener("keyup", onKeyUp);
  const onKey = (e: KeyboardEvent): void => {
    if (e.code === "Tab") {
      e.preventDefault();
      showScores = true;
      return;
    }
    if (e.repeat || (e.target instanceof HTMLElement && /INPUT|SELECT|TEXTAREA/.test(e.target.tagName))) return;
    if (e.code === "KeyT") toggleTuning();
    else if (e.code === "KeyN") toggleNight();
    else if (e.code === "KeyB") toggleSound();
    else if (e.code === "KeyM") audio.toggleMute();
    else if (e.code === "KeyR") respawn();
    else if (e.code === "KeyV" && !o.server) game?.spawnCar(0);
    else if (e.code === "KeyP" && !o.server) dropPickup();
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
      if (paused || !game || online || o.server) return;
      const fr = input.latch(t);
      game.step(fr, t);
      for (const e of game.takeEvents()) onGameEvent(e);
      afterTick(fr[0]!, 0);
    },
    render: (alpha, now) => {
      if (crashed) return;
      try {
        if (online && game && !paused) netFrame(now);
        draw(online ? 1 : alpha, now);
      } catch (e) {
        // Say so instead of leaving a frozen grey canvas.
        crashed = true;
        console.error("[game]", e);
        status.textContent = `The game stopped: ${(e as Error).message ?? e}. Reload the page; "Files & maps" has a button to clear cached files.`;
        status.classList.remove("hidden");
        status.classList.add("bad");
      }
    },
  });

  function netFrame(now: number): void {
    const g = game!;
    const f = { ...input.latch(g.tick)[0]! };
    f.buttons |= pendingButtons;
    const n = g.netUpdate(now, f);
    if (n === 0) {
      pendingButtons = f.buttons;
      return;
    }
    pendingButtons = 0;
    const msg = g.netInput(now);
    if (msg) conn?.sendInput(msg);
    afterTick(f, ownSlot);
    const st = g.netStats();
    const others = [...names.entries()].filter(([s]) => s !== ownSlot).map(([, nm]) => nm);
    netLine = ` · ${conn?.transport ?? ""} · rtt ${st.rttMs} ms · replay ≤${st.maxReplay} · ${others.length ? `with ${others.join(", ")}` : "alone"}`;
  }

  function afterTick(f: Frame, slot: number): void {
    const g = game!;
    {
      const p = g.player(slot);
      if (p.inCar !== lastInCar) {
        input.rumble(0, Effects.enterExit);
        audio.play("car_door");
      }
      const dv = lastSpeed - p.speed;
      if (p.inCar && lastInCar && dv > 0.12) {
        input.rumble(0, Effects.collisionHeavy);
        audio.play("car_crash");
      } else if (p.inCar && lastInCar && dv > 0.05) input.rumble(0, Effects.collisionLight);
      if (p.inCar) audio.setEngine(slot, p.speed);
      if (f.buttons & Button.special && p.inCar && !(lastButtons & Button.special)) audio.play("horn");
      lastButtons = f.buttons;
      lastInCar = p.inCar;
      lastSpeed = p.speed;
      const bnames = BUTTON_NAMES.filter(([bit]) => f.buttons & bit).map(([, n]) => n);
      frameLine.textContent = `I2 ${hex(f)}  steer ${f.steer} throttle ${f.throttle} aim ${f.aim} [${bnames.join(" ")}]`;
      const where = p.respawnTimer > 0 ? "dead, respawning" : p.inCar ? `in car · ${(p.speed * 30).toFixed(1)} blocks/s` : `on foot (${input.schemeOf(input.players[0]!)})`;
      playLine.textContent = `tick ${g.tick} · ${where} · hp ${p.hp} · frags ${p.kills} · ${p.score} pts · deaths ${p.deaths}${online ? netLine : ""}`;
      weaponLine.textContent = p.respawnTimer > 0 ? "" : hudLine(p);
    }
  }

  function draw(alpha: number, now: number): void {
    const dt = Math.min(0.1, (now - lastNow) / 1000);
    lastNow = now;
    if (!renderer || !game) return;
    renderer.resize(canvas.clientWidth, canvas.clientHeight, devicePixelRatio || 1);
    const t = game.camera(paused ? 1 : alpha, ownSlot);
    if (t.found) {
      camera.update({ x: t.x, y: t.y, z: t.z, vx: t.vx, vy: t.vy, inCar: lastInCar }, dt);
      audio.setListener(t.x, t.y, t.z);
    }
    const list = game.renderList(paused ? 1 : alpha, now);
    renderer.draw(camera.view(), list.bytes, list.count, now / 1000);
    for (const c of game.takeCues()) playCue(c);
    if (bannerUntil && now > bannerUntil) {
      bannerUntil = 0;
      banner.classList.add("hidden");
    }
    renderScores();
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
      // Car handling from the player's .gci (nyc.gci), if imported. Online
      // games use the one default model until the server loads car info.
      if (o.server) g.useDefaultCars();
      else {
        const gciRec = o.store.manifest.files.find((f) => f.kind === "gci");
        const gci = gciRec ? new Uint8Array(await o.store.read(gciRec.hash)) : null;
        const cars = g.loadCarInfo(gci);
        if (!gci) console.info(`[cars] ${cars} models from the style; no .gci imported, default handling`);
      }
      renderer.setMap(g.loadMap(new Uint8Array(gmp)));
      void loadBanks(o.store, o.map).catch((e) => console.warn("[audio] banks", e));
      if (o.server) {
        game = g;
        await connect(g);
        return;
      }
      g.netStop();
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

  function connect(g: GameModule): Promise<void> {
    status.textContent = `Connecting to ${o.server}…`;
    status.classList.remove("hidden");
    return new Promise((resolve) => {
      conn = new Connection(
        { server: o.server!, transport: transportParam(), session: o.sessionId, layoutHash: g.layoutHash, mapHash: o.map.gmpRecord.hash, name: playerName() },
        {
          welcome: (w) => {
            ownSlot = w.slots[0]!;
            g.netStart(ownSlot, w.inputBufferTicks);
            online = true;
            camera.reset();
            status.textContent = `Joined as player ${ownSlot + 1}. Waiting for the world…`;
            (window as unknown as { __game: unknown }).__game = { game: g, renderer, camera, input, conn, slot: () => ownSlot };
            resolve();
          },
          snapshot: (body, baseline) => {
            g.netSnapshot(body, performance.now());
            if (baseline) {
              status.textContent = "";
              status.classList.add("hidden");
            }
          },
          playerInfo: (p) => {
            if (p.flags & 1) names.set(p.slot, p.name || `player ${p.slot + 1}`);
            else names.delete(p.slot);
          },
          event: (e) => onGameEvent({ kind: e.kind, a: e.a, b: e.b, c: e.c, x: e.x / 65536, y: e.y / 65536, z: e.z / 65536 }),
          reject: (_code, message) => {
            status.textContent = `The server refused: ${message}`;
            status.classList.add("bad");
          },
          closed: (reason) => {
            online = false;
            if (!disposed && !status.classList.contains("bad")) {
              status.textContent = `Disconnected: ${reason}. Reload to rejoin.`;
              status.classList.remove("hidden");
              status.classList.add("bad");
            }
            resolve();
          },
        },
      );
    });
  }

  // ---------------------------------------------------------------- M3 HUD

  const nameOf = (slot: number): string => {
    if (slot === 0xff) return "the city";
    if (!online && !o.server) return slot === 0 ? "You" : `Player ${slot + 1}`;
    if (slot === ownSlot) return "You";
    return names.get(slot) ?? `Player ${slot + 1}`;
  };
  const weaponWord = (c: number): string => (c === 0x80 ? "a car" : c === 0x81 ? "fire" : (WEAPON_NAMES[c] ?? "?").toLowerCase());
  // Shot sounds by weapon; none for the silenced gun, the streams (one cue
  // a tick would be noise) and throws.
  const SHOT_CUES: (CueName | null)[] = ["pistol", "machine_gun", "shotgun", "rocket_launch", "pistol", null, null, null, null, null];
  const secs = (ticks: number): number => Math.ceil(ticks / 30);
  // Debug: each press drops the next kind of pickup, weapons then power-ups.
  let nextPickup = 1;
  function dropPickup(): void {
    if (!game || online || o.server) return;
    game.spawnPickup(nextPickup);
    nextPickup = nextPickup + 1 >= WEAPON_NAMES.length + PICKUP_NAMES.length ? 1 : nextPickup + 1;
  }
  function hudLine(p: PlayerInfo): string {
    const parts = [`${WEAPON_NAMES[p.weapon] ?? "?"}${p.rounds < 0 ? "" : ` · ${p.rounds}`}`];
    if (p.charge > 0) parts.push(`throw ${"▮".repeat(Math.min(6, Math.ceil(p.charge / 10)))}`);
    parts.push(`♥ ${Math.max(0, p.hp)}`);
    if (p.armour > 0) parts.push(`armour ${p.armour}`);
    if (p.invulnerable > 0) parts.push(`invulnerable ${secs(p.invulnerable)}s`);
    if (p.doubleDamage > 0) parts.push(`double damage ${secs(p.doubleDamage)}s`);
    if (p.fastReload > 0) parts.push(`fast reload ${secs(p.fastReload)}s`);
    if (p.burning) parts.push("on fire!");
    parts.push(`frags ${p.kills}/10 · ${p.score.toLocaleString("en-US")} pts`);
    return parts.join(" · ");
  }

  function feedLine(text: string, mine = false): void {
    const line = h("div", { class: mine ? "mine" : "" }, text);
    feed.prepend(line);
    while (feed.childElementCount > 5) feed.lastElementChild?.remove();
    setTimeout(() => line.remove(), 6000);
  }

  function onGameEvent(e: GameEvent): void {
    const g = game;
    const now = performance.now();
    switch (e.kind) {
      case 1: {
        // kill: a killer (0xFF none), b victim, c weapon
        const victim = nameOf(e.b);
        const mine = e.a === ownSlot || e.b === ownSlot;
        if (e.a === e.b) feedLine(`${victim} ${e.b === ownSlot ? "killed yourself" : "died by their own hand"}`, mine);
        else if (e.a === 0xff) feedLine(`${victim} ${e.b === ownSlot ? "were" : "was"} killed by ${weaponWord(e.c)}`, mine);
        else feedLine(`${nameOf(e.a)} killed ${victim === "You" ? "you" : victim} with ${weaponWord(e.c)}`, mine);
        if (e.b === ownSlot) {
          audio.play("ped_death");
          input.rumble(0, Effects.collisionHeavy);
        }
        break;
      }
      case 2:
        if (e.a !== ownSlot) feedLine(`${nameOf(e.a)} joined`);
        break;
      case 3:
        feedLine(`${nameOf(e.a)} left`);
        break;
      case 4: {
        g?.explosion(e.x, e.y, e.z, now);
        audio.play("explosion", e.x, e.y, e.z);
        const t = g?.camera(1, ownSlot);
        if (t?.found && Math.hypot(t.x - e.x, t.y - e.y) < 6) input.rumble(0, Effects.collisionHeavy);
        // Shake the view for explosions on or near the screen.
        if (t?.found && Math.hypot(t.x - e.x, t.y - e.y) < 12) camera.shake();
        break;
      }
      case 5:
        banner.textContent = e.a === ownSlot ? "You win the round!" : `${nameOf(e.a)} wins the round`;
        banner.classList.remove("hidden");
        bannerUntil = now + 6000;
        feedLine(`Round over: ${nameOf(e.a)} won. Scores reset.`, e.a === ownSlot);
        break;
      case 6:
        if (e.a === ownSlot) {
          audio.play("pickup", e.x, e.y, e.z);
          feedLine(e.b < WEAPON_NAMES.length ? WEAPON_NAMES[e.b]! : (PICKUP_NAMES[e.b - WEAPON_NAMES.length] ?? "Power-up"), true);
        }
        break;
    }
  }

  function playCue(c: Cue): void {
    if (c.kind === 1) {
      const name = c.a < SHOT_CUES.length ? SHOT_CUES[c.a] : "pistol";
      if (name) audio.play(name, c.x, c.y, c.z);
    }
    else if (c.kind === 2) audio.play("ped_hurt", c.x, c.y, c.z);
    else if (c.kind === 3) audio.play("bullet_hit", c.x, c.y, c.z);
    else if (c.kind === 4) audio.play("weapon_switch");
  }

  let scoresKey = "";
  function renderScores(): void {
    const g = game;
    const show = (showScores || bannerUntil > 0) && !!g;
    scores.classList.toggle("hidden", !show);
    if (!show || !g) return;
    const rows: { slot: number; score: number; kills: number; deaths: number }[] = [];
    for (let s = 0; s < MAX_PLAYERS; s++) {
      const p = g.player(s);
      if (p.active) rows.push({ slot: s, score: p.score, kills: p.kills, deaths: p.deaths });
    }
    rows.sort((a, b) => b.kills - a.kills || b.score - a.score || a.deaths - b.deaths || a.slot - b.slot);
    const key = JSON.stringify(rows) + [...names.entries()].join();
    if (key === scoresKey) return;
    scoresKey = key;
    clear(scores);
    scores.append(
      h(
        "table",
        {},
        h("tr", {}, h("th", {}, "Player"), h("th", {}, "Frags"), h("th", {}, "Points"), h("th", {}, "Deaths")),
        ...rows.map((r) => h("tr", { class: r.slot === ownSlot ? "mine" : "" }, h("td", {}, nameOf(r.slot)), h("td", {}, String(r.kills)), h("td", {}, r.score.toLocaleString("en-US")), h("td", {}, String(r.deaths)))),
      ),
      h("div", { class: "muted small" }, "First to 10 frags wins the round. Points: 2,000 a player shot, 1,000 run over, 5,000 electrocuted; civilians, car hits, hijacks and wrecks score too. Hold Tab for scores."),
    );
  }

  const section = h("section", { class: "screen game" }, h("div", { class: "stage" }, canvas, status, weaponLine, feed, banner, scores), hud);
  root.append(section);
  input.allowLocalJoin = false;
  loop.start();
  void boot();

  return () => {
    disposed = true;
    conn?.close("leaving");
    game?.netStop();
    loop.stop();
    closeOverlay();
    audio.stopAll();
    offInput();
    removeEventListener("keydown", onKey);
    removeEventListener("keyup", onKeyUp);
    input.inVehicle = () => false;
    clear(root);
  };
}

function playerName(): string {
  try {
    const n = localStorage.getItem("gta2.name");
    if (n) return n;
  } catch {
    /* ignore */
  }
  return `player-${Math.floor(Math.random() * 900 + 100)}`;
}

function transportParam(): "auto" | "webtransport" | "websocket" {
  const t = new URLSearchParams(location.search).get("transport");
  return t === "webtransport" || t === "websocket" ? t : "auto";
}
