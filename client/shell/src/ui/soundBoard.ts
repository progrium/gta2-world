// Sound board: every sample in the player's banks with a play button, and the
// mapping from the game's cues to those samples. Nobody can map these but the
// player, by ear, so the board is built for auditioning quickly: arrow keys
// step through samples and play each one, Enter assigns it to the chosen cue.
// The mapping stays in this browser and exports as JSON.

import { CUES, CUE_GROUPS, CUE_INFO, CUE_LABELS, type Cue, type SampleRef, type SoundMapping, defaultMapping, emptyMapping, fallbackChain, mappingJson, normalizeMapping, sameRef } from "../audio/cues.ts";
import type { AudioEngine, BankId } from "../audio/engine.ts";
import type { SampleFormat } from "../audio/sdt.ts";
import { clear, h } from "./dom.ts";

const clone = (m: SoundMapping): SoundMapping => normalizeMapping(JSON.parse(JSON.stringify(m)), emptyMapping());
const refLabel = (r: SampleRef, names: Partial<Record<BankId, string>>): string =>
  r.bank === "vocals" ? `“${r.name}”` : `${(names[r.bank] ?? r.bank).replace(/\.sdt$/, "")} #${r.index}${r.format ? ` ${r.format}` : ""}`;

export function soundBoard(audio: AudioEngine, onClose: () => void): HTMLElement {
  let bank: BankId = audio.banks.map ? "map" : "fstyle";
  let target: Cue = "pistol";
  let selected = -1;
  const overrides = new Map<string, SampleFormat>();

  const status = h("div", { class: "small" });
  const cuesBody = h("tbody");
  const samplesBody = h("tbody");
  const cuesScroll = h("div", { class: "scroll" }, h("table", { class: "bindings sound-cues" }, cuesBody));
  const samplesScroll = h("div", { class: "scroll samples" }, h("table", { class: "bindings sound-samples" }, samplesBody));
  const out = h("pre", { class: "mono small tuneout" });
  const tabs = h("div", { class: "tabs" });
  const targetSel = h(
    "select",
    { onchange: (e: Event) => (target = (e.target as HTMLSelectElement).value as Cue) },
    ...CUE_GROUPS.map((g) => h("optgroup", { label: g }, ...CUES.filter((c) => CUE_INFO[c].group === g).map((c) => h("option", { value: c }, CUE_LABELS[c])))),
  ) as HTMLSelectElement;

  const vol = h("input", {
    type: "range", min: "0", max: "1", step: "0.01", value: String(audio.volume),
    oninput: (e: Event) => (audio.volume = Number((e.target as HTMLInputElement).value)),
  }) as HTMLInputElement;
  const mute = h("input", { type: "checkbox", checked: audio.muted, onchange: (e: Event) => (audio.muted = (e.target as HTMLInputElement).checked) }) as HTMLInputElement;

  const update = (fn: (m: SoundMapping) => void): void => {
    const m = clone(audio.mapping);
    fn(m);
    audio.setMapping(m);
  };

  const formatOf = (i: number): SampleFormat => overrides.get(`${bank}:${i}`) ?? audio.banks[bank]!.formats[i]!;
  const refFor = (i: number): SampleRef => {
    const bk = audio.banks[bank]!;
    if ("names" in bk) return { bank: "vocals", index: 0, name: bk.names[i]! };
    const f = formatOf(i);
    return f === audio.banks[bank]!.formats[i] ? { bank, index: i } : { bank, index: i, format: f };
  };

  const assign = (i: number): void => {
    const ref = refFor(i);
    update((m) => {
      const list = m.cues[target].samples;
      if (target === "engine") list.length = 0;
      if (!list.some((r) => sameRef(r, ref))) list.push(ref);
    });
  };

  const renderStatus = (): void => {
    const names = audio.bankNames;
    const have = [names.map, names.vocals, names.fstyle].filter(Boolean).join(", ");
    clear(status);
    status.append(
      have ? h("span", {}, `Banks: ${have}. `) : h("span", { class: "warn" }, "No sound banks cached. Import data/audio/*.sdt and *.raw with your other files; until then every cue plays its built-in sound. "),
      have && !names.vocals ? h("span", { class: "warn" }, "No spoken lines cached: import your data folder again to bring in data/audio/Vocals/*.wav. ") : "",
      audio.running ? "" : h("span", { class: "prompt" }, "Click or press a key to turn sound on."),
    );
  };

  const renderCues = (): void => {
    clear(cuesBody);
    const m = audio.mapping;
    let group = "";
    for (const c of CUES) {
      const cm = m.cues[c];
      const info = CUE_INFO[c];
      if (info.group !== group) {
        group = info.group;
        cuesBody.append(h("tr", { class: "group" }, h("th", { colspan: "4" }, group)));
      }
      const borrowed = cm.samples.length ? undefined : fallbackChain(c).slice(1).find((f) => m.cues[f].samples.length);
      const chips = cm.samples.map((r) =>
        h(
          "span",
          { class: "chip" },
          h("button", { class: "link", title: "Play", onclick: () => void audio.preview(r) }, refLabel(r, audio.bankNames)),
          h("button", { class: "link", title: "Remove", onclick: () => update((mm) => (mm.cues[c].samples = mm.cues[c].samples.filter((x) => !sameRef(x, r)))) }, "×"),
        ),
      );
      const gain = h("input", {
        type: "number", min: "0", max: "2", step: "0.1", value: String(cm.gain), class: "gain",
        onchange: (e: Event) => update((mm) => (mm.cues[c].gain = Number((e.target as HTMLInputElement).value))),
      });
      cuesBody.append(
        h(
          "tr",
          { class: c === target ? "changed" : "" },
          h("td", {}, h("button", { class: "link", title: "Assign samples to this cue", onclick: () => { target = c; targetSel.value = c; keepScroll(renderCues); } }, CUE_LABELS[c]), h("div", { class: "muted small mono" }, c)),
          h("td", {}, ...(chips.length ? chips : [h("span", { class: "muted small" }, borrowed ? `uses ${CUE_LABELS[borrowed].toLowerCase()}` : "built-in sound")])),
          h("td", {}, gain),
          h("td", {}, h("button", { onclick: () => void audio.previewCue(c) }, "▶")),
        ),
      );
    }
    const e = m.engine;
    const num = (k: keyof SoundMapping["engine"], step: string) =>
      h("input", { type: "number", step, value: String(e[k]), class: "gain", onchange: (ev: Event) => update((mm) => (mm.engine[k] = Number((ev.target as HTMLInputElement).value))) });
    cuesBody.append(
      h("tr", {}, h("td", { colspan: "4" }, h("span", { class: "small" }, "Engine pitch: rate at standstill "), num("idleRate", "0.05"), h("span", { class: "small" }, " at top speed "), num("topRate", "0.05"), h("span", { class: "small" }, " top speed (blocks/tick) "), num("topSpeed", "0.01"))),
    );
  };

  const usedBy = (r: SampleRef): Cue[] => CUES.filter((c) => audio.mapping.cues[c].samples.some((x) => sameRef(x, r)));

  const renderTabs = (): void => {
    clear(tabs);
    for (const b of ["map", "vocals", "fstyle"] as BankId[]) {
      const bk = audio.banks[b];
      if (!bk) continue;
      tabs.append(h("button", { class: b === bank ? "on" : "", onclick: () => { bank = b; selected = -1; renderTabs(); renderSamples(); samplesScroll.scrollTop = 0; } }, `${audio.bankNames[b] ?? b} (${bk.entries.length})`));
    }
  };

  const play = (i: number): void => {
    selected = i;
    void audio.preview(refFor(i));
    for (const tr of samplesBody.children) tr.classList.toggle("sel", Number((tr as HTMLElement).dataset.i) === i);
    (samplesBody.children[i] as HTMLElement | undefined)?.scrollIntoView({ block: "nearest" });
  };

  const renderSamples = (): void => {
    clear(samplesBody);
    const bk = audio.banks[bank];
    if (!bk) return;
    bk.entries.forEach((e, i) => {
      const f = formatOf(i);
      const used = usedBy(refFor(i));
      const vocal = "names" in bk;
      const tr = h(
        "tr",
        { class: i === selected ? "sel" : "", "data-i": i },
        h("td", { class: "mono" }, vocal ? (bk as { names: string[] }).names[i]! : `#${i}`),
        h("td", {}, h("button", { onclick: () => play(i) }, "▶")),
        h("td", { class: "mono small" }, `${(e.size / (f === "s16" ? 2 : 1) / e.rate).toFixed(2)} s · ${e.rate} Hz`),
        vocal ? h("td", {}) : h("td", { class: "small" }, h("button", {
          class: "link",
          title: "Switch between 16-bit and 8-bit if it sounds like noise",
          onclick: () => {
            overrides.set(`${bank}:${i}`, f === "s16" ? "u8" : "s16");
            keepScroll(renderSamples);
            play(i);
          },
        }, f === "s16" ? "16-bit" : "8-bit"), e.loopStart > 0 ? h("span", { class: "muted" }, " loop") : null, e.unknownA ? h("span", { class: "muted mono", title: "Unknown field" }, ` ${e.unknownA}`) : null),
        h("td", { class: "small" }, used.length ? used.map((c) => c).join(", ") : ""),
        h("td", {}, h("button", { onclick: () => assign(i), title: "Assign to the chosen cue" }, "Assign")),
      );
      samplesBody.append(tr);
    });
  };

  // Re-rendering empties the tables, which would snap both lists back to the
  // top; put them back where the player was.
  const keepScroll = (fn: () => void): void => {
    const a = cuesScroll.scrollTop;
    const b = samplesScroll.scrollTop;
    const c = panel.scrollTop;
    fn();
    cuesScroll.scrollTop = a;
    samplesScroll.scrollTop = b;
    panel.scrollTop = c;
  };

  const renderAll = (): void => {
    renderStatus();
    keepScroll(() => {
      renderCues();
      renderTabs();
      renderSamples();
    });
    vol.value = String(audio.volume);
    mute.checked = audio.muted;
  };

  const fileIn = h("input", {
    type: "file", accept: ".json,application/json", hidden: true,
    onchange: async (e: Event) => {
      const f = (e.target as HTMLInputElement).files?.[0];
      if (!f) return;
      try {
        audio.setMapping(normalizeMapping(JSON.parse(await f.text())));
        out.textContent = `Loaded ${f.name}.`;
      } catch (err) {
        out.textContent = `Could not read ${f.name}: ${(err as Error).message}`;
      }
    },
  }) as HTMLInputElement;

  const onKey = (ev: KeyboardEvent): void => {
    if (ev.target instanceof HTMLElement && /INPUT|SELECT|TEXTAREA/.test(ev.target.tagName) && ev.key !== "Escape") return;
    const n = audio.banks[bank]?.entries.length ?? 0;
    if (ev.key === "ArrowDown" && n) play(Math.min(n - 1, selected + 1));
    else if (ev.key === "ArrowUp" && n) play(Math.max(0, selected - 1));
    else if (ev.key === " " && selected >= 0) play(selected);
    else if (ev.key === "Enter" && selected >= 0) assign(selected);
    else if (ev.key === "Escape" || ev.code === "KeyB") onClose();
    else return;
    ev.preventDefault();
    ev.stopImmediatePropagation();
  };
  addEventListener("keydown", onKey, { capture: true });
  const off = audio.on(renderAll);
  const poll = setInterval(renderStatus, 1000);

  const panel = h(
    "div",
    { class: "overlay sound" },
    h("div", { class: "hudtop" }, h("h2", {}, "Sound board"), h("button", { onclick: onClose }, "Close (B)")),
    h("p", { class: "muted small" }, "Pick a cue, then step through the samples with ↑ ↓ (each one plays) and press Enter or Assign to give it to the cue. A cue with several samples picks one at random. A cue with none borrows a related cue's samples where it has one (dual pistol uses the pistol's), else plays a built-in sound. Cues under “Not in the game yet” can be mapped now; the game doesn't play them yet. The engine uses its first sample as a loop. Your mapping stays in this browser; export it to keep it or send it back."),
    h("div", { class: "row" }, h("label", {}, "Volume ", vol), h("label", {}, mute, " mute (M)")),
    status,
    h(
      "div",
      { class: "row" },
      h("button", {
        class: "primary",
        onclick: () => {
          const blob = new Blob([mappingJson(audio.mapping)], { type: "application/json" });
          const a = h("a", { href: URL.createObjectURL(blob), download: "gta2-sound-mapping.json" });
          a.click();
          setTimeout(() => URL.revokeObjectURL(a.href), 1000);
        },
      }, "Export JSON"),
      h("button", {
        onclick: async () => {
          const j = mappingJson(audio.mapping);
          out.textContent = j;
          try {
            await navigator.clipboard.writeText(j);
            out.textContent = `Copied.\n${j}`;
          } catch {
            /* shown for manual copy */
          }
        },
      }, "Copy JSON"),
      h("button", { onclick: () => fileIn.click() }, "Import JSON"),
      h("button", { onclick: () => { audio.setMapping(defaultMapping()); out.textContent = "Back to the built-in mapping."; } }, "Reset to default"),
      h("button", { onclick: () => { audio.setMapping(emptyMapping()); out.textContent = "Mapping cleared."; } }, "Clear mapping"),
      fileIn,
    ),
    out,
    h(
      "div",
      { class: "sound-grid" },
      h("div", { class: "pane" }, h("h3", {}, "Cues"), cuesScroll),
      h(
        "div",
        { class: "pane" },
        h("h3", {}, "Samples"),
        h("div", { class: "row" }, h("label", {}, "Assign to ", targetSel)),
        tabs,
        samplesScroll,
      ),
    ),
  );
  targetSel.addEventListener("change", () => keepScroll(renderCues));
  renderAll();
  (panel as HTMLElement & { dispose?: () => void }).dispose = () => {
    removeEventListener("keydown", onKey, { capture: true });
    off();
    clearInterval(poll);
    audio.stopPreview();
  };
  return panel;
}
