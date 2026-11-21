# client/render: workstream B renderer

Map meshing, style textures, render lists and the WebGL2 renderer for M1. Carried forward from spike S1 (parsers in `formats/`, the mesh rules and their real-data fixes), rebuilt for production.

| Part | File | What it does |
| --- | --- | --- |
| Map mesh | `src/mesh.zig` | 16x16-block chunks over all 8 layers, one vertex range and bounding box per chunk. Faces against a closed opaque cube are dropped. The map's coloured lights (LGHT) are baked into each vertex. 16-byte vertices, 64 units per block. |
| Style data | `src/style.zig` | The TILE and SPRG pages are uploaded as is, as one R8UI texture array (tiles first, then sprites). PPAL and PALX are uploaded as is too. The only thing built is a 64-wide sprite table (x, y, layer, w and h per sprite). |
| Render list | `src/list.zig` | Reads any I1 state through `views()` and writes 24-byte instances (x, y, z, angle, sprite, palette, kind). It can interpolate between two states. Peds riding a vehicle are skipped. `target()` gives the camera the player's car or ped plus velocity. |
| Stub entities | `src/stub.zig` | A traffic stub that drives cars along the road arrows and walks peds on pavements, laid out as an I1 state with a view table. Also the `.grec` recorded entity buffer format (view table plus one state per tick) and a recorder. |
| Renderer | `ts/src/renderer.ts` | WebGL2. Chunks are frustum-culled and runs of adjacent visible chunks merged into one draw call. Sprites are one instanced draw. Map lights are scaled by a uniform (`lighting.ambient`, `lighting.lightGain`). Animated tiles go through a 1024-entry lookup texture. An optional viewport handles split-screen. |
| Cameras | `ts/src/camera.ts` | `ChaseCamera` is top-down perspective. It follows a target and pulls back with speed (`baseHeight` 7 blocks, plus 0.6 per block/s, up to 15), rising faster than it settles. `FreeCamera` is for debugging. |
| Demo | `ts/src/demo.ts`, `demo/`, `src/demo_wasm.zig` | A standalone page. It also shows how a host hands the Zig buffers to the renderer. |

The shell imports `ts/src/index.ts` and owns the canvas and the frame loop: `new Renderer(canvas)`, `setStyle()`, `setMap()`, `resize(cssW, cssH, dpr)`, then `draw(camera.view(), instances, count, timeSec, viewport?)` each frame. `client/wasm` depends on this package (`render` module) for `mesh.buildChunked`, `style.prepare` and `list.build`. `demo_wasm.zig` is the reference for which buffers to export.

## Build and run

```sh
cd client/render
zig build test                      # Zig 0.17.0
(cd ts && tsc -p .)                 # TypeScript 5+, no other dependencies
zig build web -Doptimize=ReleaseFast            # zig-out/web: page, wasm, synthetic fixtures
zig build -Doptimize=ReleaseFast                # zig-out/bin/render-tool
```

To view the demo, serve `zig-out/web` with any static server and open `?demo` for the synthetic showcase. It needs no game files: cars, peds, car remaps, road arrows and lights are all generated. To use your own GTA2 copy, pick the `.gmp` and `.sty` files in the panel; they are read in the tab and never uploaded. Keys: F free camera, N night lighting, P pause. `?gmp=URL&sty=URL[&rec=URL][&bench=20][&night]` loads served files.

`render-tool inspect map.gmp` prints mesh and collision stats. `render-tool record map.gmp out.grec [ticks] [cars] [peds]` records the traffic stub. Recordings made on original maps hold positions on those maps, so keep them out of the repo; `.gitignore` covers `*.grec`.

## Measured (headless Chromium, software GL, 1000x700, chase camera)

| Map | Triangles | Load (parse, mesh, light bake) | Bench 10 s |
| --- | --- | --- | --- |
| wil | 266,809 | 65 ms | 57 fps avg |
| ste | 298,047 | 72 ms | 53 fps avg |
| bil | 329,178 | 75 ms | 48 fps avg |

With the chase camera, 4 to 9 of the 256 chunks are in view, in 3 or 4 draw calls. S1 drew the whole map in one call and ran at 12 fps on the same software renderer. A real GPU number still needs a person to run the benchmark.

Hidden-face removal drops only 14 to 86 faces on the real districts. The original map compressor already leaves interior faces out: building interiors are empty cells, not closed cubes. The pass stays because it is cheap and it helps on synthetic and edited maps.

## Open items and readings to confirm

- **Appearance is not in I1 v1.** The renderer needs a sprite and remap per entity. `list.zig` reads a proposed component, id 12 `Appearance { sprite: u16, remap: u16 }`, when a sim's views list it. The sprite number is relative to the kind's sprite group. Without it, every entity draws its group's first sprite. This needs a proposal accepted by the sim (A) and netcode (C) owners.
- **Car model to sprite** needs the style's car info (CARI). That parsing waits for the clean-room behaviour notes, so for now the sim's model number is used directly as the car sprite number. Ped walk frames are likewise the sim's to choose.
- **Animated tiles:** `frame_rate` is read as game frames (30 per second) per animation frame, looping, and `repeat` is ignored.
- **Lights:** linear falloff inside the radius, scaled by intensity, flicker not modelled. Day lighting adds them at 0.35 strength and night at full strength. The format docs give no lighting model, so this is our choice.
- **Sprite orientation:** sprites face down (+y) in the image (cars, peds and the rest), so `list.zig` adds 180 degrees to every heading and the shader draws the image's top along it. Cars line up with their lanes and drive bonnet first, and peds walk face first (both fixed after play-testing M3).
- **Sprite and remap palettes:** sprite s uses virtual palette `PALB.sprite base + s`, and remap r of a group uses that group's remap base + r. Remapped peds on real maps show varied clothing, as expected.
- **Doors, traffic lights and pickups (client/wasm `decorate`, `doorFaces`).** Read from the player's own style and map files and checked by drawing them. A door's animation frames (script type 230) are tile numbers, closed to open, so a door leaf is a wall face showing the current tile, rebuilt each frame into a small second vertex buffer (`setExtraFaces`); a double door's second leaf is on the open block beside it. Traffic light lamps are the last three code objects (549 red, 550 green, 551 amber, 18x4), laid across the lane on top of the light's gantry, which the map builds from blocks. Script pickups (object models 200-244 and 64-108) are the spinning code-object icons in the public COLLECT order. Script object types the style has no OBJI entry for are not drawn.
- **Tyre marks (client/wasm `skids.zig`, `setMarks`).** Ours until the skid-marks note: rear wheels mark while a car slides sideways faster than 0.045 blocks a tick or drags the handbrake, all four when a player (not traffic) locks the brakes over 0.12 blocks a tick. Marks are 0.1 block wide, blended dark over the road and fade over 25 s; at most 4096 segments are kept.
