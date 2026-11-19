# Spike S1 result: parse and draw a map

**Question (design doc):** Can we read real `.gmp` and `.sty` files and draw a district correctly?
**Passes when:** one full original map renders with correct tiles, slopes and transparency at 60 fps.

## Answer

**Not yet a yes. Everything is built and works on synthetic data, but the pass criterion needs real GTA2 files, which this spike could not use.** It becomes a **yes** if the four local checks below pass on your copy. If check 1 fails, the fix is almost certainly a small parser change, not the fallback.

| Part of the criterion | Status here | Evidence |
| --- | --- | --- |
| Read `.gmp` | Done for UMAP, CMAP and DMAP, plus ZONE, MOBJ, LGHT, ANIM | Round-trip tests in all three encodings; corrupt and truncated files are rejected |
| Read `.sty` | Done for PALX, PPAL, PALB, TILE, SPRX, SPRB, SPRG | Round-trip test; tile pixels, palette mapping and the index-0 transparency rule |
| Runs in WASM | Done | The same Zig parsers compiled to `wasm32-freestanding` (850 KB); a full 256x256x8 map parses and meshes in about 160 ms in headless Chromium |
| Draw a full map | Done for synthetic data | A 256x256 synthetic city, 441k triangles, in one draw call |
| Correct tiles, slopes, transparency | Correct against our reading of the DMA docs; **not checked against the game** | Screenshots of the showcase: every slope code 1-61, the 4 rotations with and without flip, 4 lighting levels, a transparent fence and grate |
| 60 fps | **Not measured on a real GPU** | The container only has a software renderer, which runs this scene at 12 fps. At 441k triangles and one draw call, a mid-range laptop GPU should easily hold 60 fps, but that is an estimate until you run the benchmark |

## What you need to run (about 10 minutes)

You need Zig 0.17.0 and your own GTA2 install. The three districts are `wil` (Downtown), `ste` (Residential) and `bil` (Industrial) in GTA2's `data/` folder.

```sh
git fetch origin spike/s1 && git checkout spike/s1
cd spikes/s1
zig build test                       # parser and mesh tests
zig build                            # native tool + zig-out/web (viewer, wasm, synthetic fixtures)

# Check 1: all three districts parse.
GTA2=/path/to/GTA2/data
./zig-out/bin/s1 inspect $GTA2/wil.gmp $GTA2/ste.gmp $GTA2/bil.gmp $GTA2/wil.sty $GTA2/ste.sty $GTA2/bil.sty

# Checks 2-4: the viewer.
python3 -m http.server -d zig-out/web 8000
```

**Check 1: parsing.** It passes if no file prints `FAILED`, every map shows `clamped columns 0`, and every style shows `tiles whose palette is out of range: 0`. Paste the output back into the thread either way; the chunk list and slope-code histogram are useful even when it passes.

**Check 2: tiles and transparency.** Open http://localhost:8000, pick `wil.gmp` and `wil.sty` and press *Load files*. The files stay in the browser tab and are never uploaded. Fly around (click to capture the mouse, WASD, Space and C, Shift, mouse wheel for speed) and compare with the game. Look for:
- The right tile images and colours on roads, pavements and roofs.
- Lid rotation and flip. Road markings and arrows on junctions should line up. Rotation is taken as clockwise, with the flip applied first. If every rotated lid is wrong the same way, that is a one-line fix in `orient` in `src/mesh.zig`.
- Transparency on flat faces: fences, railings, grates and bridge edges should have holes, not black or solid areas.

**Check 3: slopes and odd shapes.** Look at ramps, bridges and the motorway on-ramps. The places most likely to be wrong are listed under "Guesses" below. If something looks off, send a screenshot with its rough block coordinates; the `1`-`4` keys jump to the map quarters, which helps describe where it is.

**Check 4: 60 fps.** In current Chrome, Firefox and Safari on a mid-range laptop, load `wil` and press *Benchmark 20 s*. It flies a fixed low, tilted orbit and then a high top-down pass, and prints `avgFps`, `p99Ms` and `over17ms`. It passes if `avgFps` is 59 or more and `p99Ms` is under 17. You can also open `http://localhost:8000/?gmp=data/wil.gmp&sty=data/wil.sty&bench=20` after `ln -s $GTA2 zig-out/web/data`. `zig-out` is git-ignored.

Then repeat checks 2 and 4 for `ste` and `bil`. The design doc's risk table asks for all three districts.

## Guesses to confirm against the game

The DMA documents leave these open. Each one is isolated in a single function, so a mismatch is a small fix, not a redesign.

1. **Axes.** x grows east and y south. `left` and `right` are the faces at x and x+1, and `top` and `bottom` the faces at y and y+1. The lid is the top of the block. If the whole map comes out mirrored, this is the cause.
2. **Slope direction.** "Up" is taken to mean the high end is toward smaller y (north), and for the 7-degree codes the lowest code in each group is the low end. If every ramp is reversed, swap the arms of `rampHeights`.
3. **Lid rotation** is clockwise and the flip is applied before rotation (`orient`).
4. **Diagonal walls (45-48)** draw the `left` tile on the diagonal for left-facing diagonals and the `right` tile for right-facing ones (`diagonalFace`).
5. **3- and 4-sided diagonal slopes (49-52).** A lid of 1023 is drawn as a 3-sided spire rising to the far corner. Otherwise the block is drawn as a 4-sided inner corner with the facing corner low. This reading comes from editor screenshots, not the DMA doc.
6. **Flat side faces** are drawn on their own edge and visible from both sides with their own tile. The doc says the reverse side uses the opposite face's tile. That detail is not implemented yet.
7. **Partial blocks** are 24 pixels wide (centre: 16) and use the matching part of each tile.
8. **Column layout.** A DMAP column header is one dword (height, offset, pad), followed by `height - offset` block indices. If check 1 fails with `BadColumn` or `BadBlockIndex`, this is the cause. The parser fails loudly rather than guessing, so you will see it.

## Not in scope for S1

These are parsed but not yet drawn: animated tiles (ANIM), map lights (LGHT), map objects (MOBJ), sprites, and junctions (RGEN, skipped). Side shading is a fixed per-direction darkening, not the game's lighting model.

## What carries forward

- `formats/`: the parsers, the chunk reader and the synthetic-file writers, with tests. They are pure functions over byte slices, so they suit the sim (the 256x256x8 block grid is `Map.cells` plus `Map.blocks`), the client and tools.
- Worth keeping as an idea, not as code: the index-plus-per-tile-palette texture pair. It makes palette index 0 exact for transparency, and palette remaps (car colours, lighting variants) become a row swap.
- Everything in `spikes/s1/` is throwaway: the mesh builder, the viewer and the showcase.

## If it fails

If parsing fails on real files in a way that cannot be fixed quickly, the design doc's fallback applies: convert the assets offline with community tools into our own format. Nothing found so far points that way. The DMA layouts were complete enough to write both parsers, and the remaining unknowns are rendering conventions, not file structure.

Toolchain note: Zig 0.17.1 exists. The spike uses the pinned 0.17.0.
