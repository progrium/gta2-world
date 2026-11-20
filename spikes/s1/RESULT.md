# Spike S1 result: parse and draw a map

**Question (design doc):** Can we read real `.gmp` and `.sty` files and draw a district correctly?
**Passes when:** one full original map renders with correct tiles, slopes and transparency at 60 fps.

## Answer

**Accepted (19 Nov 2026), with known caveats.** Jeff judged the results good enough to move on. Frame rate passes in Chrome on macOS. Two things were never checked: transparency on the fixed build, and runs in Firefox and Safari. They are carried as caveats, listed at the end of "Tester results". Parsing and drawing were checked on real wil, ste and bil files (below), and two mesh bugs found that way are fixed. Jeff's Chrome run (see "Tester results") holds 120 fps on all three districts. He saw black where see-through faces should be, but the hosted viewer he used was built before the fix for exactly that bug, so that part needs a rerun on a redeployed site.

| Part of the criterion | Status here | Evidence |
| --- | --- | --- |
| Read `.gmp` | Done for UMAP, CMAP and DMAP, plus ZONE, MOBJ, LGHT, ANIM | Round-trip tests in all three encodings; corrupt and truncated files are rejected |
| Read `.sty` | Done for PALX, PPAL, PALB, TILE, SPRX, SPRB, SPRG | Round-trip test; tile pixels, palette mapping and the index-0 transparency rule |
| Runs in WASM | Done | The same Zig parsers compiled to `wasm32-freestanding` (850 KB); a full 256x256x8 map parses and meshes in about 160 ms in headless Chromium |
| Draw a full map | Done for synthetic data | A 256x256 synthetic city, 441k triangles, in one draw call |
| Correct tiles, slopes, transparency | Correct against our reading of the DMA docs; **not checked against the game** | Screenshots of the showcase: every slope code 1-61, the 4 rotations with and without flip, 4 lighting levels, a transparent fence and grate |
| 60 fps | **Passes in Chrome 156 on macOS (M3 Max)**; Firefox and Safari not run yet | 120 fps average, p99 9.3 ms, 0 frames over 17 ms on wil, ste and bil (Tester results below). The container's software renderer only manages 12 fps |

## Checked against real files (19 Nov 2026)

Run on wil, ste and bil from a community release of the game (kept outside the repo). The checks are reproducible with `python3 -I spikes/s1/tools/check_conventions.py /path/to/GTA2/data`, an independent numpy reading of the same files.

**Check 1, parsing: passes.** All six files parse with `s1 inspect`: no `FAILED`, `clamped columns 0` on every map, `tiles whose palette is out of range: 0` on every style, no unknown chunks. Guess 8 (column layout) is right.

| Guess | Verdict | Evidence from the data |
| --- | --- | --- |
| 1. Axes | **Right** | Top-down render: road text ("SLOW") reads correctly, and it sits in the lane of the traffic that reads it with right-hand driving. Side faces are set where the neighbour on their own side is air (left on x-1, top on y-1). |
| 2. Slope direction | **Right** | Codes rise by one per block toward the named direction in every group (e.g. wil: 435 of 435 up-7 neighbours). The top of a 7-degree ramp meets a full block ahead of it 464 times and something else 23 times over the three maps. |
| 3. Lid rotation and flip | **Right** | Colour continuity across neighbouring flat lids where one is flipped and quarter-turned: the mesh's convention (rotate clockwise, mirror after) gives a mean edge step of 8.7–10.9, close to the 6.9–8.5 of unrotated neighbours. Mirroring first gives 18.7–31.2. |
| 4. Diagonal face tile | **Right**, but the texture was mirrored | 45–52 use only the left face on left-facing pieces and only the right face on right-facing ones. The diagonal wall drew its tile mirrored relative to the box walls. **Fixed.** |
| 5. 3- and 4-sided diagonal slopes | **Plausible** | 53–89% of 49–52 definitions have lid 1023, so most are the 3-sided kind. In ste they are mostly 2x2 tree canopies (49 50 / 51 52 with a see-through branch tile), and they render as round trees. |
| 6. Flat side faces | **Was wrong. Fixed.** | In the real maps, a non-flat face with a see-through tile almost always sits opposite a flat face in the same block, usually with the same tile (bil: 1458 of 1474 definitions). It is the reverse of the flat face. The mesh drew it as a wall of its own, so railings, gantries, fences and bridge girders had solid black slabs behind them. Now a flat face whose opposite is not flat is drawn as two one-sided halves on its own edge, front with its tile and back with the opposite tile, both see-through. |
| 7. Partial blocks | **Right** | See-through lids on left and top partial blocks have their opaque pixels in x or y 0–24. |

Headless screenshots (software renderer) of ramps, diagonals, gantries and trees on all three maps look like the game after the two fixes. They are not committed, because they contain the game's art.

**Check 4, 60 fps: passes in Chrome on macOS** (Tester results below). Firefox and Safari are still to run.

## Tester results

Scored 19 Nov 2026 from the results issues. Pass for frame rate is `avgFps` ≥ 59 and `p99Ms` < 17 in each browser.

| Tester | Browser, OS, GPU | Map | avgFps | p99 ms | Worst ms | Over 17 ms | Tiles | Transparency | Slopes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Jeff (#6) | Chrome 156, macOS, Apple M3 Max, 3024x1714 | wil | 119.9 | 9.3 | 10.9 | 0 | Right | Mostly wrong | Right |
| | | ste | 120.0 | 9.3 | 10.8 | 0 | Right | Mostly wrong | Right |
| | | bil | 120.0 | 9.3 | 16.7 | 0 | Right | A few wrong | Right |

- **Frame rate passes on Chrome.** The rate is pinned at the 120 Hz display refresh with a flat 8.3 ms median, so the GPU has headroom. An M3 Max is well above the design doc's "mid-range laptop", so a run on a mid-range machine would be good to have too.
- **Transparency: rerun needed, not a fail yet.** Jeff's notes say black shows where see-through pixels should be on all three maps. That matches guess 6 above (solid black slabs behind railings and fences), which was fixed in a12f781 at 22:31 UTC. The hosted viewer (`site/s1` on main) was last built at 17:47 UTC, before the fix, and Jeff's run was at 23:08 UTC on that hosted page. Rerun checks 2 and 4 once the site is rebuilt from this branch.
- Parse counts match across loads (wil 266,833 triangles, ste 298,079, bil loaded), with `unknownChunks 0` and `clampedColumns 0`. That agrees with check 1.
- Data note: the first load in the file is `ste.gmp + wil.sty`, a mismatched pair. It wasn't benchmarked, so it doesn't affect anything.

**Known caveats, accepted:**
- Transparency hasn't been seen on the fixed build. Recheck it once the hosted viewer is rebuilt from this branch. If black slabs remain, the cause is in the mesh (`src/mesh.zig`), not the parsers.
- Frame rate and correctness are untested in Firefox and Safari.
- The benchmark has only run on a high-end GPU (M3 Max), not a mid-range laptop.

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
