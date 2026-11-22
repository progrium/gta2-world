// Shell entry: import screen until a map is available, then the game screen.
// Opening the page with cached assets goes straight into the last map.
// A join link (#join/<room>.<maphash12>) opens the join screen instead, and
// "Host a game" runs the session in this tab for others to join.
// The site's front page links straight to a screen: #files (game files and
// map list), #host (host a game) and #sounds (the sound cue board).

import { AssetStore, type MapChoice } from "./assets/store.ts";
import { audio } from "./audio/index.ts";
import type { HostSession } from "./host/hostSession.ts";
import { InputSystem } from "./input/system.ts";
import type { RtcPeer } from "./net/rtc.ts";
import { parseJoinHash } from "./net/signal.ts";
import "./net/signal-ws.ts";
import { sessionIdFromUrl } from "./session.ts";
import { gameScreen } from "./ui/gameScreen.ts";
import { hostPanel, hostScreen } from "./ui/hostScreen.ts";
import { importScreen, levelKey } from "./ui/importScreen.ts";
import { joinScreen } from "./ui/joinScreen.ts";
import { soundsScreen } from "./ui/soundsScreen.ts";

const LAST_MAP = "gta2.lastMap";
const root = document.getElementById("app")!;
const store = new AssetStore(new URL("./worker.js", import.meta.url));
const input = new InputSystem();
input.attach(window);
audio.attach(window);
const sessionId = sessionIdFromUrl();
// ?server=ws://host:port joins that game server; without it the game runs offline.
const server = new URLSearchParams(location.search).get("server");

let teardown: (() => void) | null = null;
let hosting: HostSession | null = null;

const lastMap = (): string | null => {
  try {
    return localStorage.getItem(LAST_MAP);
  } catch {
    return null;
  }
};

/** Drops a #files, #host or #sounds hash once the player moves on, so a reload doesn't land back there. */
function clearRoute(): void {
  if (/^#(files|host|sounds)$/.test(location.hash)) history.replaceState(null, "", location.pathname + location.search);
}

function showImport(): void {
  if (location.hash === "#host" || location.hash === "#sounds") clearRoute();
  teardown?.();
  teardown = importScreen(root, { store, lastMap: lastMap(), onStart: showGame, onHost: showHost });
}

function showGame(map: MapChoice): void {
  clearRoute();
  try {
    localStorage.setItem(LAST_MAP, levelKey(map));
  } catch {
    /* ignore */
  }
  teardown?.();
  teardown = gameScreen(root, { input, store, sessionId, server, map, onBack: showImport });
}

function showHost(): void {
  if (location.hash === "#files" || location.hash === "#sounds") clearRoute();
  teardown?.();
  teardown = hostScreen(root, {
    store,
    session: hosting,
    onSession: (s) => (hosting = s),
    onPlay: playHosted,
    onBack: showImport,
  });
}

function playHosted(s: HostSession): void {
  teardown?.();
  const panel = hostPanel(s, true);
  const end = gameScreen(root, {
    input,
    store,
    sessionId: s.room,
    net: { transport: "loopback", loopback: s.loopback(), label: `hosting ${s.room}`, police: s.police, gciHash: s.gciHash, addPoints: (slot, n) => s.addPoints(slot, n) },
    extraHud: panel.el,
    map: s.map,
    onBack: showHost,
  });
  teardown = () => {
    panel.dispose();
    end();
  };
}

function showSounds(): void {
  teardown?.();
  teardown = soundsScreen(root, {
    store,
    onFiles: () => {
      history.replaceState(null, "", "#files");
      showImport();
    },
  });
}

/** The screen a front-page link asks for, if any. */
function route(): boolean {
  if (location.hash === "#files") showImport();
  else if (location.hash === "#host") showHost();
  else if (location.hash === "#sounds") showSounds();
  else return false;
  return true;
}

function leaveJoin(): void {
  history.replaceState(null, "", location.pathname + location.search);
  void boot(false);
}

function showJoin(room: string, mapHash12: string, police = false): void {
  teardown?.();
  teardown = joinScreen(root, {
    store,
    room,
    mapHash12,
    onCancel: leaveJoin,
    onPlay: (map: MapChoice, rtc: RtcPeer, gciHash: string | null) => {
      teardown?.();
      teardown = gameScreen(root, { input, store, sessionId: room, net: { transport: "webrtc", rtc, label: `room ${room}`, police, gciHash }, map, onBack: leaveJoin });
    },
  });
}

async function boot(autoStart = true): Promise<void> {
  try {
    await store.load();
  } catch (e) {
    console.warn("asset cache unavailable", e);
  }
  const join = parseJoinHash(location.hash);
  if (join) return showJoin(join.room, join.mapHash12, join.police);
  if (route()) return;
  const maps = [...store.levels(), ...store.maps()];
  const want = lastMap();
  const m = maps.find((x) => levelKey(x) === want);
  if (m && autoStart) showGame(m);
  else showImport();
}

addEventListener("hashchange", () => {
  const join = parseJoinHash(location.hash);
  if (join) showJoin(join.room, join.mapHash12, join.police);
  else route();
});

void boot();
