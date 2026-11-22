// Sound check: what the audio engine sees, and beeps that skip the game's
// banks, so a player who hears nothing can say where the sound stops. Shown
// on the game screen with ?soundcheck in the address, and on the sound board.

import type { AudioEngine } from "../audio/engine.ts";
import { clear, h } from "./dom.ts";

export function soundCheck(audio: AudioEngine, onClose?: () => void): HTMLElement & { dispose: () => void } {
  const rows = h("table", { class: "bindings sound-check-table" });
  const render = (): void => {
    clear(rows);
    for (const [k, v] of Object.entries(audio.diagnostics())) rows.append(h("tr", {}, h("th", {}, k), h("td", { class: "mono small" }, v)));
  };
  const btn = (label: string, fn: () => void): HTMLElement =>
    h("button", { tabindex: "-1", onclick: () => {
      fn();
      setTimeout(render, 300);
    } }, label);
  const el = h(
    "div",
    { class: "sound-check" },
    h(
      "div",
      { class: "row" },
      h("strong", {}, "Sound check"),
      btn("Beep (web audio)", () => audio.testTone()),
      btn("Beep (audio element)", () => audio.testToneHtml()),
      btn("Pistol", () => {
        audio.unlock();
        audio.play("pistol");
      }),
      onClose ? h("button", { tabindex: "-1", onclick: onClose }, "Close") : null,
    ),
    h("p", { class: "muted small" }, "If only the audio-element beep is heard, the device's silent mode is muting web audio. If neither is heard, check the volume and output. Send a screenshot of this table either way."),
    rows,
  ) as unknown as HTMLElement & { dispose: () => void };
  render();
  const timer = setInterval(render, 1000);
  el.dispose = () => clearInterval(timer);
  return el;
}
