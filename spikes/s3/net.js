// Spike S3 netcode: an in-page fake network between a server sim and a
// client sim, with client-side rewind-and-replay prediction and error
// smoothing. No DOM here so the same file runs in the browser and in Node.

export const TICK_MS = 1000 / 30;
const SNAP_EVERY = 1.5; // 30 Hz sim, 20 Hz snapshots
const REDUNDANT_FRAMES = 8;
export const F = 65536;

export function instantiate(bytes) {
  const mod = new WebAssembly.Module(bytes);
  return new WebAssembly.Instance(mod, {}).exports;
}

// Small deterministic PRNG so headless runs are repeatable.
export function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function hash32(n) {
  n = Math.imul(n ^ (n >>> 16), 0x45d9f3b);
  n = Math.imul(n ^ (n >>> 16), 0x45d9f3b);
  return (n ^ (n >>> 16)) >>> 0;
}

function wrapAngle(a) {
  while (a > Math.PI) a -= 2 * Math.PI;
  while (a < -Math.PI) a += 2 * Math.PI;
  return a;
}

// Fake one-way link: latency, uniform jitter (which also reorders), loss.
export class Link {
  constructor(rng) {
    this.rng = rng;
    this.q = [];
    this.oneWay = 75;
    this.jitter = 0;
    this.loss = 0;
    this.sent = 0;
    this.dropped = 0;
  }
  send(now, msg) {
    this.sent++;
    if (this.rng() < this.loss) {
      this.dropped++;
      return;
    }
    const d = Math.max(0, this.oneWay + (this.rng() * 2 - 1) * this.jitter);
    this.q.push({ t: now + d, msg });
  }
  poll(now) {
    const out = [];
    const keep = [];
    for (const e of this.q) (e.t <= now ? out : keep).push(e);
    this.q = keep;
    out.sort((a, b) => a.t - b.t);
    return out.map((e) => e.msg);
  }
}

// Server-side bot driver. Stands in for another player: the client cannot
// know its next input, which is what makes bumping into it mispredict.
export function botInput(sim, slot, mode) {
  if (mode === "off") return [0, 0, 0];
  const t = sim.tick(slot);
  const bx = sim.carX(slot, 1) / F, by = sim.carY(slot, 1) / F;
  const bh = (sim.carH(slot, 1) / 65536) * 2 * Math.PI;
  let tx, ty;
  if (mode === "chase") {
    tx = sim.carX(slot, 0) / F;
    ty = sim.carY(slot, 0) / F;
  } else {
    const r = hash32((t >> 6) + 1);
    tx = 200 + (r % 2000);
    ty = 200 + ((r >>> 11) % 1200);
  }
  const diff = wrapAngle(Math.atan2(ty - by, tx - bx) - bh);
  const steer = Math.max(-127, Math.min(127, Math.round(diff * 160)));
  const throttle = Math.abs(diff) > 2 ? 50 : mode === "chase" ? 127 : 100;
  const vx = sim.carVX(slot, 1) / F, vy = sim.carVY(slot, 1) / F;
  const hb = mode === "chase" && Math.abs(diff) > 1.0 && Math.hypot(vx, vy) > 9 ? 1 : 0;
  return [steer, throttle, hb];
}

function stateView(sim, slot) {
  return new Uint8Array(sim.memory.buffer, sim.slotPtr(slot), sim.stateSize());
}

function pose(sim, slot, car) {
  return {
    x: sim.carX(slot, car) / F,
    y: sim.carY(slot, car) / F,
    h: (sim.carH(slot, car) / 65536) * 2 * Math.PI,
  };
}

function lerpPose(a, b, t) {
  return { x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, h: a.h + wrapAngle(b.h - a.h) * t };
}

class Server {
  constructor(sim, slot, up, down, opts, now) {
    Object.assign(this, { sim, slot, up, down, opts });
    this.t0 = now;
    this.n = 0;
    this.buf = new Map();
    this.last = { steer: 0, throttle: 0, buttons: 0 };
    this.slackSamples = []; // [time, slack]
    this.slack = 0;
    this.missing = 0;
    this.processed = 0;
  }
  update(now) {
    for (const m of this.up.poll(now)) this.onInput(now, m);
    while (now >= this.t0 + (this.n + 1) * TICK_MS) {
      this.n++;
      this.tickOnce(now);
    }
  }
  onInput(now, m) {
    const wt = this.sim.tick(this.slot);
    let newest = -1;
    for (const f of m.frames) {
      if (f.tick >= wt && !this.buf.has(f.tick)) this.buf.set(f.tick, f);
      newest = Math.max(newest, f.tick);
    }
    this.slackSamples.push([now, newest - wt]);
  }
  tickOnce(now) {
    const { sim, slot } = this;
    const wt = sim.tick(slot);
    const f = this.buf.get(wt);
    if (f) {
      this.last = f;
      this.buf.delete(wt);
    } else {
      this.missing++; // late or lost: repeat the previous frame
    }
    this.processed++;
    for (const k of this.buf.keys()) if (k < wt) this.buf.delete(k);
    sim.setInput(slot, 0, this.last.steer, this.last.throttle, this.last.buttons);
    const b = botInput(sim, slot, this.opts.botMode);
    sim.setInput(slot, 1, b[0], b[1], b[2]);
    sim.step(slot);
    const nt = wt + 1;
    if (Math.floor(nt / SNAP_EVERY) !== Math.floor(wt / SNAP_EVERY)) {
      // min arrival slack over the last second is what the client steers on
      this.slackSamples = this.slackSamples.filter((s) => s[0] > now - 1000);
      if (this.slackSamples.length) this.slack = Math.min(...this.slackSamples.map((s) => s[1]));
      this.down.send(now, { tick: nt, state: stateView(sim, slot).slice(), slack: this.slack });
    }
  }
}

class Client {
  constructor(sim, slot, up, down, opts, now) {
    Object.assign(this, { sim, slot, up, down, opts });
    this.lastT = now;
    this.acc = 0;
    this.interval = TICK_MS;
    this.inputs = new Map();
    this.ackTick = 0;
    this.snapTick = -1;
    this.slack = null;
    this.lastResync = -1e9;
    this.prev = pose(sim, slot, 0);
    this.cur = this.prev;
    this.prevBot = pose(sim, slot, 1);
    this.curBot = this.prevBot;
    this.offset = { x: 0, y: 0, h: 0 };
    this.botOffset = { x: 0, y: 0, h: 0 };
    this.snaps = []; // for remote (bot) interpolation
    this.srvOffset = null; // server tick minus local time in ticks
    this.stats = { corrections: 0, snaps: 0, replays: 0, replayTicks: 0, errs: [], hardResyncs: 0 };
    this.onTick = null;
  }
  doTick(input) {
    const { sim, slot } = this;
    const t = sim.tick(slot);
    this.inputs.set(t, input);
    this.prev = this.cur;
    this.prevBot = this.curBot;
    sim.setInput(slot, 0, input.steer, input.throttle, input.buttons);
    sim.step(slot);
    this.cur = pose(sim, slot, 0);
    this.curBot = pose(sim, slot, 1);
    const frames = [];
    for (let k = Math.max(this.ackTick, t - REDUNDANT_FRAMES + 1); k <= t; k++) {
      const f = this.inputs.get(k);
      if (f) frames.push({ tick: k, ...f });
    }
    this.up.send(this.now, { frames });
    if (this.onTick) this.onTick(t, input);
  }
  onSnapshot(now, s) {
    if (s.tick <= this.snapTick) return; // stale or reordered
    const { sim, slot } = this;
    this.snapTick = s.tick;
    this.ackTick = s.tick;
    this.slack = s.slack;
    this.stats.snaps++;
    // remote entity buffer + server clock estimate
    const view = new DataView(s.state.buffer);
    // World layout: tick u32, pad, cars[2] each 9 x i32 (x,y,vx,vy,heading,...)
    const base = 8 + 36;
    this.snaps.push({
      tick: s.tick,
      x: view.getInt32(base, true) / F,
      y: view.getInt32(base + 4, true) / F,
      h: (view.getInt32(base + 16, true) / 65536) * 2 * Math.PI,
      own: { x: view.getInt32(8, true) / F, y: view.getInt32(12, true) / F, h: (view.getInt32(24, true) / 65536) * 2 * Math.PI },
    });
    if (this.snaps.length > 40) this.snaps.shift();
    const sample = s.tick - now / TICK_MS;
    if (this.srvOffset === null || sample > this.srvOffset + 3) this.srvOffset = sample;
    else this.srvOffset += (sample - this.srvOffset) * 0.05;

    // rewind and replay
    const target = sim.tick(slot);
    const before = this.renderPoseRaw(this.alpha());
    const beforeBot = lerpPose(this.prevBot, this.curBot, Math.max(0, this.alpha()));
    stateView(sim, slot).set(s.state);
    let n = 0;
    let last = { steer: 0, throttle: 0, buttons: 0 };
    for (let t = s.tick; t < target; t++) {
      if (t === target - 1) {
        this.prev = pose(sim, slot, 0);
        this.prevBot = pose(sim, slot, 1);
      }
      const f = this.inputs.get(t) || last;
      last = f;
      sim.setInput(slot, 0, f.steer, f.throttle, f.buttons);
      sim.step(slot);
      n++;
    }
    if (n === 0) {
      this.prev = pose(sim, slot, 0);
      this.prevBot = pose(sim, slot, 1);
    }
    this.cur = pose(sim, slot, 0);
    this.curBot = pose(sim, slot, 1);
    {
      const ab = lerpPose(this.prevBot, this.curBot, Math.max(0, this.alpha()));
      const bx = beforeBot.x - ab.x, by = beforeBot.y - ab.y;
      if (Math.hypot(bx, by) > 200 || this.opts.smoothMs <= 0) this.botOffset = { x: 0, y: 0, h: 0 };
      else {
        this.botOffset.x += bx;
        this.botOffset.y += by;
        this.botOffset.h = wrapAngle(this.botOffset.h + wrapAngle(beforeBot.h - ab.h));
      }
    }
    for (const k of this.inputs.keys()) if (k < s.tick) this.inputs.delete(k);
    this.stats.replays++;
    this.stats.replayTicks += n;
    this.lastReplay = n;
    const after = this.renderPoseRaw(this.alpha());
    const ex = before.x - after.x, ey = before.y - after.y, eh = wrapAngle(before.h - after.h);
    const e = Math.hypot(ex, ey);
    if (e > 0.01 || Math.abs(eh) > 0.0005) {
      this.stats.corrections++;
      this.stats.errs.push({ t: now, e, eh });
      if (this.stats.errs.length > 2000) this.stats.errs.shift();
    }
    if (e > 200 || this.opts.smoothMs <= 0) {
      this.offset = { x: 0, y: 0, h: 0 }; // too big to hide, or smoothing off: snap
    } else {
      this.offset.x += ex;
      this.offset.y += ey;
      this.offset.h = wrapAngle(this.offset.h + eh);
    }
  }
  alpha() {
    return Math.min(1, this.acc / this.interval);
  }
  renderPoseRaw(a) {
    return lerpPose(this.prev, this.cur, a);
  }
  update(now, input) {
    this.now = now;
    for (const m of this.down.poll(now)) this.onSnapshot(now, m);
    const dt = now - this.lastT;
    this.lastT = now;
    // clock steering: keep min input slack at the server near the buffer target
    if (this.slack !== null) {
      const err = this.slack - this.opts.bufferTicks;
      if ((err < -3 || err > 6) && now - this.lastResync > 1500) {
        this.acc -= err * this.interval; // jump the clock; runs or stalls ticks below
        this.lastResync = now;
        this.stats.hardResyncs++;
      }
      const dil = Math.max(-0.08, Math.min(0.08, err * 0.015));
      this.interval = TICK_MS * (1 + dil);
    }
    this.acc += dt;
    let steps = 0;
    while (this.acc >= this.interval && steps < 20) {
      this.acc -= this.interval;
      this.doTick(input);
      steps++;
    }
    if (this.acc < -10 * this.interval) this.acc = -10 * this.interval;
    const k = this.opts.smoothMs > 0 ? Math.exp((-dt * 3) / this.opts.smoothMs) : 0;
    this.offset.x *= k;
    this.offset.y *= k;
    this.offset.h *= k;
    this.botOffset.x *= k;
    this.botOffset.y *= k;
    this.botOffset.h *= k;
    return steps;
  }
  ownPose() {
    const p = this.renderPoseRaw(Math.max(0, this.alpha()));
    return { x: p.x + this.offset.x, y: p.y + this.offset.y, h: p.h + this.offset.h };
  }
  // remote entity: interpolate between snapshots about interpMs in the past
  remoteRenderTick(now) {
    if (this.srvOffset === null) return null;
    return now / TICK_MS + this.srvOffset - this.opts.interpMs / TICK_MS;
  }
  remotePose(now) {
    const rt = this.remoteRenderTick(now);
    const s = this.snaps;
    if (rt === null || !s.length) return pose(this.sim, this.slot, 1);
    if (rt <= s[0].tick) return s[0];
    for (let i = s.length - 1; i > 0; i--) {
      if (s[i - 1].tick <= rt) {
        const a = s[i - 1], b = s[i];
        if (rt >= b.tick) return b;
        return lerpPose(a, b, (rt - a.tick) / (b.tick - a.tick));
      }
    }
    return s[s.length - 1];
  }
  // remote entity drawn from the predicted world instead: present time,
  // dead-reckoned on its last known input, corrections smoothed like ours
  predictedRemotePose() {
    const p = lerpPose(this.prevBot, this.curBot, Math.max(0, this.alpha()));
    return { x: p.x + this.botOffset.x, y: p.y + this.botOffset.y, h: p.h + this.botOffset.h };
  }
  serverGhost() {
    const s = this.snaps[this.snaps.length - 1];
    return s ? s.own : null;
  }
}

// Zero-latency reference: the same sim stepped on the same client ticks with
// the same inputs, no network, no corrections. While it is not on screen it
// is kept equal to the predicted world so a switch is seamless.
class Local {
  constructor(sim, slot, opts) {
    Object.assign(this, { sim, slot, opts });
    this.prev = pose(sim, slot, 0);
    this.cur = this.prev;
    this.prevBot = pose(sim, slot, 1);
    this.curBot = this.prevBot;
    this.botHist = new Map();
  }
  doTick(input) {
    const { sim, slot } = this;
    this.prev = this.cur;
    this.prevBot = this.curBot;
    sim.setInput(slot, 0, input.steer, input.throttle, input.buttons);
    const b = botInput(sim, slot, this.opts.botMode);
    sim.setInput(slot, 1, b[0], b[1], b[2]);
    sim.step(slot);
    this.cur = pose(sim, slot, 0);
    this.curBot = pose(sim, slot, 1);
    this.recordBot();
  }
  recordBot() {
    const t = this.sim.tick(this.slot);
    this.botHist.set(t, pose(this.sim, this.slot, 1));
    this.botHist.delete(t - 120);
  }
  // show the bot with the same delay the networked view has, so the only
  // difference between the two views is how the own car behaves
  botPose(tick) {
    const t0 = Math.floor(tick);
    const a = this.botHist.get(t0), b = this.botHist.get(t0 + 1);
    if (a && b) return lerpPose(a, b, tick - t0);
    return a || b || pose(this.sim, this.slot, 1);
  }
}

export const DEFAULTS = {
  rttMs: 150,
  jitterMs: 10,
  lossPct: 2,
  smoothMs: 100,
  bufferTicks: 2,
  interpMs: 100,
  botMode: "wander",
  remoteView: "interpolated", // or "predicted"
};

// Everything for one session: slots 0 server, 1 client, 2 local reference.
export class Sandbox {
  constructor(sim, opts, now, seed = 1) {
    this.sim = sim;
    this.opts = { ...DEFAULTS, ...opts };
    for (const s of [0, 1, 2]) sim.init(s);
    this.rng = mulberry32(seed);
    this.up = new Link(this.rng);
    this.down = new Link(this.rng);
    this.applyOpts();
    this.server = new Server(sim, 0, this.up, this.down, this.opts, now);
    this.client = new Client(sim, 1, this.up, this.down, this.opts, now);
    this.local = new Local(sim, 2, this.opts);
    this.localActive = false;
    this.client.onTick = (t, input) => {
      if (this.localActive) this.local.doTick(input);
    };
    // start a few ticks ahead; clock steering settles the real lead
    this.client.now = now;
    const lead = Math.ceil(this.opts.rttMs / 2 / TICK_MS) + this.opts.bufferTicks;
    for (let i = 0; i < lead; i++) this.client.doTick({ steer: 0, throttle: 0, buttons: 0 });
  }
  applyOpts() {
    for (const l of [this.up, this.down]) {
      l.oneWay = this.opts.rttMs / 2;
      l.jitter = this.opts.jitterMs;
      l.loss = this.opts.lossPct / 100;
    }
  }
  setOpts(o) {
    Object.assign(this.opts, o);
    this.applyOpts();
  }
  setLocalActive(on) {
    if (on && !this.localActive) {
      this.sim.copySlot(2, 1);
      this.local.prev = this.client.prev;
      this.local.cur = this.client.cur;
      this.local.prevBot = this.client.prevBot;
      this.local.curBot = this.client.curBot;
      this.local.botHist.clear();
      // seed the bot history from what the networked view was showing
      const snaps = this.client.snaps;
      for (const s of snaps) this.local.botHist.set(s.tick, s);
      const last = snaps[snaps.length - 1];
      const nowTick = this.sim.tick(2);
      const predicted = pose(this.sim, 2, 1);
      if (last) {
        for (let t = last.tick + 1; t < nowTick; t++)
          this.local.botHist.set(t, lerpPose(last, predicted, (t - last.tick) / (nowTick - last.tick)));
      }
      this.local.recordBot();
    }
    this.localActive = on;
  }
  frame(now, input) {
    this.server.update(now);
    this.client.update(now, input);
    const c = this.client;
    const predictedRemote = this.opts.remoteView === "predicted";
    const net = {
      own: c.ownPose(),
      bot: predictedRemote ? c.predictedRemotePose() : c.remotePose(now),
      ghost: c.serverGhost(),
    };
    let shown = net;
    if (this.localActive) {
      const a = c.alpha();
      const rt = c.remoteRenderTick(now);
      shown = {
        own: lerpPose(this.local.prev, this.local.cur, Math.max(0, a)),
        bot: predictedRemote
          ? lerpPose(this.local.prevBot, this.local.curBot, Math.max(0, a))
          : rt === null ? pose(this.sim, 2, 1) : this.local.botPose(rt),
        ghost: null,
      };
    }
    return { net, shown };
  }
  // slip of the shown car, for skid marks
  slip() {
    const slot = this.localActive ? 2 : 1;
    const s = this.sim;
    const h = (s.carH(slot, 0) / 65536) * 2 * Math.PI;
    const vx = s.carVX(slot, 0) / F, vy = s.carVY(slot, 0) / F;
    return Math.abs(-Math.sin(h) * vx + Math.cos(h) * vy);
  }
}
