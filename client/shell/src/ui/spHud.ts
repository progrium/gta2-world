// The single-player HUD (workstream H): points, multiplier, lives, wanted
// stars, the banner message, the typed-out brief with its portrait, the
// pager (countdown and counters), the arrow, and the big centre messages
// (wasted, busted, game over, level complete).
//
// It draws only what the sim's SP state says (`SpHud` from game.wasm, owned
// by workstreams A1, G and E) plus the text from the player's own .gxt.
// Layout, colours and the brief's portrait badge are ours until the HUD
// note lands; the rules it follows are script-messages.md (banner, brief
// typing at 3 ticks a character, timer and counter displays) and
// power-ups-death-and-arrest.md (death messages by cause).

import type { SpHud } from "../game/wasm.ts";
import { BRIEF_TICKS_PER_CHAR, FALLBACK_TEXT, PORTRAIT_COLOURS, type TextSpan, arrowAngle, formatPoints, formatTimer, parseGameText, truncateSpans } from "../game/text.ts";
import { clear, h } from "./dom.ts";

export interface TextSource {
  /** A script message number's text, or null. */
  text(id: number): string | null;
  /** A named key's text ("wasted", "g_over", ...), or null. */
  textKey(key: string): string | null;
}

/** Ticks a big centre message stays up (ours; the sim's own countdown is 70). */
const CENTRE_TICKS = 70;
const MAX_STARS = 6;

export class SpHudView {
  readonly el: HTMLElement;
  private top = h("div", { class: "sp-top" });
  private points = h("span", { class: "sp-points" });
  private mult = h("span", { class: "sp-mult" });
  private lives = h("span", { class: "sp-lives" });
  private stars = h("div", { class: "sp-stars", title: "Wanted level" });
  private banner = h("div", { class: "sp-banner hidden" });
  private brief = h("div", { class: "sp-brief hidden" });
  private portrait = h("div", { class: "sp-portrait" });
  private briefText = h("div", { class: "sp-brief-text" });
  private pager = h("div", { class: "sp-pager hidden" });
  private arrow = h("div", { class: "sp-arrow hidden" }, "➤");
  private centre = h("div", { class: "sp-centre hidden" });
  private centreUntil = 0;
  private briefId = 0;
  private briefStart = 0;
  private lastKey = "";

  private readonly src: TextSource;

  constructor(src: TextSource) {
    this.src = src;
    this.top.append(this.points, this.mult, this.lives);
    this.brief.append(this.portrait, this.briefText);
    this.el = h("div", { class: "sp-hud" }, this.top, this.stars, this.banner, this.brief, this.pager, this.arrow, this.centre);
  }

  /** A named key's text, or our own words when the player has no .gxt. */
  keyText(key: string): string {
    const t = this.src.textKey(key);
    return t !== null ? parseGameText(t).plain : (FALLBACK_TEXT[key] ?? key.toUpperCase());
  }

  /** Shows a big centre message (wasted, busted, ...) for `ticks`. */
  showCentre(text: string, tick: number, ticks = CENTRE_TICKS, kind = ""): void {
    this.centre.textContent = text;
    this.centre.className = `sp-centre ${kind}`;
    this.centreUntil = tick + ticks;
  }

  /**
   * Redraws from the SP state. `player` is the followed position in blocks
   * (the screen centre, near enough); the arrow points from it.
   */
  update(s: SpHud, player: { x: number; y: number } | null): void {
    this.points.textContent = formatPoints(s.points);
    this.mult.textContent = s.multiplier > 1 ? `×${s.multiplier}` : "";
    this.lives.textContent = s.lives > 0 ? `${s.lives} ${s.lives === 1 ? "life" : "lives"}` : "";
    const starsKey = `${s.stars}`;
    if (this.stars.dataset.n !== starsKey) {
      this.stars.dataset.n = starsKey;
      clear(this.stars);
      for (let i = 0; i < MAX_STARS; i++) this.stars.append(h("span", { class: i < s.stars ? "on" : "" }, "★"));
      this.stars.classList.toggle("hidden", s.stars === 0);
    }
    // Banner: the one-line message while its ticks last.
    if (s.banner && s.bannerTicks > 0) {
      const t = this.src.text(s.banner);
      setSpans(this.banner, t === null ? [{ text: `[${s.banner}]`, hi: false }] : parseGameText(t).spans);
      this.banner.classList.remove("hidden");
    } else this.banner.classList.add("hidden");
    // Brief: the front of the queue types itself out.
    const front = s.briefs[0] ?? 0;
    if (front !== this.briefId) {
      this.briefId = front;
      this.briefStart = s.tick;
    }
    if (front) {
      const raw = this.src.text(front);
      const g = raw === null ? { portrait: null, spans: [{ text: `[${front}]`, hi: false }], plain: "" } : parseGameText(raw);
      const shown = Math.floor((s.tick - this.briefStart) / BRIEF_TICKS_PER_CHAR) + 1;
      setSpans(this.briefText, truncateSpans(g.spans, shown));
      const colour = (g.portrait && PORTRAIT_COLOURS[g.portrait.toLowerCase()]) || "#8a8f98";
      this.portrait.style.background = colour;
      this.portrait.textContent = g.portrait ? g.portrait.toUpperCase() : "";
      this.brief.classList.remove("hidden");
    } else this.brief.classList.add("hidden");
    // Pager: countdown and counters.
    const parts: string[] = [];
    if (s.timer > 0) parts.push(formatTimer(s.timer));
    for (const c of s.counters) if (c !== 0) parts.push(String(c));
    const key = parts.join("  ");
    if (key !== this.lastKey) {
      this.lastKey = key;
      this.pager.textContent = key;
      this.pager.classList.toggle("hidden", !key);
    }
    this.pager.classList.toggle("flash", s.timer > 0 && s.timer <= 10 * 30 && Math.floor(s.tick / 8) % 2 === 0);
    // Arrow: around the screen centre, toward the target.
    if (s.arrow && player) {
      const a = arrowAngle(player.x, player.y, s.arrow.x, s.arrow.y);
      const near = Math.hypot(s.arrow.x - player.x, s.arrow.y - player.y) < 1.5;
      this.arrow.style.transform = `translate(-50%, -50%) rotate(${a}rad) translateX(64px)`;
      this.arrow.classList.toggle("hidden", near);
    } else this.arrow.classList.add("hidden");
    this.centre.classList.toggle("hidden", s.tick >= this.centreUntil);
  }

  /** Hides the timed parts (a new game). */
  reset(): void {
    this.centreUntil = 0;
    this.briefId = 0;
    this.centre.classList.add("hidden");
  }
}

function setSpans(el: HTMLElement, spans: readonly TextSpan[]): void {
  const key = JSON.stringify(spans);
  if (el.dataset.k === key) return;
  el.dataset.k = key;
  clear(el);
  for (const sp of spans) el.append(sp.hi ? h("em", {}, sp.text) : document.createTextNode(sp.text));
}
