# client/wasm

The browser's Zig module, `game.wasm`. It links `sim/` (dm16), `formats/`, `net/` (prediction client) and the renderer's Zig side (`client/render/src`) and exports a flat C ABI that `client/shell/src/game/wasm.ts` wraps.

```sh
zig build test                        # native: join, walk, render list, tuning round trip
zig build -Doptimize=ReleaseSmall     # zig-out/web/game.wasm (about 60 KB)
../build-web.sh [out]                 # the whole playable client as static files
```

| Exports | What |
| --- | --- |
| `alloc`, `free`, `errorPtr`, `errorLen` | Memory for files copied in; last error text. |
| `loadStyle`, `styleInfo`, `tiles*`, `spritePages*`, `ppal*`, `palxPtr`, `spriteTable*` | Parse a `.sty` and expose what the renderer uploads (same layout as the renderer demo). |
| `loadMap`, `vertex*`, `chunk*`, `anim*`, `meshInfo` | Parse a `.gmp`: chunked mesh with lights, tile animations, and the I1 collision grid for the sim. |
| `loadTestMap` | The sim's synthetic test map, no game files. |
| `gameStart(seed, hint, x, y)`, `gameJoin`, `gameLeave` | Start a session (ambient cars and peds spawn) and join slot 0; more local slots by command. |
| `framesPtr`, `gameStep`, `gameTick`, `gameHash` | Write 16 I2 frames, step one tick. |
| `playerInfo(slot)` | active, in car, hp, kills, deaths, respawn timer, speed, z. |
| `buildList(alpha)`, `instancePtr`, `cameraTarget(alpha, slot)` | Render list and camera target interpolated between the last two ticks. |
| `gameSpawnCar(slot)` | Drops a car in front of the player (offline tuning aid). |
| `layoutHashPtr`, `netStart(slot, buffer_ticks)`, `netStop`, `netSnapshot(body, now)`, `netUpdate(now)`, `netInput(now)`, `netInputPtr`, `netStats` | Online mode: net/'s client predicts in `.predict` mode against server snapshots; JavaScript owns the transport. `buildList`, `cameraTarget` and `playerInfo` then read the predicted, smoothed state. |
| `tuneNames*`, `tuneGet`, `tuneSet`, `tuneReset` | The placeholder handling numbers in `sim/tuning.zig`, live. |

Offline, the sim runs in `.authoritative` mode and the browser is the authority. Online (`netStart`), it predicts. Tuning changes numbers that are not part of the state, so it is for offline play only; a networked client must leave the defaults, or it will mispredict.
