// Host a game from this tab: pick a map, choose whether to share the map's
// files with players who lack them, get a join link, watch players arrive.

import type { AssetStore, MapChoice } from "../assets/store.ts";
import { HostSession } from "../host/hostSession.ts";
import type { PeerView } from "../host/hostPeers.ts";
import { signalIsLocal } from "../net/signaller.ts";
import { clear, fmtBytes, h } from "./dom.ts";

export interface HostScreenOpts {
  store: AssetStore;
  /** The running session, if already hosting. */
  session: HostSession | null;
  onSession(s: HostSession | null): void;
  onPlay(s: HostSession): void;
  onBack(): void;
}

const SHARE_KEY = "gta2.host.share";

function savedShare(): boolean {
  try {
    return localStorage.getItem(SHARE_KEY) === "1";
  } catch {
    return false;
  }
}

function peerLine(p: PeerView): string {
  if (p.kind === "loopback") return `You (this tab) · ${p.state}`;
  const who = p.name || `player ${p.id}`;
  const l = p.lobby;
  let what: string = p.state;
  if (p.state === "lobby" && l) {
    if (l.state === "sending") what = `downloading files ${fmtBytes(l.sent)} of ${fmtBytes(l.total)}`;
    else if (l.state === "refused") what = `missing ${l.detail} (sharing is off)`;
    else if (l.state === "error") what = `lobby error: ${l.detail}`;
    else if (l.state === "ready") what = "files ready, starting";
    else what = "in the lobby";
  }
  return `${who} · ${what}`;
}

/** The join link and player list; used on the host screen and in the game HUD. */
export function hostPanel(s: HostSession, compact: boolean): { el: HTMLElement; dispose(): void } {
  const linkInput = h("input", { class: "joinlink mono", readonly: true, value: s.link(), onfocus: (e: Event) => (e.target as HTMLInputElement).select() }) as HTMLInputElement;
  const copyBtn = h("button", {
    onclick: async () => {
      try {
        await navigator.clipboard.writeText(s.link());
        copyBtn.textContent = "Copied";
      } catch {
        linkInput.select();
      }
    },
  }, "Copy link");
  const shareBox = h("input", {
    type: "checkbox",
    class: "share",
    checked: s.share,
    onchange: (e: Event) => {
      s.share = (e.target as HTMLInputElement).checked;
      try {
        localStorage.setItem(SHARE_KEY, s.share ? "1" : "0");
      } catch {
        /* ignore */
      }
    },
  });
  const list = h("ul", { class: "peers" });
  const err = h("p", { class: "bad small" });
  const render = (): void => {
    clear(list);
    const ps = s.list();
    for (const p of ps) list.append(h("li", { class: `peer ${p.state.replace(" ", "-")}`, "data-peer": p.id }, peerLine(p)));
    if (ps.length === 0) list.append(h("li", { class: "muted" }, "No players yet."));
    err.textContent = s.error;
  };
  const off = s.on(render);
  render();
  const local = signalIsLocal()
    ? h("p", { class: "muted small" }, "This link reaches other tabs of this browser only (local signalling).")
    : null;
  const el = compact
    ? h("div", { class: "hostbar row small" }, h("strong", {}, "Hosting"), linkInput, copyBtn, h("label", {}, shareBox, " share files"), list, err)
    : h(
        "div",
        { class: "hostpanel" },
        h("h2", {}, `Hosting ${s.map.description}`),
        h("div", { class: "row" }, linkInput, copyBtn),
        local,
        h("label", { class: "row" }, shareBox, " Share my game files (the map's .gmp and .sty) with players who don't have them"),
        h("h2", {}, "Players"),
        list,
        err,
      );
  return { el, dispose: off };
}

export function hostScreen(root: HTMLElement, o: HostScreenOpts): () => void {
  clear(root);
  const section = h("section", { class: "screen import host" }, h("h1", {}, "Host a game"));
  root.append(section);
  let dispose: (() => void) | null = null;
  let session = o.session;
  const setSession = (s: HostSession | null): void => {
    session = s;
    o.onSession(s);
  };

  const setup = (): void => {
    const maps = o.store.maps();
    const status = h("p", { class: "status-line", role: "status" });
    if (maps.length === 0) {
      section.append(h("p", { class: "muted" }, "Import your GTA2 files first: hosting needs a map."), h("button", { onclick: () => o.onBack() }, "Back"));
      return;
    }
    const sel = h("select", { class: "mapsel" }, ...maps.map((m, i) => h("option", { value: i }, `${m.description} (${m.gmp})`))) as HTMLSelectElement;
    const share = h("input", { type: "checkbox", class: "share", checked: savedShare() }) as HTMLInputElement;
    const startBtn = h("button", {
      class: "primary start",
      onclick: async () => {
        startBtn.disabled = true;
        status.textContent = "Starting the host…";
        const map: MapChoice = maps[Number(sel.value)]!;
        try {
          localStorage.setItem(SHARE_KEY, share.checked ? "1" : "0");
        } catch {
          /* ignore */
        }
        try {
          const s = await HostSession.start(o.store, map, share.checked);
          setSession(s);
          render();
        } catch (e) {
          status.textContent = `Could not host: ${(e as Error).message ?? e}`;
          startBtn.disabled = false;
        }
      },
    }, "Start hosting");
    section.append(
      h("p", {}, "Your browser runs the game; other players join with a link. Keep this tab open while you host."),
      h("div", { class: "row" }, h("label", {}, "Map "), sel),
      h("label", { class: "row" }, share, " Share my game files with players who don't have them"),
      h("p", { class: "muted small" }, "Shared files go straight from this browser to the joining player's, and are kept in their browser for next time."),
      h("div", { class: "row" }, startBtn, h("button", { onclick: () => o.onBack() }, "Back")),
      status,
    );
  };

  const hosting = (s: HostSession): void => {
    const panel = hostPanel(s, false);
    dispose = panel.dispose;
    section.append(
      panel.el,
      h(
        "div",
        { class: "row" },
        h("button", { class: "primary play", onclick: () => o.onPlay(s) }, "Enter the game"),
        h("button", {
          class: "danger stop",
          onclick: async () => {
            await s.stop();
            setSession(null);
            render();
          },
        }, "Stop hosting"),
        h("button", { onclick: () => o.onBack() }, "Files & maps"),
      ),
    );
  };

  const render = (): void => {
    dispose?.();
    dispose = null;
    while (section.childNodes.length > 1) section.lastChild!.remove();
    if (session?.peers) hosting(session);
    else setup();
  };
  render();
  return () => {
    dispose?.();
    clear(root);
  };
}
