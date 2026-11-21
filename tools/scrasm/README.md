# scrasm

Workstream A1's script tool. Native only; `zig build -Doptimize=ReleaseFast`.

- `scrasm asm in.sasm outdir/` writes `main.scr` and one `<mission>.scr` per mission from the text form in `formats/scr.zig` (the sim's tests use the same assembler in-process, so CI never needs game data). The `.scr` outputs are ignored by git.
- `scrasm dis file.scr [--mission]` prints a script as that text.
- `scrasm coverage --data <dir> [--out file.md] [--ticks N]` reads every level script in the player's own data, lists each command type the scripts use with its count and handler (A1, A2 done or stubbed, or none), and runs each level's script in the sim on the synthetic test map. `results/coverage.md` is the last run on the player's files: type numbers and counts only.
