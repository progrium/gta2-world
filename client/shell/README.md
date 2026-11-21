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
npm test        # node --test on the pure parts (input, assets, loop, lobby, signalling)
npm run test:e2e  # Playwright: two tabs, host + join over WebRTC (fake host Worker)
npm run build   # dist/main.js + dist/worker.js
npm run dev     # rebuild on change and serve on http://localhost:8000
```

Serve the folder over `localhost` or https: gamepads and OPFS need a secure context.

## What's here

| Path | What it does |
| --- | --- |
| `src/input/` | Keyboard, gamepad and the on-screen touch pad to I2 frames (`interfaces/I2-input-frame.md`). |
| `src/assets/` | Folder pick, drag-drop, worker hashing and checks, OPFS cache keyed by SHA-256. |
| `src/loop.ts` | rAF-driven fixed 30 Hz clock: poll every frame, latch every tick, render with alpha. |
| `src/session.ts` | Fixed session id `m1-local`, or `#s=<id>` from the link. |
| `src/game/wasm.ts` | Loads `game.wasm`; copies files in, hands buffers to the renderer, steps the sim, reads player info and tuning. |
| `src/audio/` | Sound banks (.sdt/.raw), WebAudio engine, the cue list and mapping, procedural fallbacks. |
| `src/assets/installer.ts` | "Download from the Internet Archive": streams the GTA2 freeware installer from archive.org into the browser and unpacks the data files from its InstallShield cabinets. |
| `src/ui/` | Import screen, game screen (real map, sim and renderer, HUD), controls (remap) overlay, handling tuning panel, sound board, host and join screens. |
| `src/net/` | I3 `Connection` (WebTransport, WebSocket, WebRTC, loopback), WebRTC peer (`rtc.ts`), signalling (`signal.ts` contract, `signal-bc.ts`, `signaller.ts` factory). |
| `src/host/` | Browser host: `hostPeers.ts` (Worker, peers, loopback), `hostSession.ts` (one hosted game), `protocol.ts` (Worker contract). |
| `src/lobby/` | File channel `f`: format and chunking (`files.ts`), host and joiner sides (`lobby.ts`), asset store glue (`assets.ts`). |

## Browser-hosted games

"Host a game…" on the import screen runs the session in the tab: `HostPeers` starts the host Worker (`dist/host-worker.js`, or `?hostWorker=<same-origin path>`) on the map's `.gmp`, opens a signalling room and shows the link `#join/<room>.<maphash12>`. Opening that link shows the join screen.

- **Signalling**: BroadcastChannel by default (tabs of one browser). `?signal=wss://…` or `SIGNAL_URL` in `net/signaller.ts` selects a WebSocket signaller registered with `registerSignaller("ws", …)`; `?signal=bc` forces BroadcastChannel.
- **Peer connection**: the joiner creates channels `s` (ordered, reliable), `d` (`ordered: false, maxRetransmits: 0`) and `f` (ordered, reliable), makes the offer and trickles ICE; the host answers. One channel message is one I3 message. Datagrams over min(1100, SCTP max message size), or sent while `d` has over 64 KB queued, are dropped.
- **Worker routing**: peers get ids from 1. `opened` (transport 2) goes to the Worker right before the peer's first stream message (its hello), so time spent in the lobby doesn't count. `s` closing, ICE `failed`, or `disconnected` for 5 s sends `closed`. Worker `close` flushes `s`, then closes the peer connection (and `closed` follows, as with the native transports).
- **Loopback**: the host's own player uses `Connection` with transport `"loopback"`: `sendStream`/`sendDatagram` post straight to the Worker as another peer id; the Worker's replies for that id are handed back in-page. hello.transport is 2, since the loopback is part of the WebRTC host.
- **Lobby (`f`)**: the joiner sends `{t:"want", map}`; the host answers `{t:"match", description, share, files}` with the `.gmp` and `.sty` (name, kind, size, sha256). The joiner asks `{t:"get", files:[sha256…]}` for what its store lacks. With sharing on, each file is a `{t:"file", id, name, kind, size, sha256}` header, binary chunks (u32 id + up to 16 KB) and `{t:"end", id}`, at most 2 transfers at a time on the host; the joiner checks size and SHA-256 and imports the file under `shared/` in the asset store. With sharing off the host answers `{t:"refused", names}` and the joiner names the missing files. `{t:"ready"}` ends the lobby; nothing more is sent on `f`.

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
- Touch pad (`src/input/touch.ts`, overlay `src/ui/touchPad.ts`): the "Touch pad" button on the game screen shows a floating move stick (left half of the view) and Fire, Jump, Car (enter/exit) and weapon buttons. It feeds slot 0 like the keyboard. On foot the auto scheme is direct; in a car the stick x steers and its y is the pedal (up accelerates, down brakes). The setting is kept in localStorage and defaults on for touch screens (`pointer: coarse`).
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

**Spoken lines.** `data/audio/Vocals/*.wav` (RIFF WAVE, IMA ADPCM or PCM, mono or stereo) load as a third bank, `vocals`, decoded in `audio/wav.ts` and mixed to mono. Mappings name these by file (`{ bank: "vocals", name: "wasted" }`), since the files have no fixed order. Spoken cues (the announcer and pedestrian voices) stay silent until mapped rather than play a built-in stand-in.

**Sound board** (B, or the Sound button; M mutes). Lists every sample in both banks with a play button and its rate, length and encoding (click the encoding to flip it if a sample plays as noise). Pick a cue, step through samples with ↑/↓ (each one plays) and press Enter or Assign. Per-cue gain and the engine pitch range are on the cue list. The mapping is saved in `localStorage` (`gta2.sound.v1`) and exports or imports as JSON; that file holds indices only, never audio.

## Internet Archive download

The import screen can fetch Rockstar's freeware release of GTA2 from the Internet Archive item [`gta2_rockstar-classics`](https://archive.org/details/gta2_rockstar-classics) (`GTA2INSTALLER.exe`, 362,331,961 bytes). The browser fetches it from `https://archive.org/cors/<item>/<file>`, archive.org's CORS endpoint, so the bytes go straight from the Internet Archive to the player and never through our servers. The plain `/download/` URL redirects to an item server that sends no CORS headers, so it can't be read from a page.

The installer is a PE stub followed by entries of `name\0 path\0 version\0 decimal-size\0` and then the bytes. Among them are an InstallShield 7 cabinet set: `data1.hdr` (the file table), `data1.cab` and `data2.cab` (the volumes). `InstallerReader` takes the download in order, keeps only the stored bytes of the files under `data/` that the shell imports, and expands them (compressed files are chunks of a u16 length and raw deflate, read with `DecompressionStream("deflate-raw")`). The music in `data/GTAudio` (about 290 MB) is skipped because nothing plays it yet. What's left, 271 files and about 57 MB, goes through the same import as a picked folder.

