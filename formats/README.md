# formats

Zig parsers for GTA2 data files. Carried forward from spike S1.

- `chunk.zig` - the shared `[4]u8 tag, u32 size` chunk container and a bounds-checked little-endian reader.
- `gmp.zig` - map files (`GBMP`): UMAP, CMAP and DMAP block grids, ZONE, MOBJ, LGHT, ANIM. Decodes face bits and the 64 slope codes into a `Shape`.
- `sty.zig` - style files (`GBST`): PALX, PPAL, PALB, TILE, SPRG, SPRX, SPRB. Tile pixel and palette colour lookup.
- `synth.zig` - writers for synthetic files, used for tests and demo content.

All parsers are pure functions over a byte slice: no I/O, no globals, usable from the sim, WASM and native tools. Each parse result owns an arena; call `deinit`.

Written from the published DMA "GBH Map Format" and "GBH Style Format" documents. No original game data is in this repo, and `.gitignore` blocks `.gmp`, `.sty` and `.scr` files. The axis and orientation conventions the docs leave open are written at the top of `gmp.zig` and listed in `spikes/s1/RESULT.md`.

```sh
cd formats && zig build test   # Zig 0.17.0
```

## Collision grid for the sim

`grid.zig` builds the I1 `abi.Grid` from a parsed map with `grid.build(&map, &grid)`: the 16-bit cells and the per-face wall table `walls` (one byte per cell: wall bits for the left, right, top and bottom faces, then bullet-wall bits; ramps' own side faces and partial blocks' faces left out). The mapping from GTA2 blocks to I1 cells is documented at the top of `grid.zig`. It also fills `surface` (W0): the red road arrows from the high nibble of each block's arrow byte, and, through `markElectrified(&map, &grid, &tiles)`, the electrified bit on cells whose lid tile is in a set the host builds from the style.

`gxt.zig` reads the `.gxt` text tables (public format: `GBL` and a language letter, a `TKEY` index of 8-byte keys and offsets, `TDAT` 16-bit strings). `Table.getId(500)` looks up the key "500", as scripts name their messages (script-messages.md 2.1). Client only; checked against the player's `e.gxt`.

`level.zig` builds the sim's static `Level` (zones, map objects with positions in sim fixed point, lights) from a parsed map: `var d = try formats.level.build(gpa, &map); sim.attachLevel(&d.level);`. The script is added by `scr.zig` when workstream A1 lands it. `formats` depends on `interfaces/zig` by path for the `abi` types.

`synth.zig` can also write sprites (SPRG, SPRX, SPRB), car remap palettes and map lights (LGHT), for the renderer's synthetic demo.

## Car models

`sty.zig` reads the CARI chunk (car info, from the public DMA style document) into `Style.cars`; `Style.carSprite(i)` gives a model's sprite within the car group. `gci.zig` parses the player's `.gci` handling file as described in `docs/behaviour/car-handling.md` (text tokens packed into 72-byte records, fractions with 14 bits). `cars.zig` joins the two by model number into one spec per style car for `sim.tuning.deriveModel`.

Deep water: `grid.zig` makes a flat block whose lid is one of the sea tiles 608-619 a `water` cell. The notes say the style marks water lids without naming the field; on every map in the player's files each column whose top is at level 0 has one of these lids, so the tile range stands in for it (ours).
