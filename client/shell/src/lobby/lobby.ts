// The lobby on data channel `f`, before the game: the joiner says which map
// it was invited to, the host lists the files the match needs, and the host
// sends the ones the joiner lacks if its "share my game files" option is on.
// Message format: files.ts. Once the joiner says "ready" both sides stop
// using the channel.

import {
  Assembler,
  type FileInfo,
  HIGH_WATER,
  type LobbyMsg,
  type Limiter,
  chunks,
  decodeChunk,
  parseLobbyMsg,
  safeName,
} from "./files.ts";

/** What the lobby needs from a data channel; wrapDataChannel adapts an RTCDataChannel. */
export interface FileChannel {
  send(data: string | Uint8Array): void;
  bufferedAmount(): number;
  onMessage: ((data: string | ArrayBuffer | Uint8Array) => void) | null;
}

export function wrapDataChannel(ch: RTCDataChannel): FileChannel {
  ch.binaryType = "arraybuffer";
  const fc: FileChannel = {
    send: (d) => (typeof d === "string" ? ch.send(d) : ch.send(d as Uint8Array<ArrayBuffer>)),
    bufferedAmount: () => ch.bufferedAmount,
    onMessage: null,
  };
  ch.onmessage = (e) => fc.onMessage?.(e.data as string | ArrayBuffer);
  return fc;
}

const send = (ch: FileChannel, m: LobbyMsg): void => ch.send(JSON.stringify(m));
const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

// ------------------------------------------------------------------ host

export interface HostFiles {
  /** SHA-256 hex of the .gmp being played. */
  mapHash: string;
  description: string;
  /** The files a joiner needs for this match (the .gmp and its .sty). */
  files: FileInfo[];
  /** Read live, so the host can switch sharing on and off while hosting. */
  share(): boolean;
  read(sha256: string): Promise<Uint8Array>;
}

export type HostLobbyState = "lobby" | "sending" | "refused" | "ready" | "error";

export class LobbyHost {
  state: HostLobbyState = "lobby";
  detail = "";
  /** Bytes sent so far, and the total requested. */
  sent = 0;
  total = 0;
  onChange: (() => void) | null = null;
  private nextId = 1;
  private done = false;
  private ch: FileChannel;
  private files: HostFiles;
  private limiter: Limiter;

  constructor(ch: FileChannel, files: HostFiles, limiter: Limiter) {
    this.ch = ch;
    this.files = files;
    this.limiter = limiter;
    ch.onMessage = (d) => {
      if (this.done || typeof d !== "string") return;
      const m = parseLobbyMsg(d);
      if (m) void this.handle(m);
    };
  }

  private set(state: HostLobbyState, detail = ""): void {
    this.state = state;
    this.detail = detail;
    this.onChange?.();
  }

  private async handle(m: LobbyMsg): Promise<void> {
    switch (m.t) {
      case "want":
        if (this.files.mapHash.slice(0, 12) !== m.map) {
          send(this.ch, { t: "error", message: "The host is no longer playing the map in this link. Ask for a new link." });
          return this.set("error", "wrong map");
        }
        send(this.ch, { t: "match", description: this.files.description, share: this.files.share(), files: this.files.files });
        return;
      case "get": {
        const want = this.files.files.filter((f) => m.files.includes(f.sha256));
        if (want.length === 0) return;
        if (!this.files.share()) {
          send(this.ch, { t: "refused", names: want.map((f) => f.name) });
          return this.set("refused", want.map((f) => f.name).join(", "));
        }
        this.total += want.reduce((n, f) => n + f.size, 0);
        this.set("sending");
        for (const f of want) void this.limiter.run(() => this.sendFile(f)).catch((e) => this.set("error", String((e as Error).message ?? e)));
        return;
      }
      case "got":
        if (!m.ok) this.set("error", `the joiner could not verify ${m.sha256.slice(0, 12)}`);
        return;
      case "ready":
        this.done = true;
        this.ch.onMessage = null;
        return this.set("ready");
    }
  }

  private async sendFile(f: FileInfo): Promise<void> {
    if (this.done) return;
    const data = await this.files.read(f.sha256);
    const id = this.nextId++;
    send(this.ch, { t: "file", id, ...f });
    for (const c of chunks(id, data)) {
      while (this.ch.bufferedAmount() > HIGH_WATER) await sleep(5);
      this.ch.send(c);
      this.sent += c.length - 4;
      this.onChange?.();
    }
    send(this.ch, { t: "end", id });
  }
}

// ---------------------------------------------------------------- joiner

export interface JoinStore {
  /** Whether a file with this SHA-256 is already in the local asset store. */
  has(sha256: string): boolean;
  /** Keep a received, verified file in the local asset store. */
  save(info: FileInfo, bytes: Uint8Array): Promise<void>;
}

export interface JoinProgress {
  file: FileInfo;
  received: number;
}

export interface MatchFiles {
  description: string;
  files: FileInfo[];
  /** The files that came from the host this time. */
  downloaded: FileInfo[];
}

export class LobbyJoin {
  onMatch: ((files: FileInfo[], missing: FileInfo[], share: boolean) => void) | null = null;
  onProgress: ((p: JoinProgress) => void) | null = null;
  onSaved: ((f: FileInfo) => void) | null = null;

  private ch: FileChannel;
  private store: JoinStore;

  constructor(ch: FileChannel, store: JoinStore) {
    this.ch = ch;
    this.store = store;
  }

  /** Asks for the match's files and fetches what is missing. Rejects with a message for the player. */
  run(mapHash12: string): Promise<MatchFiles> {
    return new Promise<MatchFiles>((resolve, reject) => {
      const open = new Map<number, Assembler>();
      let missing = new Map<string, FileInfo>();
      let match: { description: string; files: FileInfo[] } | null = null;
      const downloaded: FileInfo[] = [];
      let finished = false;
      const fail = (msg: string): void => {
        if (finished) return;
        finished = true;
        this.ch.onMessage = null;
        reject(new Error(msg));
      };
      const ready = (): void => {
        if (finished || !match) return;
        finished = true;
        send(this.ch, { t: "ready" });
        this.ch.onMessage = null;
        resolve({ ...match, downloaded });
      };
      const needMsg = (names: string[]): string =>
        `The host is not sharing game files, and this browser does not have ${names.join(" and ")}. ` +
        "Import your GTA2 folder (Files & maps), then open the link again.";

      this.ch.onMessage = (d) => {
        if (finished) return;
        if (typeof d !== "string") {
          const c = decodeChunk(d);
          const a = c && open.get(c.id);
          if (!c || !a) return;
          a.add(c.bytes);
          this.onProgress?.({ file: a.info, received: a.received });
          return;
        }
        const m = parseLobbyMsg(d);
        if (!m) return;
        switch (m.t) {
          case "error":
            return fail(m.message);
          case "match": {
            match = { description: m.description, files: m.files };
            const miss = m.files.filter((f) => !this.store.has(f.sha256));
            this.onMatch?.(m.files, miss, m.share);
            if (miss.length === 0) return ready();
            if (!m.share) return fail(needMsg(miss.map((f) => f.name)));
            missing = new Map(miss.map((f) => [f.sha256, f]));
            send(this.ch, { t: "get", files: miss.map((f) => f.sha256) });
            return;
          }
          case "refused":
            return fail(needMsg(m.names));
          case "file": {
            const want = missing.get(m.sha256);
            const name = safeName(m.name, m.kind);
            // Only files we asked for, under the name and size the match listed.
            if (!want || !name || m.size !== want.size) return;
            open.set(m.id, new Assembler({ name, kind: m.kind, size: m.size, sha256: m.sha256 }));
            return;
          }
          case "end": {
            const a = open.get(m.id);
            if (!a) return;
            open.delete(m.id);
            a.finish()
              .then(async (bytes) => {
                await this.store.save(a.info, bytes);
                send(this.ch, { t: "got", sha256: a.info.sha256, ok: true });
                downloaded.push(a.info);
                this.onSaved?.(a.info);
                missing.delete(a.info.sha256);
                if (missing.size === 0) ready();
              })
              .catch((e) => {
                if (!finished) send(this.ch, { t: "got", sha256: a.info.sha256, ok: false });
                fail(`Download failed: ${(e as Error).message ?? e}`);
              });
            return;
          }
        }
      };
      send(this.ch, { t: "want", map: mapHash12 });
    });
  }
}
