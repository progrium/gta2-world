// Live tuning panel for the placeholder handling in sim/tuning.zig. Offline
// play only: the numbers are not part of the sim state, so a networked
// client must leave them alone. Changes persist in this browser and can be
// copied out as Zig to paste into sim/tuning.zig.

import type { GameModule, TuneEntry } from "../game/wasm.ts";
import { h } from "./dom.ts";

const STORE = "gta2.tuning.v2";
const FX = 65536;

/** Plain-language labels; the field names are the ones in tuning.zig. */
const LABELS: Record<string, string> = {
  "car.max_speed": "Top speed (blocks/tick)",
  "car.thrust": "Thrust",
  "car.brake_friction": "Brake friction",
  "car.turn_ratio": "Turn ratio (steering angle)",
  "car.turn_in": "Turn in (grip shift while steering)",
  "car.rear_end_stability": "Rear end stability",
  "car.handbrake_slide": "Handbrake slide (rear grip)",
  "car.front_drive_bias": "Front drive share",
  "car.gear1": "Gear 1 multiplier",
  "car.gear2": "Gear 2 multiplier",
  "car.gear3": "Gear 3 multiplier",
  "car.gear2_speed": "Gear 2 from speed",
  "car.gear3_speed": "Gear 3 from speed",
  "car.inertia": "Moment of inertia",
  "car.front_axle": "Front axle offset",
  "car.rear_axle": "Rear axle offset",
  "car.restitution_8ths": "Wall bounce (8ths)",
  "car.mass": "Mass",
  "car.anti_strength": "Damage taken (anti-strength)",
  "car.half_len": "Body half length",
  "car.half_wid": "Body half width",
  "car.radius": "Radius vs other bodies",
  ped_walk: "Walk speed",
  ped_run: "Run speed",
  ped_back: "Walk backward speed",
  ped_tank_turn: "Tank turn build-up per tick",
  ped_direct_turn: "Direct turn rate",
  ped_jump_vz: "Jump speed",
};

/** Fields shown first: the ones that change the feel most. */
const FEEL = ["car.max_speed", "car.thrust", "car.brake_friction", "car.turn_ratio", "car.turn_in", "car.rear_end_stability", "car.handbrake_slide", "car.mass"];

const toShown = (e: TuneEntry, raw: number): number => (e.unit === "fx" ? raw / FX : raw);
const toRaw = (e: TuneEntry, shown: number): number => (e.unit === "fx" ? Math.round(shown * FX) : Math.round(shown));
const fmt = (e: TuneEntry, raw: number): string => (e.unit === "fx" ? (raw / FX).toFixed(4) : String(raw));

function loadSaved(): Record<string, number> {
  try {
    return JSON.parse(localStorage.getItem(STORE) ?? "{}") as Record<string, number>;
  } catch {
    return {};
  }
}
function save(v: Record<string, number>): void {
  try {
    localStorage.setItem(STORE, JSON.stringify(v));
  } catch {
    /* private mode: changes last for this visit */
  }
}

/** Applies saved tuning to a freshly loaded module. Returns how many differ from defaults. */
export function applySavedTuning(game: GameModule): number {
  const saved = loadSaved();
  let n = 0;
  for (const e of game.tuning()) {
    const v = saved[e.name];
    if (typeof v === "number" && v !== e.default) {
      game.tuneSet(e.index, v);
      n++;
    }
  }
  return n;
}

/** Zig source for the changed values, to paste into sim/tuning.zig. */
export function tuningAsZig(game: GameModule): string {
  const lines: string[] = [];
  for (const e of game.tuning()) {
    const v = game.tuneGet(e.index);
    if (v === e.default) continue;
    const field = e.name.startsWith("car.") ? `.${e.name.slice(4)}` : `pub var ${e.name}`;
    const note = e.unit === "fx" ? ` // ${(v / FX).toFixed(4)} (was ${(e.default / FX).toFixed(4)})` : ` // was ${e.default}`;
    lines.push(e.name.startsWith("car.") ? `    ${field} = ${v},${note}` : `${field}: i32 = ${v};${note}`);
  }
  return lines.length ? `// sim/tuning.zig changes from the browser tuning panel\n${lines.join("\n")}\n` : "// No changes from the defaults.\n";
}

export function tuningPanel(game: GameModule, onClose: () => void): HTMLElement {
  const entries = game.tuning();
  const saved = loadSaved();
  const ordered = [...FEEL.map((n) => entries.find((e) => e.name === n)!).filter(Boolean), ...entries.filter((e) => !FEEL.includes(e.name))];
  const out = h("pre", { class: "mono small tuneout" });
  const rows: HTMLElement[] = [];

  const persist = (): void => {
    const v: Record<string, number> = {};
    for (const e of entries) {
      const raw = game.tuneGet(e.index);
      if (raw !== e.default) v[e.name] = raw;
    }
    for (const k of Object.keys(saved)) delete saved[k];
    Object.assign(saved, v);
    save(v);
  };

  for (const e of ordered) {
    const raw = game.tuneGet(e.index);
    const input = h("input", { type: "number", step: e.unit === "fx" ? "0.001" : "1", value: String(toShown(e, raw)) }) as HTMLInputElement;
    const def = h("span", { class: "muted small" }, `default ${fmt(e, e.default)}`);
    const row = h("tr", { class: raw !== e.default ? "changed" : "" }, h("td", {}, LABELS[e.name] ?? e.name, h("div", { class: "muted small mono" }, e.name)), h("td", {}, input), h("td", {}, def));
    const apply = (): void => {
      const n = Number(input.value);
      if (!Number.isFinite(n)) return;
      game.tuneSet(e.index, toRaw(e, n));
      row.classList.toggle("changed", game.tuneGet(e.index) !== e.default);
      persist();
    };
    input.addEventListener("input", apply);
    input.addEventListener("keydown", (ev) => ev.stopPropagation());
    rows.push(row);
  }

  const panel = h(
    "div",
    { class: "overlay tuning" },
    h("div", { class: "hudtop" }, h("h2", {}, "Handling tuning"), h("button", { onclick: onClose }, "Close (T)")),
    h("p", { class: "muted small" }, "Placeholder handling from sim/tuning.zig, applied live. Speeds are blocks per tick (30 ticks/s); turn rates are angle units per tick (65536 per turn). Changes stay in this browser. Copy them as Zig to send back."),
    h(
      "div",
      { class: "row" },
      h("button", {
        class: "primary",
        onclick: async () => {
          const z = tuningAsZig(game);
          out.textContent = z;
          try {
            await navigator.clipboard.writeText(z);
            out.textContent = `Copied.\n${z}`;
          } catch {
            /* shown below for manual copy */
          }
        },
      }, "Copy as Zig"),
      h("button", {
        onclick: () => {
          const z = tuningAsZig(game);
          const body = `Handling tuning from the play page.\n\nWhat I changed and why:\n\n\n\`\`\`zig\n${z}\`\`\`\n`;
          const url = `https://github.com/progrium/gta2-world/issues/new?labels=tuning&title=${encodeURIComponent("Handling tuning")}&body=${encodeURIComponent(body)}`;
          window.open(url, "_blank", "noopener");
        },
      }, "Submit on GitHub"),
      h("button", {
        onclick: () => {
          game.tuneReset();
          save({});
          for (const k of Object.keys(saved)) delete saved[k];
          rows.forEach((r, i) => {
            const e = ordered[i]!;
            (r.querySelector("input") as HTMLInputElement).value = String(toShown(e, e.default));
            r.classList.remove("changed");
          });
          out.textContent = "";
        },
      }, "Reset to defaults"),
    ),
    out,
    h("table", { class: "bindings tune" }, ...rows),
  );
  return panel;
}
