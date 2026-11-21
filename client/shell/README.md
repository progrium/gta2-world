# client/shell

Workstream E: the browser shell. TypeScript, no framework, bundled with esbuild.
Owns input and gamepad, asset import, the frame loop and the UI. It loads
`game.wasm` (client/wasm: the sim, map and render-list builders) and draws with
the WebGL2 renderer from client/render. Transport (C/D) plugs in at M2.

`client/build-web.sh [out]` builds everything into one static folder; the
tester site's `play/` page is that folder.

```sh
npm install
npm run check   # tsc, no emit
npm test        # node --test on the pure parts (input, assets, loop)
npm run build   # dist/main.js + dist/worker.js
npm run dev     # rebuild on change and serve on http://localhost:8000
```

Serve the folder over `localhost` or https: gamepads and OPFS need a secure context.

## What's here

| Path | What it does |
| --- | --- |
| `src/input/` | Keyboard and gamepad to I2 frames (`interfaces/I2-input-frame.md`). |
| `src/assets/` | Folder pick, drag-drop, worker hashing and checks, OPFS cache keyed by SHA-256. |
| `src/loop.ts` | rAF-driven fixed 30 Hz clock: poll every frame, latch every tick, render with alpha. |
| `src/session.ts` | Fixed session id `m1-local`, or `#s=<id>` from the link. |
| `src/game/wasm.ts` | Loads `game.wasm`; copies files in, hands buffers to the renderer, steps the sim, reads player info and tuning. |
| `src/audio/` | Sound banks (.sdt/.raw), WebAudio engine, the cue list and mapping, procedural fallbacks. |
| `src/ui/` | Import screen, game screen (real map, sim and renderer, HUD), controls (remap) overlay, handling tuning panel, sound board. |

## Single player

Story levels come from a `.seq` file in the player's data (`MainOrBonus`, `GMPFile`, `STYFile`, `SCRFile`, `Description` blocks: main areas and bonus stages, in order), or, without one, from each `.gmp` with a same-named `.sty` and `.scr`. The import screen lists them under "Single player" above the deathmatch maps, with a choice of `.gxt` when there are several (`e.gxt` by default).

Starting one loads the `.gxt`, the main `.scr` and the `.scr` files in the folder named after it (the mission sub-scripts) into `game.wasm` and runs the `sp` sim (`spStart`). `src/ui/spHud.ts` draws the HUD from `spInfo()`: points, multiplier and lives (top right), wanted stars (top centre), the banner message, the brief typing itself out at 3 ticks a character with a portrait badge from the text's speaker marker, the pager with the countdown and counters, and the arrow toward the mission target. Wasted (by cause: wasted, fried, shocked), busted, game over and level complete show as big centre text from the player's own `.gxt` keys, and the camera holds on the body, pulled back, for the 70-tick countdown. Text markup: `#` toggles highlighted words.

What the HUD shows is filled in by the sim's workstreams (script engine A1, career G, wanted level E); until they land it stays empty. `?hudtest` feeds it a made-up state that cycles through every part, to look at the layout. Layout and colours are ours until the HUD note lands.

## Input

- Every device produces the same 8-byte I2 frame. Slot 0 is the keyboard plus the first pad; further pads join as local players with Start (off on the M1 screen).
- Pads are polled once per animation frame and latched once per tick. Buttons seen at any poll (or key press, or Chromium `gamepadrawinputchanged` report) inside a tick are ORed into that tick's frame, so short taps aren't lost (S6: 26% of pad updates fall between frames).
- Sticks: radial deadzone 0.15, clamped to the unit circle (S6: square-ish gates reach 1.22 on diagonals).
- Car: steer from the stick x, throttle from `RT − LT`, analog. Digital triggers (Switch Pro) give ±127; the shell never ramps. Keyboard and d-pad up/down also drive; the stick's y never brakes.
- On foot: tank (steer + walk) or direct (`direct` bit, `aim` from the stick, speed from its magnitude, heading kept when centred). "Auto" uses direct after pad input and tank after keys. On foot, RT also fires.
- Rumble through `vibrationActuator`: dual-rumble where present, trigger-rumble only where listed. Firefox has none, Safari has no trigger-rumble (S6). Never throws.
- Hot-plug from `gamepadconnected`/`gamepaddisconnected` and from polling (events can be late in background tabs). A pad that comes back returns to its slot. The HUD asks for a button press while no pad is visible.
- Remaps are stored in `localStorage` per normalised controller key: `vid:pid` where the id carries it (Chrome, Firefox), else `name:<name>` (Safari). Each pad remap is saved under both keys, so Safari finds a remap made elsewhere. Non-standard mappings get a warning and a guessed layout until remapped. `KNOWN_PADS` in `bindings.ts` is the per-controller table, empty until probe runs show a pad that needs an entry.

Default pad layout (standard mapping, by position): RT accelerate, LT brake, X fire, Y enter/exit, A handbrake/jump, B run, RB/LB next/previous weapon, LS click horn. Home is never bound.
Default keys: arrows or WASD, Ctrl or J fire, Enter or F enter/exit, Space handbrake/jump, Z/X or Q/E weapons, C horn, Shift run.

## Assets

The player picks their GTA2 folder (File System Access where available, else a `webkitdirectory` input), picks files, or drops a folder. A module worker hashes each `.gmp .sty .scr .mmp .seq .gxt .sdt .raw .gci`, checks `.gmp`/`.sty` headers and chunk tables, parses `.mmp` map descriptors, and writes the bytes to OPFS under `gta2/blobs/<sha256>` with a manifest. Nothing is uploaded. `AssetStore.find(name)` and `AssetStore.read(hash)` are the API for the renderer and sim; reads re-check the hash.

Maps on offer come from `.mmp` files whose `.gmp` and `.sty` are present; without any `.mmp`, same-named `.gmp`/`.sty` pairs. With cached assets, the page opens straight into the last map.

## Sound

`src/audio/index.ts` exports `audio`, the one engine the game screen talks to:

```ts
audio.play(cue, x, y, z);     // one-shot at a world position in blocks; no position = centred
audio.setListener(x, y, z);   // the camera, every frame
audio.setEngine(id, speed);   // every tick a car is driven (blocks/tick); stops when calls stop
audio.volume; audio.muted; audio.toggleMute();
```

Cues are fixed: `pistol machine_gun shotgun rocket_launch explosion bullet_hit ped_hurt ped_death car_crash car_door pickup weapon_switch horn engine`. Each plays the samples the player mapped to it (one picked at random), else a short procedural sound, so the game is never silent. Sounds pan by x offset from the listener and fade with distance (full inside 3 blocks, silent past 24). The engine is one looping source per id whose playback rate goes from `idleRate` at rest to `topRate` at `topSpeed`.

The game screen already feeds the listener, the player's engine, door, crash and horn (special button in a car). Weapons, hits, deaths and pickups are for the sim events to call.

**Banks.** The player's `data/audio/<map>.sdt` + `.raw` (the map's base name: `wil.gmp` uses `wil.sdt`; a map without one borrows another, the shipped map banks share a layout) and `fstyle.sdt` + `.raw`, read from the OPFS cache. Layout, read off the player's own files: `.sdt` is 24-byte little-endian entries with no header, `u32 offset, u32 size, u32 rate, i32 unknown, i32 loopStart (bytes), i32 loopEnd (-1)`, contiguous in the `.raw`. Samples are mono PCM, mostly 16-bit signed, with 8-bit unsigned mixed in (no flag; `guessFormat` tells from the bytes, and on the shipped banks it picks exactly the 5500 Hz block). Banks under 8000 Hz are upsampled for browsers that refuse slower buffers. Import checks the entry table and the shell's file list flags a missing or short `.raw`.

**Sound board** (B, or the Sound button; M mutes). Lists every sample in both banks with a play button and its rate, length and encoding (click the encoding to flip it if a sample plays as noise). Pick a cue, step through samples with ↑/↓ (each one plays) and press Enter or Assign. Per-cue gain and the engine pitch range are on the cue list. The mapping is saved in `localStorage` (`gta2.sound.v1`) and exports or imports as JSON; that file holds indices only, never audio.
