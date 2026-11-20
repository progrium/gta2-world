# Spike S1: parse and draw a map

Zig parsers for `.gmp` and `.sty` (in `../../formats/`), compiled to WASM, plus a throwaway WebGL2 viewer with a free camera. The result and the steps to check it on real data are in [RESULT.md](RESULT.md).

```sh
zig build test       # Zig 0.17.0
zig build            # zig-out/bin/s1, zig-out/web/{index.html,viewer.js,s1.wasm,fixtures/}
python3 -m http.server -d zig-out/web 8000
# open http://localhost:8000/?demo for the synthetic showcase
./zig-out/bin/s1 inspect path/to/file.gmp path/to/file.sty
```

Layout:

- `src/mesh.zig` builds a map into triangles (12-byte vertices, 64 units per block).
- `src/atlas.zig` builds the tile index atlas and the per-tile palette rows.
- `src/wasm.zig` holds the WASM exports used by `web/viewer.js`.
- `src/showcase.zig` generates the synthetic demo map and style. They contain no original data.
- `src/main.zig` is the native `s1 inspect` and `s1 fixtures` tool.

No original game data belongs in this repo. The `.gitignore` here and in `formats/` blocks `.gmp`, `.sty` and `.scr` files.
