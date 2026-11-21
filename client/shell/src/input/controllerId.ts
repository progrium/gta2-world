// Normalised controller key, so a remap saved in one browser applies in the
// others. S6: the same pad reports a different `id` in each browser.
//   Chrome:  "Xbox Wireless Controller (STANDARD GAMEPAD Vendor: 045e Product: 0b13)"
//   Firefox: "045e-0b13-Xbox Wireless Controller"
//   Safari:  "Xbox Wireless Controller" (no vendor or product)
//   Chrome on macOS can also omit them: "DualSense Wireless Controller (STANDARD GAMEPAD)"
//   (S6, Jeff's DualSense run), and XInput pads on Windows always do.
// The key is "vid:pid" when the id carries them, otherwise "name:<lowercased name>".
// Safari therefore gets a name key that differs from the other two; the remap
// store falls back from one to the other (see remapStore.ts).

export interface ControllerKey {
  /** Stable storage key. */
  key: string;
  /** "045e:0b13" or null. */
  vidPid: string | null;
  /** Human-readable name with browser decoration removed. */
  name: string;
}

const hex4 = (s: string): string => s.toLowerCase().padStart(4, "0");

export function normalizeControllerId(id: string): ControllerKey {
  const raw = id.trim();
  let vidPid: string | null = null;
  let name = raw;

  const chrome = /\(\s*(?:[^()]*?)Vendor:\s*([0-9a-f]{1,4})\s+Product:\s*([0-9a-f]{1,4})\s*\)\s*$/i.exec(raw);
  const firefox = /^([0-9a-f]{1,4})-([0-9a-f]{1,4})-(.*)$/i.exec(raw);
  if (chrome) {
    vidPid = `${hex4(chrome[1]!)}:${hex4(chrome[2]!)}`;
    name = raw.slice(0, chrome.index);
  } else if (firefox) {
    vidPid = `${hex4(firefox[1]!)}:${hex4(firefox[2]!)}`;
    name = firefox[3]!;
  }
  // Chrome's XInput path: "Xbox 360 Controller (XInput STANDARD GAMEPAD)".
  name = name.replace(/\((?:[^()]*\b)?STANDARD GAMEPAD[^()]*\)\s*$/i, "");
  name = name.replace(/\s+/g, " ").trim() || "unknown controller";
  const key = vidPid ? vidPid : `name:${name.toLowerCase()}`;
  return { key, vidPid, name };
}

/** Rough family, for button glyphs and default-binding hints. Position-based mapping stays the same. */
export type PadFamily = "xbox" | "playstation" | "nintendo" | "generic";

/** Button names by standard-mapping position, per family (S6 gap 7: positions, not labels). */
const GLYPHS: Record<PadFamily, readonly string[]> = {
  xbox: ["A", "B", "X", "Y", "LB", "RB", "LT", "RT", "View", "Menu", "LS", "RS", "D-pad up", "D-pad down", "D-pad left", "D-pad right", "Guide"],
  playstation: ["Cross", "Circle", "Square", "Triangle", "L1", "R1", "L2", "R2", "Create", "Options", "L3", "R3", "D-pad up", "D-pad down", "D-pad left", "D-pad right", "PS"],
  nintendo: ["B", "A", "Y", "X", "L", "R", "ZL", "ZR", "−", "+", "LS", "RS", "D-pad up", "D-pad down", "D-pad left", "D-pad right", "Home"],
  generic: ["Bottom", "Right", "Left", "Top", "L1", "R1", "L2", "R2", "Select", "Start", "L3", "R3", "D-pad up", "D-pad down", "D-pad left", "D-pad right", "Home"],
};

export function buttonGlyph(family: PadFamily, index: number, standard: boolean): string {
  return (standard && GLYPHS[family][index]) || `Button ${index}`;
}

export function padFamily(k: ControllerKey): PadFamily {
  const vendor = k.vidPid?.slice(0, 4);
  if (vendor === "045e") return "xbox";
  if (vendor === "054c") return "playstation";
  if (vendor === "057e") return "nintendo";
  const n = k.name.toLowerCase();
  if (/xbox|xinput/.test(n)) return "xbox";
  if (/dualsense|dualshock|playstation|wireless controller$/.test(n)) return "playstation";
  if (/switch|pro controller|joy-?con/.test(n)) return "nintendo";
  return "generic";
}
