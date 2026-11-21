// Spike S3 browser page. Concatenated after net.js by build.sh, so the
// net.js names (Sandbox, instantiate, DEFAULTS, TICK_MS) are in scope.

const sim = instantiate(Uint8Array.from(atob(SIM_WASM_B64), (c) => c.charCodeAt(0)));
// F (fixed-point one) comes from net.js
const ARENA_W = sim.arenaW() / F, ARENA_H = sim.arenaH() / F;
const PILLARS = [];
for (let i = 0; i < sim.pillarCount(); i++) PILLARS.push({ x: sim.pillarX(i) / F, y: sim.pillarY(i) / F });
const PILLAR_R = sim.pillarR() / F;

const $ = (id) => document.getElementById(id);
const canvas = $("view");
const ctx = canvas.getContext("2d");

const opts = { ...DEFAULTS };
let sb = new Sandbox(sim, opts, performance.now(), (Math.random() * 1e9) | 0);
let skids = [];
let debug = false;

// ---- A/B toggle: A and B map to networked/local at random per page load
let abNetIsA = Math.random() < 0.5;
let abShowing = "A";
function applyAB() {
  sb.setLocalActive(abShowing === "A" ? !abNetIsA : abNetIsA);
  $("abLabel").textContent = abShowing;
}

// ---- blind trials
const trials = [];
let trial = null; // { local: bool }
function startTrial() {
  sb = new Sandbox(sim, opts, performance.now(), (Math.random() * 1e9) | 0);
  skids = [];
  trial = { local: Math.random() < 0.5, settings: describeSettings() };
  sb.setLocalActive(trial.local);
  setDebug(false);
  $("guess").hidden = false;
  $("startTrial").hidden = true;
  $("trialMsg").textContent = `Trial ${trials.length + 1}: drive for a while, then guess.`;
  $("abRow").hidden = true;
  canvas.focus();
}
function guess(saysLocal) {
  if (!trial) return;
  const correct = saysLocal === trial.local;
  trials.push({ ...trial, correct });
  $("trialMsg").textContent = `That was ${trial.local ? "zero latency" : "networked (" + trial.settings + ")"}. You were ${correct ? "right" : "wrong"}.`;
  trial = null;
  $("guess").hidden = true;
  $("startTrial").hidden = false;
  $("startTrial").textContent = "Next trial";
  $("abRow").hidden = false;
  renderTally();
  applyAB();
}
function binomTail(n, k) {
  // P(X >= k) for X ~ Bin(n, 0.5)
  let p = 0, c = 1;
  for (let i = 0; i <= n; i++) {
    if (i > 0) c = (c * (n - i + 1)) / i;
    if (i >= k) p += c;
  }
  return p / Math.pow(2, n);
}
function renderTally() {
  const n = trials.length, k = trials.filter((t) => t.correct).length;
  if (!n) return;
  const p = binomTail(n, k);
  let verdict = "";
  if (n >= 10) verdict = p < 0.05 ? " You can tell them apart: FAIL." : " Not distinguishable from chance: PASS.";
  $("tally").textContent = `${k}/${n} correct, chance of doing this well by guessing p=${p.toFixed(3)}.${verdict}`;
}
function describeSettings() {
  return `${opts.rttMs} ms RTT, ±${opts.jitterMs} ms jitter, ${opts.lossPct}% loss, smooth ${opts.smoothMs} ms`;
}

// ---- controls panel
const sliders = [
  ["rttMs", "Round trip", "ms", 0, 400, 10],
  ["jitterMs", "Jitter ±", "ms", 0, 80, 1],
  ["lossPct", "Loss", "%", 0, 20, 0.5],
  ["smoothMs", "Error smoothing", "ms", 0, 400, 10],
  ["bufferTicks", "Server input buffer", "ticks", 0, 6, 1],
  ["interpMs", "Remote interp delay", "ms", 0, 300, 10],
];
for (const [key, label, unit, min, max, step] of sliders) {
  const row = document.createElement("label");
  row.className = "row";
  row.innerHTML = `<span>${label}</span><input type="range" min="${min}" max="${max}" step="${step}" value="${opts[key]}"><b></b>`;
  const input = row.querySelector("input"), out = row.querySelector("b");
  const show = () => (out.textContent = `${opts[key]} ${unit}`);
  input.addEventListener("input", () => {
    opts[key] = Number(input.value);
    sb.setOpts({ [key]: opts[key] });
    show();
  });
  show();
  $("sliders").appendChild(row);
}
$("bot").addEventListener("change", (e) => {
  opts.botMode = e.target.value;
  sb.setOpts({ botMode: opts.botMode });
});
$("remoteView").addEventListener("change", (e) => {
  opts.remoteView = e.target.value;
  sb.setOpts({ remoteView: opts.remoteView });
});
$("startTrial").onclick = startTrial;
$("saysLocal").onclick = () => guess(true);
$("saysNet").onclick = () => guess(false);
$("reveal").onclick = () => {
  $("abReveal").textContent = `A = ${abNetIsA ? "networked" : "zero latency"}, B = ${abNetIsA ? "zero latency" : "networked"}. Shuffled again.`;
  abNetIsA = Math.random() < 0.5;
  applyAB();
};
$("debug").addEventListener("change", (e) => setDebug(e.target.checked));
function setDebug(on) {
  debug = on && !trial;
  $("debug").checked = debug;
  $("debug").disabled = !!trial;
  $("stats").hidden = !debug;
}

// ---- input
const keys = new Set();
addEventListener("keydown", (e) => {
  if (e.target.tagName === "INPUT" && e.target.type !== "range") return;
  keys.add(e.code);
  if (e.code === "Tab") {
    e.preventDefault();
    if (!trial) {
      abShowing = abShowing === "A" ? "B" : "A";
      applyAB();
    }
  }
  if (e.code === "KeyR" && !trial) {
    sb = new Sandbox(sim, opts, performance.now(), (Math.random() * 1e9) | 0);
    skids = [];
    applyAB();
  }
  if (e.code === "KeyH") $("panel").hidden = !$("panel").hidden;
  if (e.code === "KeyG") setDebug(!debug);
  if (["Space", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"].includes(e.code)) e.preventDefault();
});
addEventListener("keyup", (e) => keys.delete(e.code));
addEventListener("blur", () => keys.clear());

function sampleInput() {
  let steer = 0, throttle = 0, buttons = 0;
  if (keys.has("ArrowLeft") || keys.has("KeyA")) steer -= 127;
  if (keys.has("ArrowRight") || keys.has("KeyD")) steer += 127;
  if (keys.has("ArrowUp") || keys.has("KeyW")) throttle += 127;
  if (keys.has("ArrowDown") || keys.has("KeyS")) throttle -= 127;
  if (keys.has("Space")) buttons |= 1;
  for (const gp of navigator.getGamepads ? navigator.getGamepads() : []) {
    if (!gp) continue;
    const ax = gp.axes[0] || 0;
    if (Math.abs(ax) > 0.15) steer = Math.round(ax * 127);
    const rt = gp.buttons[7] ? gp.buttons[7].value : 0;
    const lt = gp.buttons[6] ? gp.buttons[6].value : 0;
    if (rt > 0.05 || lt > 0.05) throttle = Math.round((rt - lt) * 127);
    if (gp.buttons[0] && gp.buttons[0].pressed) buttons |= 1;
    if (gp.buttons[1] && gp.buttons[1].pressed) buttons |= 1;
  }
  return { steer, throttle, buttons };
}

// ---- drawing
function resize() {
  const dpr = devicePixelRatio || 1;
  canvas.width = innerWidth * dpr;
  canvas.height = innerHeight * dpr;
}
addEventListener("resize", resize);
resize();

function drawCar(p, body, outline) {
  ctx.save();
  ctx.translate(p.x, p.y);
  ctx.rotate(p.h);
  if (outline) {
    ctx.strokeStyle = body;
    ctx.lineWidth = 2;
    ctx.strokeRect(-20, -10, 40, 20);
  } else {
    ctx.fillStyle = "rgba(0,0,0,0.35)";
    ctx.fillRect(-18, -8, 40, 20);
    ctx.fillStyle = body;
    ctx.fillRect(-20, -10, 40, 20);
    ctx.fillStyle = "#1c2a36";
    ctx.fillRect(4, -8, 8, 16); // windscreen
    ctx.fillRect(-14, -8, 5, 16); // rear window
    ctx.fillStyle = "#ffe9a8";
    ctx.fillRect(18, -9, 2, 4);
    ctx.fillRect(18, 5, 2, 4);
  }
  ctx.restore();
}

function addSkid(p, slip, hb) {
  if (slip < 2.2 && !hb) {
    skids.push(null);
    return;
  }
  const c = Math.cos(p.h), s = Math.sin(p.h);
  const rx = p.x - c * 14, ry = p.y - s * 14;
  skids.push([rx - s * 8, ry + c * 8, rx + s * 8, ry - c * 8]);
  if (skids.length > 4000) skids.splice(0, 500);
}

function draw(out, now) {
  const W = canvas.width, H = canvas.height;
  const scale = Math.min(W, H) / 650;
  const cam = out.shown.own;
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.fillStyle = "#2b2d2f";
  ctx.fillRect(0, 0, W, H);
  ctx.setTransform(scale, 0, 0, scale, W / 2 - cam.x * scale, H / 2 - cam.y * scale);

  // tarmac with tile grid, like a top-down city block
  ctx.fillStyle = "#55585b";
  ctx.fillRect(0, 0, ARENA_W, ARENA_H);
  ctx.strokeStyle = "rgba(255,255,255,0.06)";
  ctx.lineWidth = 1;
  ctx.beginPath();
  for (let x = 0; x <= ARENA_W; x += 64) (ctx.moveTo(x, 0), ctx.lineTo(x, ARENA_H));
  for (let y = 0; y <= ARENA_H; y += 64) (ctx.moveTo(0, y), ctx.lineTo(ARENA_W, y));
  ctx.stroke();
  ctx.strokeStyle = "rgba(240,210,90,0.55)";
  ctx.lineWidth = 4;
  ctx.setLineDash([30, 30]);
  ctx.beginPath();
  ctx.moveTo(0, ARENA_H / 2);
  ctx.lineTo(ARENA_W, ARENA_H / 2);
  ctx.moveTo(ARENA_W / 2, 0);
  ctx.lineTo(ARENA_W / 2, ARENA_H);
  ctx.stroke();
  ctx.setLineDash([]);
  ctx.strokeStyle = "#c9c9c9";
  ctx.lineWidth = 12;
  ctx.strokeRect(-6, -6, ARENA_W + 12, ARENA_H + 12);

  // skids
  ctx.strokeStyle = "rgba(20,20,20,0.55)";
  ctx.lineWidth = 3;
  ctx.beginPath();
  for (let i = 1; i < skids.length; i++) {
    const a = skids[i - 1], b = skids[i];
    if (!a || !b) continue;
    ctx.moveTo(a[0], a[1]);
    ctx.lineTo(b[0], b[1]);
    ctx.moveTo(a[2], a[3]);
    ctx.lineTo(b[2], b[3]);
  }
  ctx.stroke();

  for (const p of PILLARS) {
    ctx.fillStyle = "#3a3c3e";
    ctx.beginPath();
    ctx.arc(p.x, p.y, PILLAR_R, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = "#8a8d90";
    ctx.lineWidth = 3;
    ctx.stroke();
  }

  if (opts.botMode !== "off") drawCar(out.shown.bot, "#3a7bd5");
  drawCar(out.shown.own, "#d23b2f");

  if (debug) {
    if (out.net.ghost) drawCar(out.net.ghost, "rgba(80,255,120,0.9)", true);
    const raw = sb.client.renderPoseRaw(Math.max(0, sb.client.alpha()));
    drawCar(raw, "rgba(255,255,0,0.9)", true);
  }
}

// rolling stats for the debug panel
const errWindow = [];
function updateStats(now) {
  const c = sb.client, s = c.stats;
  const recent = s.errs.filter((e) => e.t > now - 5000);
  const maxE = recent.reduce((m, e) => Math.max(m, e.e), 0);
  const lead = sim.tick(1) - sim.tick(0);
  $("stats").textContent =
    `showing: ${sb.localActive ? "zero latency" : "networked"}\n` +
    `client lead: ${lead} ticks, server slack: ${c.slack}\n` +
    `replay depth: ${c.lastReplay ?? 0} ticks\n` +
    `corrections (5 s): ${recent.length}, max error ${maxE.toFixed(1)} u\n` +
    `smoothing offset: ${Math.hypot(c.offset.x, c.offset.y).toFixed(2)} u\n` +
    `server repeated inputs: ${sb.server.missing}\n` +
    `packets lost up/down: ${sb.up.dropped}/${sb.down.dropped}\n` +
    `hard clock resyncs: ${s.hardResyncs}\n` +
    `green = latest server state, yellow = unsmoothed prediction`;
}

let lastStats = 0;
function loop(now) {
  const input = sampleInput();
  const out = sb.frame(now, input);
  addSkid(out.shown.own, sb.slip(), input.buttons & 1);
  draw(out, now);
  if (debug && now - lastStats > 200) {
    updateStats(now);
    lastStats = now;
  }
  requestAnimationFrame(loop);
}
applyAB();
setDebug(false);
requestAnimationFrame(loop);
