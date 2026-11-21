# Tester site

Static pages for the spikes that need a person to try them, deployed to GitHub Pages by `.github/workflows/pages.yml` on every push to `main` that touches `site/`.

Each spike page is a copy of that spike's web page with two additions: a `window.TESTER` config near the end of the page, and `assets/tester.js`, which adds the "Tester guide" drawer (steps, a short form, and a Download results button that saves a JSON file) and a Submit on GitHub link that opens the matching issue form in `.github/ISSUE_TEMPLATE/` (labels `results` and the spike id). Answers and recorded runs are kept in the tester's `localStorage`.

| Page | Copied from | Notes |
| --- | --- | --- |
| `play/` | `client/build-web.sh site/play` on the integration branch | The M1 playable client: shell, `game.wasm` (sim, formats, renderer) and the handling tuning panel. Reads the player's own files. Tuning goes back through a prefilled GitHub issue (label `tuning`). |
| `s1/` | `spike/s1` @ 88d0abd, `spikes/s1` `zig build` output (`zig-out/web`, Zig 0.17.0) | `fixtures/` is the synthetic showcase, not game data. The page records every load and benchmark. |
| `s2/` | `spike/s2` @ cd14a18, `spikes/s2/web` | Unchanged apart from the guide. |
| `s3/` | `spike/s3` @ 97e961e, `spikes/s3/s3.html` | Patched to keep trials in `localStorage` and record the remote-car setting per trial. |
| `s4/` | placeholder | Needs a live server. |
| `s5/` | `s5.wasm` from `client/bench` (`zig build -Doptimize=ReleaseSmall`, Zig 0.17.0) on `claude/project-thread-awfjzy` | Handling is sim/'s, from `docs/behaviour/car-handling.md`, with car numbers from the tester's own `.gci` and style car info. Ratings carry a `build` tag (`notes-1`); ratings from the withdrawn build show as "old build" and do not count. The `data-wasm` attribute on `<html>` versions the module URL. |
| `s6/` | `spike/s6` @ b4701dd, `spikes/s6-gamepad/index.html` | Unchanged apart from the guide; the page's own Download JSON is the results file. |

No original game data goes in this folder. Pages that need it (S1, S5) read the tester's own files in the browser.

Preview locally with `python3 -m http.server -d site 8000`.
