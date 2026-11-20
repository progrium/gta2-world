// Shell entry: import screen until a map is available, then the game screen.
// Opening the page with cached assets goes straight into the last map.

import { AssetStore, type MapChoice } from "./assets/store.ts";
import { InputSystem } from "./input/system.ts";
import { sessionIdFromUrl } from "./session.ts";
import { gameScreen } from "./ui/gameScreen.ts";
import { importScreen } from "./ui/importScreen.ts";

const LAST_MAP = "gta2.lastMap";
const root = document.getElementById("app")!;
const store = new AssetStore(new URL("./worker.js", import.meta.url));
const input = new InputSystem();
input.attach(window);
const sessionId = sessionIdFromUrl();
// ?server=ws://host:port joins that game server; without it the game runs offline.
const server = new URLSearchParams(location.search).get("server");

let teardown: (() => void) | null = null;

const lastMap = (): string | null => {
  try {
    return localStorage.getItem(LAST_MAP);
  } catch {
    return null;
  }
};

function showImport(): void {
  teardown?.();
  teardown = importScreen(root, { store, lastMap: lastMap(), onStart: showGame });
}

function showGame(map: MapChoice): void {
  try {
    localStorage.setItem(LAST_MAP, map.mmp ?? map.gmp);
  } catch {
    /* ignore */
  }
  teardown?.();
  teardown = gameScreen(root, { input, store, sessionId, server, map, onBack: showImport });
}

async function boot(): Promise<void> {
  try {
    await store.load();
  } catch (e) {
    console.warn("asset cache unavailable", e);
  }
  const maps = store.maps();
  const want = lastMap();
  const m = maps.find((x) => (x.mmp ?? x.gmp) === want);
  if (m) showGame(m);
  else showImport();
}

void boot();
