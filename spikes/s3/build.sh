#!/bin/sh
# Builds sim.wasm with Zig 0.17.0 and a single self-contained s3.html
# (wasm inlined as base64, so it opens straight from disk).
set -e
cd "$(dirname "$0")"
zig build-exe sim.zig -target wasm32-freestanding -fno-entry -rdynamic -O ReleaseSmall -femit-bin=sim.wasm
node -e '
const fs = require("fs");
const b64 = fs.readFileSync("sim.wasm").toString("base64");
const bundle = "const SIM_WASM_B64 = \"" + b64 + "\";\n" + fs.readFileSync("net.js", "utf8") + "\n" + fs.readFileSync("main.js", "utf8");
const html = fs.readFileSync("index.html", "utf8").replace("/*BUNDLE*/", () => bundle);
fs.writeFileSync("s3.html", html);
console.log("wrote s3.html", html.length, "bytes");
'
# Same page without the document skeleton, for publishing as a claude.ai artifact.
node -e '
const fs = require("fs");
const h = fs.readFileSync("s3.html", "utf8");
const head = h.match(/<head>([\s\S]*?)<\/head>/)[1].replace(/<meta[^>]*>\n?/g, "");
const body = h.match(/<body>([\s\S]*)<\/body>/)[1];
fs.writeFileSync("s3-artifact.html", head + body);
'
