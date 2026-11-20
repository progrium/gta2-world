// Remap screen: per-controller (by normalised id) and keyboard bindings.
// Click an action, then press the control. Escape cancels.

import { ACTION_LABELS, ANALOG_ACTIONS, type Action, BUTTON_ACTIONS, type PadBindings, type PadSource } from "../input/bindings.ts";
import type { MinimalGamepad } from "../input/gamepad.ts";
import { buttonGlyph } from "../input/controllerId.ts";
import { Effects, rumble, rumbleSupport } from "../input/rumble.ts";
import type { InputSystem } from "../input/system.ts";
import { clear, h } from "./dom.ts";

const ACTIONS: Action[] = [...ANALOG_ACTIONS, ...BUTTON_ACTIONS];

const axisLabel = (s: PadSource & { t: "a" }): string => `Axis ${s.i}${s.dir > 0 ? "+" : "−"}${s.full ? " (full)" : ""}`;

/** Wait for the next pad control that moves away from its resting state. */
function capturePad(get: () => MinimalGamepad | null, signal: AbortSignal): Promise<PadSource> {
  return new Promise((resolve, reject) => {
    const base = get();
    if (!base) return reject(new Error("controller disconnected"));
    const b0 = base.buttons.map((b) => b.value || (b.pressed ? 1 : 0));
    const a0 = [...base.axes];
    const tick = (): void => {
      if (signal.aborted) return reject(new Error("cancelled"));
      const gp = get();
      if (!gp) return reject(new Error("controller disconnected"));
      for (let i = 0; i < gp.buttons.length; i++) {
        const v = gp.buttons[i]!.value || (gp.buttons[i]!.pressed ? 1 : 0);
        if (v > 0.5 && (b0[i] ?? 0) < 0.3) return resolve({ t: "b", i });
      }
      for (let i = 0; i < gp.axes.length; i++) {
        const v = gp.axes[i]!;
        const d = v - (a0[i] ?? 0);
        if (Math.abs(d) > 0.6) {
          // An axis resting near -1 is a full-range trigger (non-standard mappings).
          const full = (a0[i] ?? 0) < -0.8;
          return resolve({ t: "a", i, dir: full ? 1 : d > 0 ? 1 : -1, full: full || undefined });
        }
      }
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
}

function captureKey(signal: AbortSignal): Promise<string> {
  return new Promise((resolve, reject) => {
    const on = (e: KeyboardEvent): void => {
      e.preventDefault();
      e.stopImmediatePropagation();
      window.removeEventListener("keydown", on, true);
      if (e.code === "Escape") reject(new Error("cancelled"));
      else resolve(e.code);
    };
    signal.addEventListener("abort", () => {
      window.removeEventListener("keydown", on, true);
      reject(new Error("cancelled"));
    });
    window.addEventListener("keydown", on, true);
  });
}

export function openRemap(host: HTMLElement, input: InputSystem, onClose: () => void): () => void {
  const panel = h("div", { class: "overlay", role: "dialog", "aria-label": "Controls" });
  let device: "keyboard" | number = input.players[0]?.pad ?? "keyboard";
  let busy: AbortController | null = null;
  const note = h("p", { class: "status", role: "status" });

  const close = (): void => {
    busy?.abort();
    off();
    panel.remove();
    onClose();
  };
  const off = input.on(() => render());

  const render = (): void => {
    clear(panel);
    const pads = [...input.pads.pads.values()];
    if (typeof device === "number" && !input.pads.pads.has(device)) device = "keyboard";
    const tabs = h(
      "div",
      { class: "tabs" },
      h("button", { class: device === "keyboard" ? "on" : "", onclick: () => ((device = "keyboard"), render()) }, "Keyboard"),
      ...pads.map((p) => h("button", { class: device === p.index ? "on" : "", onclick: () => ((device = p.index), render()) }, p.key.name)),
    );
    const rows = h("table", { class: "bindings" });

    if (device === "keyboard") {
      const kb = input.keyboard.bindings;
      for (const a of ACTIONS) {
        rows.append(
          h(
            "tr",
            {},
            h("td", {}, ACTION_LABELS[a]),
            h("td", { class: "mono" }, kb.actions[a].join(", ") || "—"),
            h(
              "td",
              {},
              h("button", {
                onclick: async () => {
                  busy?.abort();
                  busy = new AbortController();
                  note.textContent = `Press a key for ${ACTION_LABELS[a]} (Escape cancels)`;
                  try {
                    const code = await captureKey(busy.signal);
                    for (const k of ACTIONS) kb.actions[k] = kb.actions[k].filter((c) => c !== code);
                    kb.actions[a] = [code];
                    input.store.saveKeyboard(kb);
                    note.textContent = `${ACTION_LABELS[a]} is now ${code}.`;
                  } catch {
                    note.textContent = "";
                  }
                  render();
                },
              }, "Change"),
            ),
          ),
        );
      }
      panel.append(
        h("h2", {}, "Controls"),
        tabs,
        rows,
        note,
        h(
          "div",
          { class: "row" },
          h("button", { onclick: () => (input.store.resetKeyboard(), (input.keyboard.bindings = input.store.keyboard()), render()) }, "Reset keyboard"),
          h("button", { class: "primary", onclick: close }, "Done"),
        ),
      );
      return;
    }

    const idx = device;
    const st = input.pads.pads.get(idx)!;
    const b: PadBindings = structuredClone(st.bindings);
    const gp = (): MinimalGamepad | null => input.pads.gamepad(idx);
    const commit = (): void => input.pads.setBindings(idx, b);
    const srcLabel = (s: PadSource): string => (s.t === "b" ? buttonGlyph(st.family, s.i, st.mapping === "standard") : axisLabel(s));

    rows.append(
      h(
        "tr",
        {},
        h("td", {}, "Move stick"),
        h("td", { class: "mono" }, `Axis ${b.stick.x}${b.stick.invertX ? " (inv)" : ""} / ${b.stick.y}${b.stick.invertY ? " (inv)" : ""}`),
        h(
          "td",
          {},
          h("button", {
            onclick: async () => {
              busy?.abort();
              busy = new AbortController();
              try {
                note.textContent = "Push the stick fully RIGHT, then let go.";
                const x = await capturePad(gp, busy.signal);
                await settle(gp, busy.signal);
                note.textContent = "Now push the stick fully DOWN.";
                const y = await capturePad(gp, busy.signal);
                if (x.t !== "a" || y.t !== "a") throw new Error("That was a button. Use the stick.");
                b.stick = { x: x.i, y: y.i, invertX: x.dir < 0 || undefined, invertY: y.dir < 0 || undefined };
                commit();
                note.textContent = "Stick set.";
              } catch (e) {
                note.textContent = (e as Error).message === "cancelled" ? "" : (e as Error).message;
              }
              render();
            },
          }, "Change"),
        ),
      ),
    );
    for (const a of ACTIONS) {
      rows.append(
        h(
          "tr",
          {},
          h("td", {}, ACTION_LABELS[a]),
          h("td", { class: "mono" }, b.actions[a].map(srcLabel).join(", ") || "—"),
          h(
            "td",
            {},
            h("button", {
              onclick: async () => {
                busy?.abort();
                busy = new AbortController();
                note.textContent = `Press the control for ${ACTION_LABELS[a]}. Click Cancel to stop.`;
                try {
                  await settle(gp, busy.signal);
                  const s = await capturePad(gp, busy.signal);
                  b.actions[a] = [s];
                  commit();
                  note.textContent = `${ACTION_LABELS[a]} is now ${srcLabel(s)}.`;
                } catch (e) {
                  note.textContent = (e as Error).message === "cancelled" ? "" : (e as Error).message;
                }
                render();
              },
            }, "Change"),
          ),
        ),
      );
    }
    const support = rumbleSupport(gp());
    panel.append(
      h("h2", {}, "Controls"),
      tabs,
      h(
        "p",
        { class: "muted" },
        `${st.key.name} · id key ${st.key.key} · mapping "${st.mapping || "none"}" · ${st.bindingSource === "saved" ? "your remap" : st.bindingSource === "table" ? "known-pad table" : "defaults"} · rumble: ${support}`,
      ),
      st.mapping !== "standard" && st.bindingSource !== "saved"
        ? h("p", { class: "warn" }, "This browser doesn't report a standard layout for this controller, so the defaults are a guess. Set each control below.")
        : "",
      rows,
      note,
      h(
        "div",
        { class: "row" },
        h("button", { onclick: () => busy?.abort() }, "Cancel"),
        h("button", { onclick: () => rumble(gp(), Effects.test), disabled: support === "none" }, "Test rumble"),
        h("button", { onclick: () => (input.pads.resetBindings(idx), render()) }, "Reset controller"),
        h("button", { class: "primary", onclick: close }, "Done"),
      ),
    );
  };

  host.append(panel);
  render();
  return close;
}

/** Wait until every control is back near rest, so the press that opened capture isn't captured. */
function settle(get: () => MinimalGamepad | null, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const tick = (): void => {
      if (signal.aborted) return reject(new Error("cancelled"));
      const gp = get();
      if (!gp) return reject(new Error("controller disconnected"));
      const busy = gp.buttons.some((b) => b.pressed) || gp.axes.some((v) => Math.abs(v) > 0.4 && v > -0.8);
      if (!busy) return resolve();
      requestAnimationFrame(tick);
    };
    tick();
  });
}
