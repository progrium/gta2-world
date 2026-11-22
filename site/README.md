# Site

The front page (`index.html`) sets a player up for the play page: game files, then hosting or joining a game, then playing alone, with smaller links to the pages where people can help (sound cues and the remaining spike tests). Static pages, deployed to GitHub Pages by `.github/workflows/pages.yml` on every push to `main` that touches `site/`.

Each spike test page is a copy of that spike's web page with two additions: a `window.TESTER` config near the end of the page, and `assets/tester.js`, which adds the "Tester guide" drawer (steps, a short form, and a Download results button that saves a JSON file) and a Submit on GitHub link that opens the matching issue form in `.github/ISSUE_TEMPLATE/` (labels `results` and the spike id). Answers and recorded runs are kept in the tester's `localStorage`.

| Page | Copied from | Notes |
| --- | --- | --- |
| `play/` | `client/build-web.sh site/play` on the integration branch | The playable client: shell, `game.wasm` (sim, formats, renderer), the browser host and the handling tuning panel. Reads the player's own files. Tuning goes back through a prefilled GitHub issue (label `tuning`). The front page links to `play/#files` (game files and maps), `play/#host` (host a game) and `play/#sounds` (the sound cue board on its own; mappings come back through the `sound-mapping` issue form). |
| `s2/` | `spike/s2` @ cd14a18, `spikes/s2/web` | Unchanged apart from the guide. |
| `s5/` | `s5.wasm` from `client/bench` (`zig build -Doptimize=ReleaseSmall`, Zig 0.17.0) on `claude/project-thread-awfjzy` | Handling is sim/'s, from `docs/behaviour/car-handling.md`, with car numbers from the tester's own `.gci` and style car info. Ratings carry a `build` tag (`notes-1`); ratings from the withdrawn build show as "old build" and do not count. The `data-wasm` attribute on `<html>` versions the module URL. |
| `s6/` | `spike/s6` @ b4701dd, `spikes/s6-gamepad/index.html` | Unchanged apart from the guide; the page's own Download JSON is the results file. |

No original game data goes in this folder. Pages that need it (play, S5) read the tester's own files in the browser.

Preview locally with `python3 -m http.server -d site 8000`.
