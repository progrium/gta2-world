// Remaps stored per normalised controller key in localStorage.
// A pad remap is saved under both its vid:pid key and its name key, so Safari
// (name only) finds a remap made in Chrome or Firefox for the same model.

import { type KeyBindings, type PadBindings, KNOWN_PADS, defaultKeyBindings, defaultNonStandardBindings, defaultPadBindings } from "./bindings.ts";
import type { ControllerKey } from "./controllerId.ts";

const PREFIX = "gta2.remap.";
const KEYBOARD = "keyboard";

export interface KV {
  getItem(k: string): string | null;
  setItem(k: string, v: string): void;
  removeItem(k: string): void;
}

function safeStorage(): KV | null {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

function parse<T extends { version: number }>(s: string | null): T | null {
  if (!s) return null;
  try {
    const v = JSON.parse(s) as T;
    return v && v.version === 1 ? v : null;
  } catch {
    return null;
  }
}

export class RemapStore {
  private kv: KV | null;

  constructor(kv: KV | null = safeStorage()) {
    this.kv = kv;
  }

  private names(k: ControllerKey): string[] {
    const nameKey = `name:${k.name.toLowerCase()}`;
    return k.key === nameKey ? [k.key] : [k.key, nameKey];
  }

  /** Saved remap, else the built-in table, else defaults for the reported mapping. */
  pad(k: ControllerKey, mapping: string): { bindings: PadBindings; source: "saved" | "table" | "default" } {
    for (const n of this.names(k)) {
      const v = parse<PadBindings>(this.get(PREFIX + n));
      if (v) return { bindings: v, source: "saved" };
    }
    const known = KNOWN_PADS[k.key];
    if (known) return { bindings: known(), source: "table" };
    return { bindings: mapping === "standard" ? defaultPadBindings() : defaultNonStandardBindings(), source: "default" };
  }

  savePad(k: ControllerKey, b: PadBindings): void {
    for (const n of this.names(k)) this.set(PREFIX + n, JSON.stringify(b));
  }

  resetPad(k: ControllerKey): void {
    for (const n of this.names(k)) this.del(PREFIX + n);
  }

  keyboard(): KeyBindings {
    return parse<KeyBindings>(this.get(PREFIX + KEYBOARD)) ?? defaultKeyBindings();
  }

  saveKeyboard(b: KeyBindings): void {
    this.set(PREFIX + KEYBOARD, JSON.stringify(b));
  }

  resetKeyboard(): void {
    this.del(PREFIX + KEYBOARD);
  }

  private get(k: string): string | null {
    try {
      return this.kv?.getItem(k) ?? null;
    } catch {
      return null;
    }
  }
  private set(k: string, v: string): void {
    try {
      this.kv?.setItem(k, v);
    } catch {
      /* storage full or blocked: the remap lasts for this page only */
    }
  }
  private del(k: string): void {
    try {
      this.kv?.removeItem(k);
    } catch {
      /* ignore */
    }
  }
}
