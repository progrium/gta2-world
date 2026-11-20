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
| `src/ui/` | Import screen, game screen (real map, sim and renderer, HUD), controls (remap) overlay, handling tuning panel. |

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

The player picks their GTA2 folder (File System Access where available, else a `webkitdirectory` input), picks files, or drops a folder. A module worker hashes each `.gmp .sty .scr .mmp .gxt .sdt .raw`, checks `.gmp`/`.sty` headers and chunk tables, parses `.mmp` map descriptors, and writes the bytes to OPFS under `gta2/blobs/<sha256>` with a manifest. Nothing is uploaded. `AssetStore.find(name)` and `AssetStore.read(hash)` are the API for the renderer and sim; reads re-check the hash.

Maps on offer come from `.mmp` files whose `.gmp` and `.sty` are present; without any `.mmp`, same-named `.gmp`/`.sty` pairs. With cached assets, the page opens straight into the last map.
