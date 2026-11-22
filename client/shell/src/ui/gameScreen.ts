// Screen 3: the game. The map and style come from the player's own files
// (OPFS cache), the sim runs in WASM (client/wasm) and the WebGL2 renderer
// (client/render) draws it. Offline the browser is the authority, so the
// handling tuning panel can change the sim's numbers live; online
// (?server=) the game server is. M3 adds the deathmatch HUD: weapon and
// rounds, kill feed, scoreboard (Tab), round winner, and sounds for shots,
// hits, explosions and pickups. A browser-hosted game passes `net` instead of
// `server`: the host's page plays over the in-page loopback, a joiner over
// its WebRTC connection to the host's page.

import { ChaseCamera, Renderer } from "../../../render/ts/src/index.ts";
import type { AssetStore, MapChoice } from "../assets/store.ts";
import { audio, loadBanks } from "../audio/index.ts";
import { type Cue, type GameEvent, GameModule, type SoundSource, MAX_PLAYERS, PICKUP_NAMES, type PlayerInfo, WEAPON_NAMES } from "../game/wasm.ts";
import type { Cue as CueName } from "../audio/cues.ts";
import { type ConnectOptions, Connection } from "../net/connection.ts";
import { Button, type Frame, encodeFrame } from "../input/i2.ts";
import { Effects, rumbleSettings, rumbleSupport } from "../input/rumble.ts";
import type { InputSystem, SchemeSetting } from "../input/system.ts";
import { FixedLoop } from "../loop.ts";
import { clear, h } from "./dom.ts";
import { soundCheck } from "./soundCheck.ts";
import { openRemap } from "./remap.ts";
import { soundBoard } from "./soundBoard.ts";
import { applySavedTuning, tuningPanel } from "./tuning.ts";
import { SpHudView } from "./spHud.ts";
import { textChoice } from "./importScreen.ts";
import { deathKey } from "../game/text.ts";
import { demoHud } from "./spDemo.ts";

export interface GameScreenOpts {
  input: InputSystem;
  store: AssetStore;
  sessionId: string;
  /** Game server base URL (ws:// or http://); offline when absent. */
  server?: string | null;
  /** A browser-hosted game: the link to use, and a label for the HUD. */
  net?: Pick<ConnectOptions, "transport" | "rtc" | "loopback"> & { label: string };
  /** Extra HUD content, e.g. the host's join link and player list. */
  extraHud?: HTMLElement;
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
  // Online (a game server or a browser host): the authority is elsewhere.
  const remote = !!o.server || !!o.net;
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
  // Single player: a story level offline (the SP sim, its script and text).
  const sp = !!o.map.story && !remote;
  const hudDemo = new URLSearchParams(location.search).has("hudtest");
  const spHud = sp ? new SpHudView({ text: (id) => game?.text(id) ?? null, textKey: (k) => game?.textKey(k) ?? null }) : null;
  /** The camera holds on the body (wasted or busted) until this tick. */
  let holdUntil = 0;
  let holdAt: { x: number; y: number; z: number } | null = null;
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
  let lastScreech = 0;
  let disposed = false;
  // Online state
  let conn: Connection | null = null;
  let online = false;
  let ownSlot = 0;
  let pendingButtons = 0;
  let netLine = "";
  const names = new Map<number, string>();

  // Local slot 0 is the sim's ownSlot when online; reading slot 0 there gave the
  // host's player, so the other player getting out of a car switched this
  // player's controls to on-foot (tank/direct) while still driving.
  input.inVehicle = (slot) => (game ? game.player(slot === 0 ? ownSlot : slot).inCar : false);

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

  const padBox = h("input", {
    type: "checkbox",
    checked: input.padsEnabled,
    title: "Turn off to stop this tab reading controllers, e.g. when two windows on one computer play each other.",
    onchange: (e: Event) => (input.padsEnabled = (e.target as HTMLInputElement).checked),
  });
  const rumbleBox = h("input", { type: "checkbox", checked: rumbleSettings.enabled, onchange: (e: Event) => (rumbleSettings.enabled = (e.target as HTMLInputElement).checked) });

  const closeOverlay = (): void => {
    (overlay as (HTMLElement & { dispose?: () => void }) | null)?.dispose?.();
    overlay?.remove();
    overlay = null;
    paused = false;
  };
  const toggleTuning = (): void => {
    if (overlay) return closeOverlay();
    if (!game || remote) return;
    overlay = tuningPanel(game, closeOverlay);
    section.append(overlay);
  };
  const toggleSound = (): void => {
    if (overlay) return closeOverlay();
    overlay = soundBoard(audio, closeOverlay);
    // Offline the board pauses the game; online the world keeps going.
    paused = !remote;
    section.append(overlay);
  };
  const respawn = (): void => {
    if (!game || remote) return;
    seed = (seed * 1103515245 + 12345) >>> 0;
    if (sp) game.startSp(seed);
    else game.start(seed);
    camera.reset();
    spHud?.reset();
    holdUntil = 0;
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
      h("span", {}, h("strong", {}, o.map.description), remote ? h("span", {}, " · online ", h("code", {}, o.net?.label ?? o.sessionId), " · ") : " · offline · ", fpsLine),
      h(
        "span",
        { class: "row" },
        schemeSel,
        h("label", { title: "Turn off to stop this tab reading controllers, e.g. when two windows on one computer play each other." }, padBox, " controller"),
        h("label", {}, rumbleBox, " rumble"),
        remote ? null : h("button", { onclick: toggleTuning }, "Tuning (T)"),
        h("button", { onclick: toggleNight }, "Night (N)"),
        h("button", { onclick: toggleSound }, "Sound (B)"),
        remote ? null : h("button", { onclick: () => game?.spawnCar(0) }, "Car here (V)"),
        remote ? null : h("button", { onclick: () => dropPickup() }, "Pickup here (P)"),
        remote ? null : h("button", { onclick: respawn }, sp ? "Restart level (R)" : "Respawn (R)"),
        h("button", {
          onclick: () => {
            paused = true;
            openRemap(root, input, () => (paused = false));
          },
        }, "Controls"),
        h("button", { onclick: () => o.onBack() }, o.net ? (o.net.transport === "loopback" ? "Host panel" : "Leave") : "Files & maps"),
      ),
    ),
    ...(o.extraHud ? [o.extraHud] : []),
    padsLine,
    playLine,
    frameLine,
  );

  const renderPads = (): void => {
    clear(padsLine);
    const pads = [...input.pads.pads.values()];
    if (!("getGamepads" in navigator)) padsLine.append(h("span", { class: "muted" }, "This browser has no Gamepad API; keyboard only."));
    else if (!isSecureContext) padsLine.append(h("span", { class: "warn" }, "Controllers need https or localhost."));
    else if (!input.padsEnabled) padsLine.append(h("span", { class: "chip" }, "Controller off in this tab · keyboard only"));
    else if (pads.length === 0) padsLine.append(h("span", { class: "prompt" }, "Keyboard: arrows/WASD, Enter/F get in or out, Ctrl/J fire, Z/X weapons, Space handbrake or jump, Shift run, Tab scores. Press a button on a controller to use it."));
    if (!input.padsEnabled) return;
    for (const p of pads) {
      const owner = input.players.find((pl) => pl.pad === p.index);
      padsLine.append(
        h(
          "span",
          { class: "chip" },
          `${owner ? `P${owner.slot + 1}` : "—"} ${p.key.name}`,
          p.mapping !== "standard" && p.bindingSource !== "saved" ? h("span", { class: "warn" }, " · needs remap") : null,
          rumbleSupport(input.pads.gamepad(p.index)) === "none" ? h("span", { class: "muted" }, " · no rumble") : null,
          !input.padsLive() ? h("span", { class: "muted" }, " · paused while this window isn't focused") : null,
        ),
      );
    }
  };
  const offInput = input.on(() => {
    padBox.checked = input.padsEnabled;
    renderPads();
  });
  addEventListener("focus", renderPads);
  addEventListener("blur", renderPads);
  renderPads();

  const onKeyUp = (e: KeyboardEvent): void => {
    if (e.code === "Tab") showScores = false;
  };
  addEventListener("keyup", onKeyUp);
  const onKey = (e: KeyboardEvent): void => {
    if (e.code === "Tab") {
      e.preventDefault();
      if (sp) return;
      showScores = true;
      return;
    }
    if (e.repeat || (e.target instanceof HTMLElement && /INPUT|SELECT|TEXTAREA/.test(e.target.tagName))) return;
    if (e.code === "KeyT") toggleTuning();
    else if (e.code === "KeyN") toggleNight();
    else if (e.code === "KeyB") toggleSound();
    else if (e.code === "KeyM") audio.toggleMute();
    else if (e.code === "KeyR") respawn();
    else if (e.code === "KeyV" && !remote) game?.spawnCar(0);
    else if (e.code === "KeyP" && !remote) dropPickup();
    else if (e.code === "Escape" && overlay) closeOverlay();
  };
  addEventListener("keydown", onKey);

  let frames = 0;
  let fpsT = performance.now();
  let lastNow = performance.now();

  const loop = new FixedLoop({
    // Hidden tab (the other tab of a two-tab game is in front): keep sending
    // input so the host doesn't time this player out after 5 s.
    background: (now) => {
      if (crashed || !online || !game || paused) return;
      try {
        netFrame(now);
      } catch (e) {
        console.warn("[game] background net frame", e);
      }
    },
    frame: () => {
      if (!paused) input.poll();
    },
    tick: (t) => {
      if (paused || !game || online || remote) return;
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
        crashSound("car_crash");
      } else if (p.inCar && lastInCar && dv > 0.05) {
        input.rumble(0, Effects.collisionLight);
        crashSound("car_bump");
      }
      // Hard steering at speed; at most once every half second.
      if (p.inCar && p.speed > 0.2 && Math.abs(f.steer) > 100 && performance.now() - lastScreech > 500) {
        lastScreech = performance.now();
        audio.play("tyre_screech");
      }
      if (f.buttons & Button.special && p.inCar && !(lastButtons & Button.special)) audio.play("horn");
      lastButtons = f.buttons;
      lastInCar = p.inCar;
      lastSpeed = p.speed;
      const bnames = BUTTON_NAMES.filter(([bit]) => f.buttons & bit).map(([, n]) => n);
      frameLine.textContent = `I2 ${hex(f)}  steer ${f.steer} throttle ${f.throttle} aim ${f.aim} [${bnames.join(" ")}]`;
      const where = p.respawnTimer > 0 || (sp && game!.tick < holdUntil) ? "dead, respawning" : p.inCar ? `in car · ${(p.speed * 30).toFixed(1)} blocks/s` : `on foot (${input.schemeOf(input.players[0]!)})`;
      playLine.textContent = sp ? `tick ${g.tick} · ${where} · hp ${p.hp}` : `tick ${g.tick} · ${where} · hp ${p.hp} · frags ${p.kills} · ${p.score} pts · deaths ${p.deaths}${online ? netLine : ""}`;
      weaponLine.textContent = p.respawnTimer > 0 ? "" : hudLine(p);
    }
  }

  function draw(alpha: number, now: number): void {
    const dt = Math.min(0.1, (now - lastNow) / 1000);
    lastNow = now;
    if (!renderer || !game) return;
    renderer.resize(canvas.clientWidth, canvas.clientHeight, devicePixelRatio || 1);
    const t = game.camera(paused ? 1 : alpha, ownSlot);
    const holding = sp && holdAt !== null && game.tick < holdUntil;
    if (holding) {
      // Wasted or busted: watch the body, pulled back (camera.md 3.2).
      camera.update({ x: holdAt!.x, y: holdAt!.y, z: holdAt!.z, dead: true }, dt);
      audio.setListener(holdAt!.x, holdAt!.y, holdAt!.z);
    } else if (t.found) {
      camera.update({ x: t.x, y: t.y, z: t.z, vx: t.vx, vy: t.vy, inCar: lastInCar }, dt);
      audio.setListener(t.x, t.y, t.z);
    }
    if (spHud) spHud.update(hudDemo ? demoHud(game.tick) : game.spInfo(), t.found ? { x: t.x, y: t.y } : null);
    const list = game.renderList(paused ? 1 : alpha, now);
    renderer.draw(camera.view(), list.bytes, list.count, now / 1000);
    for (const c of game.takeCues()) playCue(c);
    soundTick(game, dt);
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
      if (remote) g.useDefaultCars();
      else {
        const gciRec = o.store.manifest.files.find((f) => f.kind === "gci");
        const gci = gciRec ? new Uint8Array(await o.store.read(gciRec.hash)) : null;
        const cars = g.loadCarInfo(gci);
        if (!gci) console.info(`[cars] ${cars} models from the style; no .gci imported, default handling`);
      }
      renderer.setMap(g.loadMap(new Uint8Array(gmp)));
      if (sp) await loadLevelFiles(g);
      void loadBanks(o.store, o.map).catch((e) => console.warn("[audio] banks", e));
      if (remote) {
        game = g;
        await connect(g);
        return;
      }
      g.netStop();
      const tuned = applySavedTuning(g);
      game = g;
      if (sp) game.startSp(seed);
      else game.start(seed);
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

  /** A story level's text (.gxt) and scripts (main .scr and mission sub-scripts) into the game module. */
  async function loadLevelFiles(g: GameModule): Promise<void> {
    if (!g.hasSinglePlayer) throw new Error("this game.wasm has no single player; reload the page");
    const files = o.store.manifest.files;
    const gxtName = textChoice(files);
    const gxt = gxtName ? files.find((f) => f.name === gxtName) : null;
    if (gxt) g.loadText(new Uint8Array(await o.store.read(gxt.hash)));
    else console.info("[text] no .gxt imported; messages show their numbers");
    g.clearScripts();
    const scripts = o.store.scripts(o.map);
    for (const f of scripts) g.addScript(f.name, new Uint8Array(await o.store.read(f.hash)));
    console.info(`[level] ${o.map.description}: ${scripts.length} script file${scripts.length === 1 ? "" : "s"}, text ${gxtName ?? "none"}`);
  }

  function connect(g: GameModule): Promise<void> {
    status.textContent = `Connecting to ${o.net?.label ?? o.server}…`;
    status.classList.remove("hidden");
    return new Promise((resolve) => {
      conn = new Connection(
        { server: o.server ?? undefined, transport: o.net?.transport ?? transportParam(), rtc: o.net?.rtc, loopback: o.net?.loopback, session: o.sessionId, layoutHash: g.layoutHash, mapHash: o.map.gmpRecord.hash, name: playerName() },
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
    if (!online && !remote) return slot === 0 ? "You" : `Player ${slot + 1}`;
    if (slot === ownSlot) return "You";
    return names.get(slot) ?? `Player ${slot + 1}`;
  };
  const weaponWord = (c: number): string => (c === 0x80 ? "a car" : c === 0x81 ? "fire" : (WEAPON_NAMES[c] ?? "?").toLowerCase());
  // Shot sounds by weapon; none for the silenced gun, the streams (one cue
  // a tick would be noise) and throws.
  // By weapon id (WEAPON_NAMES order).
  const SHOT_CUES: CueName[] = ["pistol", "machine_gun", "shotgun", "rocket_launch", "dual_pistol", "silenced_mg", "flamethrower", "electro_gun", "grenade_throw", "molotov_throw"];
  // What the announcer says for each pickup kind: weapons, then PICKUP_NAMES.
  const SAY_PICKUP: CueName[] = [
    "say_pistol", "say_machine_gun", "say_shotgun", "say_rocket_launcher", "say_dual_pistol", "say_silenced_mg", "say_flamethrower", "say_electro_gun", "say_grenades", "say_molotovs",
    "say_health", "say_armour", "say_invulnerability", "say_double_damage", "say_fast_reload",
  ];
  const secs = (ticks: number): number => Math.ceil(ticks / 30);
  // Debug: each press drops the next kind of pickup, weapons then power-ups.
  let nextPickup = 1;
  function dropPickup(): void {
    if (!game || online || remote) return;
    game.spawnPickup(nextPickup);
    nextPickup = nextPickup + 1 >= WEAPON_NAMES.length + PICKUP_NAMES.length ? 1 : nextPickup + 1;
  }
  function hudLine(p: PlayerInfo): string {
    const parts = [p.rounds === 0 ? "Unarmed" : `${WEAPON_NAMES[p.weapon] ?? "?"}${p.rounds < 0 ? "" : ` · ${p.rounds}`}`];
    if (p.charge > 0) parts.push(`throw ${"▮".repeat(Math.min(6, Math.ceil(p.charge / 10)))}`);
    parts.push(`♥ ${Math.max(0, p.hp)}`);
    if (p.armour > 0) parts.push(`armour ${p.armour}`);
    if (p.invulnerable > 0) parts.push(`invulnerable ${secs(p.invulnerable)}s`);
    if (p.doubleDamage > 0) parts.push(`double damage ${secs(p.doubleDamage)}s`);
    if (p.fastReload > 0) parts.push(`fast reload ${secs(p.fastReload)}s`);
    if (p.burning) parts.push("on fire!");
    if (!sp) parts.push(`frags ${p.kills}/10 · ${p.score.toLocaleString("en-US")} pts`);
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
        if (e.a === ownSlot && e.b !== ownSlot) audio.play("frag_taunt");
        if (e.b === ownSlot) {
          audio.play("ped_death");
          input.rumble(0, Effects.collisionHeavy);
        }
        break;
      }
      case 2:
        if (e.a !== ownSlot) {
          feedLine(`${nameOf(e.a)} joined`);
          audio.play("player_joined");
        }
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
        audio.play("round_end");
        break;
      case 6:
        if (e.a === ownSlot) {
          const extra = e.b - WEAPON_NAMES.length;
          audio.play(extra < 0 ? "pickup" : extra === 0 ? "pickup_health" : extra === 1 ? "pickup_armour" : "pickup_powerup", e.x, e.y, e.z);
          const say = SAY_PICKUP[e.b];
          if (say) audio.play(say);
          feedLine(e.b < WEAPON_NAMES.length ? WEAPON_NAMES[e.b]! : (PICKUP_NAMES[e.b - WEAPON_NAMES.length] ?? "Power-up"), true);
        }
        break;
      case 15:
        // a phone; a = 1 while ringing
        if (e.a === 1) audio.play("phone_ring", e.x, e.y, e.z);
        break;
      case 16:
        // a vehicle's siren; a = 1 switched on
        if (e.a === 1) audio.play("siren", e.x, e.y, e.z);
        break;
      case 19:
        // police voice: a = 0 a cop shouts ("Freeze!"), 1 radio chatter
        audio.play(e.a === 0 ? "cop_shout" : "police_radio", e.x, e.y, e.z);
        break;
      default:
        if (spHud && g && e.a === ownSlot) onSpEvent(e, g);
    }
  }

  /** Single-player events (I3 kinds 9-18, wire.zig). */
  function onSpEvent(e: GameEvent, g: GameModule): void {
    const tick = g.tick;
    const hold = (): void => {
      const t = g.camera(1, ownSlot);
      holdAt = e.x || e.y ? { x: e.x, y: e.y, z: e.z } : t.found ? { x: t.x, y: t.y, z: t.z } : null;
      holdUntil = tick + 70;
    };
    switch (e.kind) {
      case 8:
        audio.play("pager");
        break;
      case 9:
        if (e.b > e.c) {
          input.rumble(0, Effects.collisionLight);
          audio.play("wanted_up");
        } else if (e.b < e.c) audio.play("wanted_down");
        break;
      case 10:
        hold();
        spHud!.showCentre(spHud!.keyText(deathKey(e.b)), tick, 70, "wasted");
        audio.play("wasted");
        input.rumble(0, Effects.collisionHeavy);
        break;
      case 11:
        hold();
        spHud!.showCentre(spHud!.keyText("nicked"), tick, 70, "busted");
        audio.play("busted");
        break;
      case 12:
        feedLine("Job started", true);
        audio.play("mission_start");
        break;
      case 13:
        feedLine("Job passed", true);
        audio.play("mission_pass");
        break;
      case 14:
        feedLine("Job failed", true);
        audio.play("mission_fail");
        break;
      case 17:
        // On the last life this comes instead of wasted, at the body.
        if (e.x || e.y) hold();
        spHud!.showCentre(spHud!.keyText("g_over"), tick, 1 << 30, "over");
        audio.play("game_over");
        break;
      case 18:
        spHud!.showCentre(spHud!.keyText("gam_cmp"), tick, 1 << 30, "done");
        audio.play("level_complete");
        break;
    }
  }

  // One crash sound per collision: both cars lose health on the same tick,
  // and your own car's crash is also heard from its loss of speed.
  let crashUntil = 0;
  function crashSound(name: "car_crash" | "car_bump", x?: number, y?: number, z?: number): void {
    const now = performance.now();
    if (now < crashUntil) return;
    crashUntil = now + 150;
    if (x === undefined) audio.play(name);
    else audio.play(name, x, y, z);
  }

  // Pedestrian voices from the wasm cue watcher (kinds 5-12).
  const VOICE_CUES: Record<number, CueName> = {
    5: "ped_panic",
    6: "ped_bumped",
    7: "carjacked",
    9: "mugger",
    10: "gang_shout",
    11: "elvis",
    12: "driver_angry",
  };
  const VOICE_GAP_MS = 900;
  const voiceAt = new Map<CueName, number>();

  // Footstep timers by player slot, in seconds since the last step.
  const stepClock = new Map<number, number>();
  /** Engines for the nearest cars and footsteps for players on foot. */
  function soundTick(g: GameModule, dt: number): void {
    const l = audio.listenerAt;
    const near = (s: SoundSource): number => Math.hypot(s.x - l.x, s.y - l.y);
    const srcs = g.soundSources();
    const cars = srcs.filter((s) => s.kind === "car" && near(s) < 26).sort((a, b) => near(a) - near(b));
    for (const s of cars.slice(0, 8)) audio.setEngine(s.id, s.speed, s.x, s.y, s.z);
    for (const s of srcs) {
      if (s.kind !== "walker") continue;
      const stride = s.anim === 2 ? 0.27 : s.anim === 1 ? 0.42 : 0;
      if (!stride) {
        // Standing: the first step comes as soon as they move.
        stepClock.set(s.id, 1);
        continue;
      }
      const t = (stepClock.get(s.id) ?? stride) + dt;
      if (t < stride) {
        stepClock.set(s.id, t);
        continue;
      }
      stepClock.set(s.id, 0);
      audio.play(s.water ? "footstep_water" : s.ground === 3 ? "footstep_grass" : "footstep", s.x, s.y, s.z);
    }
  }

  function playCue(c: Cue): void {
    if (c.kind === 1) {
      audio.play(SHOT_CUES[c.a] ?? "pistol", c.x, c.y, c.z);
    }
    else if (c.kind === 2) audio.play("ped_hurt", c.x, c.y, c.z);
    else if (c.kind === 3) audio.play("bullet_hit", c.x, c.y, c.z);
    else if (c.kind === 4) audio.play("weapon_switch");
    else if (c.kind === 13) crashSound(c.a >= 600 ? "car_crash" : "car_bump", c.x, c.y, c.z);
    else {
      const name = VOICE_CUES[c.kind];
      if (!name) return;
      // People shout over each other in a crowd; one line per voice at a time.
      const now = performance.now();
      if (now < (voiceAt.get(name) ?? 0)) return;
      voiceAt.set(name, now + VOICE_GAP_MS);
      audio.play(name, c.x, c.y, c.z);
    }
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

  // Sound needs a tap, click or key first; a gamepad button doesn't count, so
  // someone playing on a pad (an iPad, a TV) would never hear anything.
  const soundPrompt = h("div", { class: "sound-prompt hidden", role: "button", onclick: () => audio.unlock() }, "🔇 Tap for sound");
  const renderSoundPrompt = (): void => void soundPrompt.classList.toggle("hidden", audio.running || audio.muted);
  const offSound = audio.on(renderSoundPrompt);
  renderSoundPrompt();
  // ?soundcheck: the sound check panel over the game, for a device that hears nothing.
  let checkPanel: (HTMLElement & { dispose: () => void }) | null = null;
  if (new URLSearchParams(location.search).has("soundcheck")) {
    checkPanel = soundCheck(audio, () => {
      checkPanel?.dispose();
      checkPanel?.remove();
      checkPanel = null;
    });
    checkPanel.classList.add("floating");
  }
  const section = h("section", { class: "screen game" }, h("div", { class: "stage" }, canvas, spHud?.el ?? null, status, weaponLine, feed, banner, scores, soundPrompt, checkPanel), hud);
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
    offSound();
    checkPanel?.dispose();
    offInput();
    removeEventListener("focus", renderPads);
    removeEventListener("blur", renderPads);
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
