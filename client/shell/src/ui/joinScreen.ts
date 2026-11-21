// Opened from a join link (#join/<room>.<maphash12>): reach the host's tab,
// get any files the match needs that this browser lacks, then play.

import type { AssetStore, MapChoice } from "../assets/store.ts";
import { gciFromMatch, joinStore, mapFromMatch } from "../lobby/assets.ts";
import type { FileInfo } from "../lobby/files.ts";
import { LobbyJoin, wrapDataChannel } from "../lobby/lobby.ts";
import { RtcPeer } from "../net/rtc.ts";
import { createSignaller } from "../net/signaller.ts";
import { clear, fmtBytes, h } from "./dom.ts";

export interface JoinScreenOpts {
  store: AssetStore;
  room: string;
  mapHash12: string;
  /** `gciHash`: the host's .gci (car handling), or null; the client builds the same car models. */
  onPlay(map: MapChoice, rtc: RtcPeer, gciHash: string | null): void;
  onCancel(): void;
}

export function joinScreen(root: HTMLElement, o: JoinScreenOpts): () => void {
  clear(root);
  const status = h("p", { class: "status-line join-status", role: "status" }, "Looking for the host…");
  const files = h("div", { class: "joinfiles" });
  const back = h("button", { onclick: () => o.onCancel() }, "Cancel");
  root.append(
    h("section", { class: "screen import join" }, h("h1", {}, "Join a game"), h("p", { class: "muted" }, `Room ${o.room}`), status, files, h("div", { class: "row" }, back)),
  );
  let rtc: RtcPeer | null = null;
  let handedOver = false;
  let gone = false;
  const bars = new Map<string, { bar: HTMLProgressElement; label: HTMLElement; f: FileInfo }>();

  const fail = (msg: string): void => {
    if (gone) return;
    status.textContent = msg;
    status.classList.add("bad");
    back.textContent = "Back";
    rtc?.close("lobby failed");
  };

  const run = async (): Promise<void> => {
    const sig = await createSignaller("peer", o.room);
    // ?pipeAfter=<ms> (tests): how long WebRTC gets before the same-browser pipe.
    const pipeAfter = Number(new URLSearchParams(location.search).get("pipeAfter") ?? NaN);
    rtc = await RtcPeer.connect(sig, undefined, Number.isFinite(pipeAfter) ? pipeAfter : undefined);
    if (gone) return rtc.close("cancelled");
    rtc.onClose = (reason) => {
      if (!handedOver) fail(`Lost the connection to the host: ${reason}`);
    };
    status.textContent = "Connected to the host. Checking the map's files…";
    const lobby = new LobbyJoin(wrapDataChannel(rtc.f), joinStore(o.store));
    lobby.onMatch = (_all, missing, share) => {
      clear(files);
      if (missing.length === 0) return;
      status.textContent = share ? `Downloading ${missing.length} file${missing.length === 1 ? "" : "s"} from the host…` : "Missing files.";
      for (const f of missing) {
        const bar = h("progress", { max: f.size, value: 0 }) as HTMLProgressElement;
        const label = h("span", { class: "small muted" }, `0 of ${fmtBytes(f.size)}`);
        bars.set(f.sha256, { bar, label, f });
        files.append(h("div", { class: "row joinfile", "data-name": f.name }, h("code", {}, f.name), bar, label));
      }
    };
    lobby.onProgress = (p) => {
      const b = bars.get(p.file.sha256);
      if (!b) return;
      b.bar.value = p.received;
      b.label.textContent = `${fmtBytes(p.received)} of ${fmtBytes(b.f.size)}`;
    };
    lobby.onSaved = (f) => {
      const b = bars.get(f.sha256);
      if (b) b.label.textContent = `${fmtBytes(f.size)}, checked (SHA-256) and kept in this browser`;
    };
    const m = await lobby.run(o.mapHash12);
    if (gone) return;
    const map = mapFromMatch(o.store, m);
    status.textContent = `Starting ${map.description}…`;
    handedOver = true;
    o.onPlay(map, rtc, gciFromMatch(m));
  };
  run().catch((e) => fail((e as Error).message ?? String(e)));

  return () => {
    gone = true;
    if (!handedOver) rtc?.close("cancelled");
    clear(root);
  };
}
