# client/bench: the S5 handling bench

`s5.wasm` for the tester page in `site/s5/`. It runs one player-driven car
in sim/ (`sim.Sim` with a one-player config) on the synthetic test map
(`sim.testmap`), with handling exactly as the game uses it: `sysCarControl`
from `docs/behaviour/car-handling.md`, per-model numbers from the tester's
own `.gci` and style car info through `formats.gci`, `formats.sty` and
`sim.tuning.deriveModel`. The bench adds no car physics of its own.

    zig build -Doptimize=ReleaseSmall   zig-out/web/s5.wasm
    zig build test                      native tests; prints the self-test hash

To update the page: build, copy `zig-out/web/s5.wasm` to `site/s5/`, set
`data-wasm` on the page's `<html>` to the first 10 hex digits of its
sha256, and if `zig build test` prints a new self-test hash, set
`SELF_TEST` in the page (and the chip's title) to it. When the handling
changes enough that old ratings should stop counting, bump `BUILD` in the
page.

Skid marks on the page are a visual cue of our own (a wheel's sideways
slip over 0.04 blocks a tick) until the skid-mark behaviour note exists.
