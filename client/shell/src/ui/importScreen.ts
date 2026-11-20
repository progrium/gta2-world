// Screen 1: the player gives us their GTA2 files. They stay in this browser.

import { type PickedFile, fromDrop, fromInput, pickDirectory } from "../assets/pick.ts";
import type { AssetRecord } from "../assets/protocol.ts";
import type { AssetStore, MapChoice } from "../assets/store.ts";
import { clear, fmtBytes, h } from "./dom.ts";

export interface ImportScreenOpts {
  store: AssetStore;
  onStart(map: MapChoice): void;
  lastMap: string | null;
}

export function importScreen(root: HTMLElement, o: ImportScreenOpts): () => void {
  clear(root);
  const status = h("p", { class: "status", role: "status" });
  const bar = h("progress", { max: 1, value: 0, hidden: true });
  const mapsBox = h("div", { class: "maps" });
  const filesBox = h("details", { class: "files" });
  const errorsBox = h("div", { class: "errors" });

  const dirInput = h("input", { type: "file", multiple: true, hidden: true }) as HTMLInputElement;
  dirInput.setAttribute("webkitdirectory", "");
  const fileInput = h("input", { type: "file", multiple: true, hidden: true, accept: ".gmp,.sty,.scr,.mmp,.gxt,.sdt,.raw" }) as HTMLInputElement;

  const run = async (files: PickedFile[] | null): Promise<void> => {
    if (!files) return;
    if (files.length === 0) {
      status.textContent = "No GTA2 data files there. Pick the GTA2 install folder, or its data folder.";
      return;
    }
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
      bar.hidden = true;
      render();
    }
  };

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
    const maps = o.store.maps();
    const files = o.store.manifest.files;
    if (maps.length === 0) {
      mapsBox.append(h("p", { class: "muted" }, files.length ? "No complete map yet: a map needs its .gmp and .sty (and the .mmp that names them)." : "Nothing imported yet."));
    } else {
      const list = h("div", { class: "maplist" });
      for (const m of maps) {
        const key = m.mmp ?? m.gmp;
        list.append(
          h(
            "button",
            { class: key === o.lastMap ? "map current" : "map", onclick: () => o.onStart(m) },
            h("strong", {}, m.description),
            h("span", { class: "muted" }, ` ${m.gmp} · ${m.sty}`),
          ),
        );
      }
      mapsBox.append(h("h2", {}, "Pick a map to drive"), list);
    }
    if (files.length) {
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
        h(
          "button",
          {
            class: "danger",
            onclick: async () => {
              await o.store.clear();
              status.textContent = "Cache cleared.";
              render();
            },
          },
          "Forget cached files",
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
      status,
      errorsBox,
      mapsBox,
      filesBox,
      dirInput,
      fileInput,
    ),
  );
  render();
  return () => clear(root);
}

/** For a sound index, whether its .raw is cached and the right size. */
function soundNote(f: AssetRecord, files: readonly AssetRecord[]): string {
  if (f.kind !== "sdt" || !f.info.ok) return "";
  const raw = files.find((r) => r.name === f.name.replace(/\.sdt$/, ".raw"));
  if (!raw) return "; its .raw is missing";
  if (f.info.rawSize !== undefined && raw.size < f.info.rawSize) return "; its .raw is too short";
  return "";
}
