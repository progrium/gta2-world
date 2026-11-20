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

`grid.zig` builds the I1 `abi.Grid` (16-bit cells) from a parsed map with `grid.build(&map, &grid)`, and a per-face wall table with `grid.buildWalls(&map, &walls)` (one byte per cell: wall bits for the left, right, top and bottom faces, then bullet-wall bits). The mapping from GTA2 blocks to I1 cells is documented at the top of `grid.zig`. `formats` depends on `interfaces/zig` by path for the `abi` types.
