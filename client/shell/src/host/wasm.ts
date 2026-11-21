// host.wasm (host/, server/src's session code built for the browser): a thin
// typed wrapper, shared by the host Worker and the Node soak/smoke tests.
// No DOM or Worker APIs here.
//
// Every time is in ns on the caller's monotonic clock and is passed in; the
// module never reads a clock except `stopwatch` for its timing metrics.

export const OUT_STREAM = 0;
export const OUT_DATAGRAM = 1;
export const OUT_CLOSE = 2;
export type OutKind = typeof OUT_STREAM | typeof OUT_DATAGRAM | typeof OUT_CLOSE;

interface Exports {
  memory: WebAssembly.Memory;
  alloc(n: number): number;
  free(p: number, n: number): void;
  textPtr(): number;
  textLen(): number;
  outPtr(): number;
  outLen(): number;
  outClear(): void;
  start(mapPtr: number, mapLen: number, namePtr: number, nameLen: number, maxPlayers: number, seedLo: number, seedHi: number, record: boolean, now: number, wallSeconds: number, entropy: number): number;
  synthMap(): number;
  loadCars(styPtr: number, styLen: number, gciPtr: number, gciLen: number): number;
  opened(peer: number, transport: number, now: number): number;
  stream(peer: number, p: number, n: number, now: number): void;
  datagram(peer: number, p: number, n: number, now: number): void;
  closed(peer: number, now: number): void;
  tick(now: number): number;
  nextDeadline(): number;
  stats(now: number): number;
  stop(now: number): number;
  replayPtr(): number;
  simTick(): number;
}

export interface StartInfo {
  mapHash: string;
  layoutHash: string;
  maxPlayers: number;
  simMaxPlayers: number;
  config: string;
}

/** What `stats` returns: protocol.ts FromHost "stats" fields plus extras. */
export interface HostStats {
  tick: number;
  stepUsP50: number;
  stepUsP99: number;
  stepUsMax: number;
  encodeUsP50: number;
  encodeUsP99: number;
  behindTicks: number;
  lateTicks: number;
  skippedTicks: number;
  /** Ticks stepped in this window. */
  ticks: number;
  players: number;
  replayBytes: number;
  peers: { peer: number; slots: number[]; rttMs: number; txBps: number; rxBps: number; snapshots: number; lost: number }[];
}

const LEVELS = ["error", "warn", "info", "debug"] as const;

export class HostModule {
  private w: Exports;
  private scratch = 0;
  private scratchLen = 0;
  private dec = new TextDecoder();

  private constructor(w: Exports) {
    this.w = w;
  }

  /**
   * `stopwatch` returns monotonic ns and is used only to time steps and
   * encodes; `log` receives the session's log lines.
   */
  static async instantiate(bytes: BufferSource, stopwatch: () => number, log: (level: string, line: string) => void = () => {}): Promise<HostModule> {
    let self: HostModule | null = null;
    const env = {
      hostLog: (level: number, p: number, n: number) => {
        const text = self ? self.dec.decode(new Uint8Array(self.w.memory.buffer, p, n)) : "";
        log(LEVELS[level] ?? "info", text);
      },
      hostStopwatch: stopwatch,
    };
    const { instance } = await WebAssembly.instantiate(bytes, { env });
    self = new HostModule(instance.exports as unknown as Exports);
    return self;
  }

  private u8(p: number, n: number): Uint8Array {
    return new Uint8Array(this.w.memory.buffer, p, n);
  }

  private text(): string {
    return this.dec.decode(this.u8(this.w.textPtr(), this.w.textLen()));
  }

  /** Copies `bytes` into a reused buffer in WASM memory; returns its address. */
  private put(bytes: Uint8Array): number {
    if (bytes.length > this.scratchLen) {
      if (this.scratch) this.w.free(this.scratch, this.scratchLen);
      const n = Math.max(bytes.length, 64 * 1024);
      this.scratch = this.w.alloc(n);
      if (!this.scratch) {
        this.scratchLen = 0;
        throw new Error("host.wasm: out of memory");
      }
      this.scratchLen = n;
    }
    if (bytes.length) this.u8(this.scratch, bytes.length).set(bytes);
    return this.scratch;
  }

  /** The server's synthetic test city as .gmp bytes (no game data needed). */
  synthMap(): Uint8Array {
    if (this.w.synthMap() !== 0) throw new Error(this.text());
    const out = this.u8(this.w.outPtr(), this.w.outLen()).slice();
    this.w.outClear();
    return out;
  }

  /** Car models from a .sty and an optional .gci (client/wasm loadCarInfo's recipe). Before start. Returns the count and carModelsHash. */
  loadCars(sty: Uint8Array, gci: Uint8Array | null): { cars: number; hash: string } {
    const g = gci ?? new Uint8Array(0);
    const total = sty.length + g.length;
    const p = this.w.alloc(Math.max(total, 1));
    if (!p) throw new Error("host.wasm: out of memory for the style");
    try {
      const mem = this.u8(p, total);
      mem.set(sty, 0);
      mem.set(g, sty.length);
      if (this.w.loadCars(p, sty.length, p + sty.length, g.length) !== 0) throw new Error(`host.wasm loadCars: ${this.text()}`);
      return JSON.parse(this.text()) as { cars: number; hash: string };
    } finally {
      this.w.free(p, Math.max(total, 1));
    }
  }

  start(o: { session: string; map: Uint8Array; maxPlayers: number; seed: number; record: boolean; now: number; entropy: Uint8Array }): StartInfo {
    const name = new TextEncoder().encode(o.session);
    // One allocation for map + name + entropy; freed after start (the map
    // is parsed into a grid and hashed; nothing keeps the bytes).
    const total = o.map.length + name.length + 32;
    const p = this.w.alloc(total);
    if (!p) throw new Error("host.wasm: out of memory for the map");
    try {
      const mem = this.u8(p, total);
      mem.set(o.map, 0);
      mem.set(name, o.map.length);
      mem.set(o.entropy.subarray(0, 32), o.map.length + name.length);
      const seedLo = o.seed >>> 0;
      const seedHi = Math.floor(o.seed / 2 ** 32) >>> 0;
      const rc = this.w.start(p, o.map.length, p + o.map.length, name.length, o.maxPlayers, seedLo, seedHi, o.record, o.now, Math.floor(Date.now() / 1000), p + o.map.length + name.length);
      if (rc !== 0) throw new Error(`host.wasm start: ${this.text()}`);
      return JSON.parse(this.text()) as StartInfo;
    } finally {
      this.w.free(p, total);
    }
  }

  opened(peer: number, transport: number, now: number): void {
    if (this.w.opened(peer, transport, now) !== 0) throw new Error(`host.wasm opened: ${this.text()}`);
  }
  stream(peer: number, msg: Uint8Array, now: number): void {
    this.w.stream(peer, this.put(msg), msg.length, now);
  }
  datagram(peer: number, msg: Uint8Array, now: number): void {
    this.w.datagram(peer, this.put(msg), msg.length, now);
  }
  closed(peer: number, now: number): void {
    this.w.closed(peer, now);
  }
  /** Steps every tick due at `now`; returns how many ran. */
  tick(now: number): number {
    return this.w.tick(now);
  }
  /** When the next tick is due (ns, same clock as `now`). */
  nextDeadline(): number {
    return this.w.nextDeadline();
  }
  simTick(): number {
    return this.w.simTick();
  }
  /** Stats since the previous call. */
  stats(now: number): HostStats {
    if (!this.w.stats(now)) throw new Error("host.wasm stats: not started");
    return JSON.parse(this.text()) as HostStats;
  }
  /** bye(shutting_down) + close to every client (drain them), and the replay bytes if recording. */
  stop(now: number): Uint8Array | null {
    const n = this.w.stop(now);
    return n ? this.u8(this.w.replayPtr(), n).slice() : null;
  }

  /** Hands every queued outbound message to `f` (bodies are fresh copies) and clears the queue. */
  drain(f: (peer: number, kind: OutKind, msg: ArrayBuffer) => void): void {
    const len = this.w.outLen();
    if (!len) return;
    const buf = this.u8(this.w.outPtr(), len);
    const dv = new DataView(buf.buffer, buf.byteOffset, len);
    let o = 0;
    // Copy everything out first: `f` may call back into the module.
    const msgs: [number, OutKind, ArrayBuffer][] = [];
    while (o + 9 <= len) {
      const peer = dv.getUint32(o, true);
      const kind = dv.getUint8(o + 4) as OutKind;
      const n = dv.getUint32(o + 5, true);
      o += 9;
      msgs.push([peer, kind, buf.slice(o, o + n).buffer]);
      o += n;
    }
    this.w.outClear();
    for (const [peer, kind, msg] of msgs) f(peer, kind, msg);
  }
}
