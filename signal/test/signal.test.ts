// Runs the bundled Worker (dist/index.js, from `npm run build`) in Miniflare
// and talks to it over real WebSockets. Offline: the TURN API is mocked with
// Miniflare's outbound service.

import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { Miniflare } from "miniflare";

const scriptPath = fileURLToPath(new URL("../dist/index.js", import.meta.url));

function makeMf(bindings: Record<string, string>, outbound?: (req: Request) => Response | Promise<Response>): Miniflare {
  return new Miniflare({
    modules: true,
    scriptPath,
    compatibilityDate: "2025-11-01",
    durableObjects: { ROOMS: { className: "Room", useSQLite: true } },
    bindings: { ALLOWED_ORIGINS: "https://example.github.io", ALLOW_LOCALHOST: "false", ...bindings },
    ...(outbound ? { outboundService: outbound } : {}),
  });
}

type Msg = Record<string, any>;

class Client {
  ws: WebSocket;
  private queue: Msg[] = [];
  private waiters: ((m: Msg) => void)[] = [];
  closed: Promise<{ code: number; reason: string }>;
  constructor(url: string) {
    this.ws = new WebSocket(url);
    this.ws.onmessage = (e) => {
      const m = JSON.parse(String(e.data));
      const w = this.waiters.shift();
      if (w) w(m);
      else this.queue.push(m);
    };
    this.closed = new Promise((res) => {
      this.ws.onclose = (e) => res({ code: e.code, reason: e.reason });
    });
  }
  next(ms = 2000): Promise<Msg> {
    const m = this.queue.shift();
    if (m) return Promise.resolve(m);
    return new Promise((res, rej) => {
      const t = setTimeout(() => rej(new Error("timed out waiting for a message")), ms);
      this.waiters.push((m) => {
        clearTimeout(t);
        res(m);
      });
    });
  }
  send(m: unknown): void {
    this.ws.send(typeof m === "string" ? m : JSON.stringify(m));
  }
}

describe("signalling rooms", () => {
  let mf: Miniflare;
  let base: URL;
  before(async () => {
    mf = makeMf({});
    base = await mf.ready;
  });
  after(() => mf.dispose());

  const wsUrl = (path: string) => new URL(path, base).href.replace(/^http/, "ws");
  const createRoom = async (): Promise<string> => {
    const res = await mf.dispatchFetch(new URL("/rooms", base), { method: "POST" });
    assert.equal(res.status, 201);
    const { room } = (await res.json()) as { room: string };
    assert.match(room, /^[a-z2-7]{8}$/);
    return room;
  };
  const host = async (room: string) => {
    const c = new Client(wsUrl(`/r/${room}?role=host`));
    const w = await c.next();
    assert.equal(w.type, "welcome");
    assert.equal(w.role, "host");
    assert.equal(w.room, room);
    return c;
  };
  const peer = async (room: string) => {
    const c = new Client(wsUrl(`/r/${room}`));
    const w = await c.next();
    assert.equal(w.type, "welcome", JSON.stringify(w));
    assert.equal(w.role, "peer");
    return { c, id: w.peer as string };
  };

  test("room create, host and peer connect, offer/answer/ice both ways", async () => {
    const room = await createRoom();
    const h = await host(room);
    const { c: p, id } = await peer(room);
    assert.match(id, /^[a-z2-7]{8}$/);
    assert.deepEqual(await h.next(), { type: "peer", peer: id });

    h.send({ to: id, msg: { kind: "offer", sdp: "v=0 offer" } });
    assert.deepEqual(await p.next(), { from: "host", msg: { kind: "offer", sdp: "v=0 offer" } });
    p.send({ to: "host", msg: { kind: "answer", sdp: "v=0 answer" } });
    assert.deepEqual(await h.next(), { from: id, msg: { kind: "answer", sdp: "v=0 answer" } });
    p.send({ to: "host", msg: { kind: "ice", candidate: null } });
    assert.deepEqual(await h.next(), { from: id, msg: { kind: "ice", candidate: null } });

    // Peers cannot address each other.
    p.send({ to: "someone", msg: { kind: "ice", candidate: null } });
    assert.equal((await p.next()).type, "error");

    p.ws.close(1000);
    assert.deepEqual(await h.next(), { type: "peer-left", peer: id });
    h.ws.close(1000);
  });

  test("host leaving closes every peer", async () => {
    const room = await createRoom();
    const h = await host(room);
    const a = await peer(room);
    const b = await peer(room);
    await h.next();
    await h.next();
    h.ws.close(1000);
    for (const p of [a, b]) {
      assert.deepEqual(await p.c.next(), { type: "closed", reason: "host left" });
      const c = await p.c.closed;
      assert.equal(c.code, 4001);
    }
    // The room is gone: neither a peer nor a new host can use it.
    const late = new Client(wsUrl(`/r/${room}`));
    assert.deepEqual(await late.next(), { type: "closed", reason: "no such room" });
    const h2 = new Client(wsUrl(`/r/${room}?role=host`));
    assert.deepEqual(await h2.next(), { type: "closed", reason: "no such room" });
  });

  test("unknown room and second host are refused", async () => {
    const p = new Client(wsUrl("/r/aaaaaaaa"));
    assert.deepEqual(await p.next(), { type: "closed", reason: "no such room" });
    assert.equal((await p.closed).code, 4000);

    const room = await createRoom();
    const h = await host(room);
    const h2 = new Client(wsUrl(`/r/${room}?role=host`));
    assert.deepEqual(await h2.next(), { type: "closed", reason: "room already has a host" });
    h.ws.close(1000);
  });

  test("room full at 16 peers", async () => {
    const room = await createRoom();
    const h = await host(room);
    const peers = [];
    for (let i = 0; i < 16; i++) peers.push(await peer(room));
    const extra = new Client(wsUrl(`/r/${room}`));
    assert.deepEqual(await extra.next(), { type: "closed", reason: "room full" });
    // A slot frees up when a peer leaves.
    for (let i = 0; i < 16; i++) await h.next();
    peers[0].c.ws.close(1000);
    assert.equal((await h.next()).type, "peer-left");
    await peer(room);
    h.ws.close(1000);
  });

  test("oversized and malformed messages are rejected, the socket stays open", async () => {
    const room = await createRoom();
    const h = await host(room);
    const { c: p } = await peer(room);
    await h.next();
    p.send({ to: "host", msg: { kind: "offer", sdp: "x".repeat(17 * 1024) } });
    assert.deepEqual(await p.next(), { type: "error", reason: "message too large" });
    p.send("not json");
    assert.equal((await p.next()).type, "error");
    p.send({ to: "host", msg: { kind: "answer", sdp: "ok" } });
    assert.equal((await h.next()).msg.sdp, "ok");
    p.send({ type: "ping" });
    assert.deepEqual(await p.next(), { type: "pong" });
    h.ws.close(1000);
  });

  test("rate limit drops a flood", async () => {
    const room = await createRoom();
    const h = await host(room);
    const { c: p } = await peer(room);
    await h.next();
    for (let i = 0; i < 100; i++) p.send({ type: "ping" });
    let limited = 0;
    for (let i = 0; i < 100; i++) if ((await p.next()).type === "error") limited++;
    assert.ok(limited >= 30, `expected most of the flood dropped, got ${limited}`);
    h.ws.close(1000);
  });

  test("CORS: allowed origin, refused origin, preflight", async () => {
    const ok = await mf.dispatchFetch(new URL("/rooms", base), {
      method: "POST",
      headers: { Origin: "https://example.github.io" },
    });
    assert.equal(ok.status, 201);
    assert.equal(ok.headers.get("Access-Control-Allow-Origin"), "https://example.github.io");
    const bad = await mf.dispatchFetch(new URL("/rooms", base), {
      method: "POST",
      headers: { Origin: "https://evil.example" },
    });
    assert.equal(bad.status, 403);
    const local = await mf.dispatchFetch(new URL("/rooms", base), {
      method: "POST",
      headers: { Origin: "http://localhost:8000" },
    });
    assert.equal(local.status, 403, "localhost is only allowed with ALLOW_LOCALHOST=true");
    const pre = await mf.dispatchFetch(new URL("/rooms", base), {
      method: "OPTIONS",
      headers: { Origin: "https://example.github.io", "Access-Control-Request-Method": "POST" },
    });
    assert.equal(pre.status, 204);
    assert.match(pre.headers.get("Access-Control-Allow-Methods") ?? "", /POST/);
  });

  test("ICE without TURN secrets is STUN only", async () => {
    const room = await createRoom();
    const c = new Client(wsUrl(`/r/${room}?role=host`));
    const w = await c.next();
    assert.deepEqual(w.ice, {
      iceServers: [{ urls: ["stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"] }],
    });
    c.ws.close(1000);
  });
});

describe("TURN credentials", () => {
  let mf: Miniflare;
  let base: URL;
  const calls: { url: string; auth: string | null; body: string }[] = [];
  before(async () => {
    mf = makeMf({ TURN_KEY_ID: "key123", TURN_KEY_API_TOKEN: "secret-token", ALLOW_LOCALHOST: "true" }, async (req) => {
      calls.push({ url: req.url, auth: req.headers.get("Authorization"), body: await req.text() });
      // Shape from Cloudflare's "Generate TURN credentials" docs.
      return Response.json(
        {
          iceServers: [
            { urls: ["stun:stun.cloudflare.com:3478", "stun:stun.cloudflare.com:53"] },
            {
              urls: [
                "turn:turn.cloudflare.com:3478?transport=udp",
                "turn:turn.cloudflare.com:53?transport=udp",
                "turn:turn.cloudflare.com:3478?transport=tcp",
                "turn:turn.cloudflare.com:80?transport=tcp",
                "turns:turn.cloudflare.com:5349?transport=tcp",
                "turns:turn.cloudflare.com:443?transport=tcp",
              ],
              username: "user-abc",
              credential: "cred-xyz",
            },
          ],
        },
        { status: 201 },
      );
    });
    base = await mf.ready;
  });
  after(() => mf.dispose());

  test("welcome carries minted TURN entries; the token stays server-side", async () => {
    const res = await mf.dispatchFetch(new URL("/rooms", base), {
      method: "POST",
      headers: { Origin: "http://localhost:5173" },
    });
    assert.equal(res.status, 201);
    const { room } = (await res.json()) as { room: string };
    const c = new Client(new URL(`/r/${room}?role=host`, base).href.replace(/^http/, "ws"));
    const w = await c.next();
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, "https://rtc.live.cloudflare.com/v1/turn/keys/key123/credentials/generate-ice-servers");
    assert.equal(calls[0].auth, "Bearer secret-token");
    assert.deepEqual(JSON.parse(calls[0].body), { ttl: 3600 });
    assert.deepEqual(w.ice.iceServers, [
      { urls: ["stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"] },
      {
        urls: [
          "turn:turn.cloudflare.com:3478?transport=udp",
          "turn:turn.cloudflare.com:3478?transport=tcp",
          "turn:turn.cloudflare.com:80?transport=tcp",
          "turns:turn.cloudflare.com:5349?transport=tcp",
          "turns:turn.cloudflare.com:443?transport=tcp",
        ],
        username: "user-abc",
        credential: "cred-xyz",
      },
    ]);
    assert.ok(!JSON.stringify(w).includes("secret-token"));
    c.ws.close(1000);
  });
});
