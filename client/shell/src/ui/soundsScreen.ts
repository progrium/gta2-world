// Sound cues on their own: the sound board as a full page, for anyone who
// wants to help map the game's cues to samples without playing. Opened from
// the site's front page with play/#sounds. Needs the sound banks from the
// player's own files, like the game does.

import { audio, loadBanks } from "../audio/index.ts";
import type { AssetStore } from "../assets/store.ts";
import { clear, h } from "./dom.ts";
import { soundBoard } from "./soundBoard.ts";

export interface SoundsScreenOpts {
  store: AssetStore;
  /** Leaves for the files screen, to import the sound banks. */
  onFiles(): void;
}

const BANK_KEY = "gta2.sounds.bank";
const ISSUE = "https://github.com/progrium/gta2-world/issues/new?template=sound-mapping.yml";

export function soundsScreen(root: HTMLElement, o: SoundsScreenOpts): () => void {
  clear(root);
  const banks = o.store.manifest.files
    .filter((f) => f.kind === "sdt" && f.info.ok && f.name !== "fstyle.sdt")
    .map((f) => f.name.replace(/\.sdt$/, ""))
    .sort();
  let saved: string | null = null;
  try {
    saved = localStorage.getItem(BANK_KEY);
  } catch {
    /* ignore */
  }
  const board = h("div", { class: "sounds-board" });
  let panel: (HTMLElement & { dispose?: () => void }) | null = null;
  let gone = false;

  const show = async (base: string): Promise<void> => {
    try {
      localStorage.setItem(BANK_KEY, base);
    } catch {
      /* ignore */
    }
    await loadBanks(o.store, { gmp: `${base}.gmp` }).catch((e) => console.warn("[audio] banks", e));
    if (gone) return;
    panel?.dispose?.();
    clear(board);
    panel = soundBoard(audio, () => undefined, true);
    board.append(panel);
  };

  const bankSel = h(
    "select",
    { onchange: (e: Event) => void show((e.target as HTMLSelectElement).value) },
    ...banks.map((b) => h("option", { value: b }, `${b}.sdt`)),
  ) as HTMLSelectElement;

  const top = h(
    "div",
    { class: "sounds-top" },
    h("h1", {}, "Sound cues"),
    h(
      "p",
      {},
      "Help match the game's sounds to its events. Listen to the samples in your own GTA2 sound banks, assign them to cues, then press ",
      h("b", {}, "Export JSON"),
      " and ",
      h("a", { href: ISSUE, target: "_blank", rel: "noopener" }, "send the file on GitHub"),
      ". Your mapping is also used when you play in this browser.",
    ),
    h(
      "div",
      { class: "row" },
      h("a", { href: "../" }, "← Setup"),
      banks.length ? h("label", { class: "small" }, "Map sound bank ", bankSel) : null,
      h("button", { onclick: o.onFiles }, "Game files…"),
    ),
  );

  root.append(h("section", { class: "screen sounds" }, top, board));
  if (banks.length === 0) {
    board.append(
      h(
        "div",
        { class: "sounds-empty" },
        h("p", {}, "No sound banks yet. They come with the game files: import your GTA2 folder (or download the freeware copy), and the files in data/audio come along."),
        h("button", { class: "primary", onclick: o.onFiles }, "Get game files"),
      ),
    );
  } else {
    const first = banks.includes(saved ?? "") ? saved! : banks[0]!;
    bankSel.value = first;
    void show(first);
  }
  return () => {
    gone = true;
    panel?.dispose?.();
    audio.stopPreview();
    clear(root);
  };
}
