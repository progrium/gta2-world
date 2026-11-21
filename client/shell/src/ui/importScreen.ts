// Screen 1: the player gives us their GTA2 files. They stay in this browser.

import { type PickedFile, fromDrop, fromInput, pickDirectory } from "../assets/pick.ts";
import { ARCHIVE_PAGE, ARCHIVE_SIZE, downloadFromArchive } from "../assets/installer.ts";
import type { AssetRecord } from "../assets/protocol.ts";
import type { AssetStore, MapChoice } from "../assets/store.ts";
import { clear, fmtBytes, h } from "./dom.ts";

export interface ImportScreenOpts {
  store: AssetStore;
  onStart(map: MapChoice): void;
  /** Opens the "Host a game" screen. */
  onHost?(): void;
  lastMap: string | null;
}

export function importScreen(root: HTMLElement, o: ImportScreenOpts): () => void {
  clear(root);
  const status = h("p", { class: "status", role: "status" });
  const bar = h("progress", { max: 1, value: 0, hidden: true });
  const mapsBox = h("div", { class: "maps" });
  const filesBox = h("details", { class: "files" });
  const clearBox = h("div", { class: "row" });
  const errorsBox = h("div", { class: "errors" });

  const dirInput = h("input", { type: "file", multiple: true, hidden: true }) as HTMLInputElement;
  dirInput.setAttribute("webkitdirectory", "");
  const fileInput = h("input", { type: "file", multiple: true, hidden: true, accept: ".gmp,.sty,.scr,.mmp,.gxt,.sdt,.raw,.gci,.seq,.wav" }) as HTMLInputElement;

  let busy = false;
  const run = async (files: PickedFile[] | null): Promise<void> => {
    if (!files || busy) return;
    if (files.length === 0) {
      status.textContent = "No GTA2 data files there. Pick the GTA2 install folder, or its data folder.";
      return;
    }
    busy = true;
    bar.hidden = false;
    bar.value = 0;
    status.textContent = `Importing ${files.length} files…`;
    try {
      const r = await o.store.import(files, (done, total, path) => {
        bar.max = Math.max(1, total);
        bar.value = done;
        if (path) status.textContent = `Checking ${path} (${done + 1} of ${total})`;
      });
      status.textContent = r.persistent
        ? `Imported ${files.length} files. They are cached in this browser and were not uploaded anywhere.`
        : `Imported ${files.length} files for this visit only: this browser won't let the page keep them (private mode?).`;
      clear(errorsBox);
      if (r.errors.length) {
        errorsBox.append(
          h("p", {}, "These files didn't look right and may be damaged or from another game version:"),
          h("ul", {}, ...r.errors.map((e) => h("li", {}, `${e.path}: ${e.error}`))),
        );
      }
    } catch (e) {
      status.textContent = `Import failed: ${(e as Error).message}`;
    } finally {
      busy = false;
      bar.hidden = true;
      render();
    }
  };

  // Download Rockstar's freeware installer from the Internet Archive into this
  // browser, pull the data files out of it and import them like a local folder.
  const archiveBar = h("progress", { max: 1, value: 0, hidden: true });
  const archiveBtn = h("button", {}, `Download from the Internet Archive (${fmtBytes(ARCHIVE_SIZE)})`) as HTMLButtonElement;
  const cancelBtn = h("button", { hidden: true }, "Cancel") as HTMLButtonElement;
  let abort: AbortController | null = null;
  cancelBtn.onclick = () => abort?.abort();
  archiveBtn.onclick = async () => {
    if (busy) return;
    busy = true;
    abort = new AbortController();
    archiveBtn.disabled = true;
    cancelBtn.hidden = false;
    archiveBar.hidden = false;
    archiveBar.value = 0;
    status.textContent = "Connecting to the Internet Archive…";
    let files: PickedFile[] | null = null;
    try {
      files = await downloadFromArchive((phase, done, total, path) => {
        archiveBar.max = Math.max(1, total);
        archiveBar.value = done;
        status.textContent =
          phase === "download"
            ? `Downloading the GTA2 installer from the Internet Archive: ${fmtBytes(done)} of ${fmtBytes(total)}`
            : `Unpacking ${path ?? ""} (${done + 1} of ${total})`;
      }, abort.signal);
    } catch (e) {
      status.textContent = abort.signal.aborted
        ? "Download cancelled."
        : `Download failed: ${(e as Error).message}. You can try again, or choose your GTA2 folder instead.`;
    } finally {
      busy = false;
      abort = null;
      archiveBtn.disabled = false;
      cancelBtn.hidden = true;
      archiveBar.hidden = true;
    }
    if (files) await run(files);
  };
  const archive = h(
    "div",
    { class: "archive" },
    h("p", {}, "No copy of GTA2? Rockstar gave it away as freeware. Get it here in one click:"),
    h("div", { class: "row" }, archiveBtn, cancelBtn),
    archiveBar,
    h(
      "p",
      { class: "muted small" },
      "The installer downloads straight from the ",
      h("a", { href: ARCHIVE_PAGE, target: "_blank", rel: "noopener" }, "Internet Archive"),
      " to this browser, which unpacks the game's data files and caches them here. Nothing goes through our servers. The music is left out to save space.",
    ),
  );

  const chooseFolder = async (): Promise<void> => {
    const r = await pickDirectory();
    if (r === null) dirInput.click(); // no File System Access API: fall back to the input
    else await run(r);
  };
  dirInput.onchange = () => void run(fromInput(dirInput));
  fileInput.onchange = () => void run(fromInput(fileInput));

  const drop = h(
    "div",
    { class: "drop", tabindex: 0 },
    h("p", {}, "Drop your GTA2 folder or its data files here"),
    h("div", { class: "row" }, h("button", { class: "primary", onclick: () => void chooseFolder() }, "Choose GTA2 folder…"), h("button", { onclick: () => fileInput.click() }, "Choose files…")),
    bar,
  );
  drop.addEventListener("dragover", (e) => {
    e.preventDefault();
    drop.classList.add("over");
  });
  drop.addEventListener("dragleave", () => drop.classList.remove("over"));
  drop.addEventListener("drop", (e) => {
    e.preventDefault();
    drop.classList.remove("over");
    if (e.dataTransfer) void fromDrop(e.dataTransfer).then(run);
  });

  const render = (): void => {
    clear(mapsBox);
    clear(filesBox);
    clear(clearBox);
    const maps = o.store.maps();
    const levels = o.store.levels();
    const files = o.store.manifest.files;
    if (levels.length > 0) {
      const list = h("div", { class: "maplist" });
      for (const m of levels) {
        const key = levelKey(m);
        list.append(
          h(
            "button",
            { class: `${key === o.lastMap ? "map current" : "map"}${m.story?.bonus ? " bonus" : ""}`, onclick: () => o.onStart(m) },
            h("strong", {}, m.description),
            h("span", { class: "muted" }, ` ${m.story?.bonus ? "bonus stage · " : ""}${m.gmp} · ${m.scr ?? ""}`),
          ),
        );
      }
      mapsBox.append(h("h2", {}, "Single player"), list);
      const texts = files.filter((f) => f.kind === "gxt" && f.info.ok);
      if (texts.length > 1) {
        const sel = h("select", { onchange: (e: Event) => setTextChoice((e.target as HTMLSelectElement).value) }, ...texts.map((f) => h("option", { value: f.name }, f.name))) as HTMLSelectElement;
        sel.value = textChoice(files) ?? "";
        mapsBox.append(h("p", { class: "small" }, "Game text: ", sel));
      }
    }
    if (maps.length === 0) {
      mapsBox.append(h("p", { class: "muted" }, files.length ? "No complete map yet: a map needs its .gmp and .sty (and the .mmp that names them)." : "Nothing imported yet."));
    } else {
      const list = h("div", { class: "maplist" });
      for (const m of maps) {
        const key = levelKey(m);
        list.append(
          h(
            "button",
            { class: key === o.lastMap ? "map current" : "map", onclick: () => o.onStart(m) },
            h("strong", {}, m.description),
            h("span", { class: "muted" }, ` ${m.gmp} · ${m.sty}`),
          ),
        );
      }
      mapsBox.append(h("h2", {}, levels.length ? "Deathmatch maps" : "Pick a map to drive"), list);
      if (o.onHost) {
        mapsBox.append(
          h("h2", {}, "Play with others"),
          h("div", { class: "row" }, h("button", { class: "host-game", onclick: () => o.onHost?.() }, "Host a game…"), h("span", { class: "muted small" }, "Run a game in this tab and invite players with a link.")),
        );
      }
    }
    if (files.length) {
      clearBox.append(
        h(
          "button",
          {
            class: "danger",
            onclick: async () => {
              if (!confirm("Remove every cached GTA2 file from this browser? You can import them again.")) return;
              await o.store.clear();
              status.textContent = "Cache cleared. Choose your GTA2 folder again to play.";
              render();
            },
          },
          "Clear cached files",
        ),
        h("span", { class: "muted small" }, " Removes your imported files from this browser, so you can import them again."),
      );
      const total = files.reduce((n, f) => n + f.size, 0);
      filesBox.append(
        h("summary", {}, `${files.length} cached files, ${fmtBytes(total)}`),
        h(
          "table",
          {},
          h("tr", {}, h("th", {}, "File"), h("th", {}, "Size"), h("th", {}, "Check"), h("th", {}, "SHA-256")),
          ...files.map((f) =>
            h(
              "tr",
              {},
              h("td", {}, f.path),
              h("td", {}, fmtBytes(f.size)),
              h("td", { class: f.info.ok ? (soundNote(f, files) ? "warn" : "ok") : "bad" }, f.info.ok ? (f.info.chunks ? `ok, ${f.info.chunks.length} chunks` : f.info.samples ? `ok, ${f.info.samples} sounds${soundNote(f, files)}` : "ok") : f.info.error ?? "bad"),
              h("td", { class: "mono", title: f.hash }, f.hash.slice(0, 12)),
            ),
          ),
        ),
      );
    }
  };

  root.append(
    h(
      "section",
      { class: "screen import" },
      h("h1", {}, "GTA2 World"),
      h("p", {}, "This game runs on your own copy of GTA2. Point it at the folder where GTA2 is installed. Your files are checked and cached in this browser only. They are never uploaded."),
      drop,
      archive,
      status,
      errorsBox,
      mapsBox,
      filesBox,
      clearBox,
      dirInput,
      fileInput,
    ),
  );
  render();
  return () => clear(root);
}

/** The key a level or map is remembered by (the last one played). */
export function levelKey(m: MapChoice): string {
  return m.story ? `level:${m.gmp.toLowerCase()}` : m.mmp ?? m.gmp;
}

const TEXT_CHOICE = "gta2.text";

/** The .gxt to use: the player's choice, else e.gxt, else the first one. */
export function textChoice(files: readonly AssetRecord[]): string | null {
  const texts = files.filter((f) => f.kind === "gxt" && f.info.ok);
  let want: string | null = null;
  try {
    want = localStorage.getItem(TEXT_CHOICE);
  } catch {
    /* ignore */
  }
  return (texts.find((f) => f.name === want) ?? texts.find((f) => f.name === "e.gxt") ?? texts[0])?.name ?? null;
}

function setTextChoice(name: string): void {
  try {
    localStorage.setItem(TEXT_CHOICE, name);
  } catch {
    /* ignore */
  }
}

/** For a sound index, whether its .raw is cached and the right size. */
function soundNote(f: AssetRecord, files: readonly AssetRecord[]): string {
  if (f.kind !== "sdt" || !f.info.ok) return "";
  const raw = files.find((r) => r.name === f.name.replace(/\.sdt$/, ".raw"));
  if (!raw) return "; its .raw is missing";
  if (f.info.rawSize !== undefined && raw.size < f.info.rawSize) return "; its .raw is too short";
  return "";
}
