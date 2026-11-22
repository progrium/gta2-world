// HUD icons drawn from the player's own style: one sprite, its own palette,
// copied into a small 2D canvas (no WebGL). Used for the weapon icon next
// to the weapon line. The sprite numbers come from game.zig's picks.

import type { StyleData } from "../../../render/ts/src/index.ts";

const PAGE = 256 * 256;

/** Draws sprite `sprite` (absolute number) of `style` into `canvas`, scaled to fit; false if it has none. */
export function drawSprite(canvas: HTMLCanvasElement, style: StyleData, sprite: number): boolean {
  const t = style.spriteTable;
  if (sprite < 0 || sprite * 4 + 3 >= t.length) return false;
  const sx = t[sprite * 4]!;
  const sy = t[sprite * 4 + 1]!;
  const layer = t[sprite * 4 + 2]!;
  const wh = t[sprite * 4 + 3]!;
  const w = wh & 0xff;
  const h = wh >> 8;
  if (!w || !h) return false;
  // The table's layer counts the tile pages first.
  const tileLayers = Math.ceil(style.tiles.length / PAGE);
  const base = (layer - tileLayers) * PAGE;
  if (base < 0) return false;
  const virt = style.spritePaletteBase + sprite;
  const phys = style.palx[virt] ?? 0;
  const img = new ImageData(w, h);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const idx = style.spritePages[base + (sy + y) * 256 + sx + x] ?? 0;
      if (idx === 0) continue;
      const off = ((Math.floor(phys / 64) * 256 + idx) * 64 + (phys % 64)) * 4;
      const o = (y * w + x) * 4;
      img.data[o] = style.ppal[off + 2] ?? 0;
      img.data[o + 1] = style.ppal[off + 1] ?? 0;
      img.data[o + 2] = style.ppal[off] ?? 0;
      img.data[o + 3] = 255;
    }
  }
  const src = document.createElement("canvas");
  src.width = w;
  src.height = h;
  src.getContext("2d")?.putImageData(img, 0, 0);
  const ctx = canvas.getContext("2d");
  if (!ctx) return false;
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  ctx.imageSmoothingEnabled = false;
  const k = Math.min(canvas.width / w, canvas.height / h);
  ctx.drawImage(src, (canvas.width - w * k) / 2, (canvas.height - h * k) / 2, w * k, h * k);
  return true;
}
