// gta2-signal: WebRTC signalling rooms for browser-hosted games, and TURN
// credentials. One Durable Object per room; WebSockets use the hibernation
// API, so an idle room costs nothing while the host waits for players.
//
//   POST /rooms                 -> {room}            (host creates a room)
//   GET  /r/<room>?role=host    -> WebSocket          (the host; one per room)
//   GET  /r/<room>              -> WebSocket          (a joining peer)
//
// Wire messages (JSON text frames) are listed in README.md. ICE servers
// (STUN, plus TURN credentials when the TURN secrets are set) arrive in the
// first server message, `welcome`, so there is no separate ICE endpoint and
// TURN credentials only go to sockets that are in a live room.

import { DurableObject } from "cloudflare:workers";

export interface Env {
  ROOMS: DurableObjectNamespace<Room>;
  /** Comma- or space-separated origins allowed to call the Worker, e.g. "https://user.github.io". */
  ALLOWED_ORIGINS?: string;
  /** "true" also allows http(s)://localhost, 127.0.0.1 and [::1] on any port (local development). */
  ALLOW_LOCALHOST?: string;
  /** Cloudflare TURN key id and its API token (secrets). Without them, ICE is STUN only. */
  TURN_KEY_ID?: string;
  TURN_KEY_API_TOKEN?: string;
}

// The main module may only export handlers and Durable Object classes, so
// constants and helpers stay module-private.
const MAX_PEERS = 16;
/** Largest client message accepted, in bytes. SDP offers are a few KB. */
const MAX_MESSAGE_BYTES = 16 * 1024;
/** Token bucket per socket: burst and refill per second. */
const RATE_BURST = 60;
const RATE_PER_SEC = 20;
/** A reserved room whose host never connects is dropped after this long. */
const RESERVE_MS = 2 * 60 * 1000;
/** A room with no message from anyone (the host pings) for this long is closed. */
const IDLE_MS = 30 * 60 * 1000;
/** TURN credentials outlive any game: an allocation refreshed after its credentials expire is dropped by the server. */
const TURN_TTL_SECONDS = 24 * 3600;

const STUN_SERVERS: RTCIceServerLike = {
  urls: ["stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"],
};
const TURN_API = "https://rtc.live.cloudflare.com/v1/turn/keys";

export interface RTCIceServerLike {
  urls: string | string[];
  username?: string;
  credential?: string;
}
export interface IceConfig {
  iceServers: RTCIceServerLike[];
}

const B32 = "abcdefghijklmnopqrstuvwxyz234567";
function randomId(n = 8): string {
  const bytes = crypto.getRandomValues(new Uint8Array(n));
  let s = "";
  for (const b of bytes) s += B32[b & 31];
  return s;
}

const ROOM_PATH = /^\/r\/([a-z2-7]{8})$/;

// ---------------------------------------------------------------------------
// ICE

/**
 * STUN servers plus, when TURN_KEY_ID and TURN_KEY_API_TOKEN are set,
 * short-lived TURN credentials from Cloudflare's TURN service. The API token
 * never leaves the Worker. Any failure falls back to STUN only.
 */
async function mintIce(env: Env, fetchImpl: typeof fetch = fetch): Promise<IceConfig> {
  const stunOnly: IceConfig = { iceServers: [STUN_SERVERS] };
  if (!env.TURN_KEY_ID || !env.TURN_KEY_API_TOKEN) return stunOnly;
  try {
    const res = await fetchImpl(
      `${TURN_API}/${encodeURIComponent(env.TURN_KEY_ID)}/credentials/generate-ice-servers`,
      {
        method: "POST",
        headers: { Authorization: `Bearer ${env.TURN_KEY_API_TOKEN}`, "Content-Type": "application/json" },
        body: JSON.stringify({ ttl: TURN_TTL_SECONDS }),
        signal: AbortSignal.timeout(3000),
      },
    );
    if (!res.ok) {
      console.warn(`TURN credentials: HTTP ${res.status} ${(await res.text()).slice(0, 200)}`);
      return stunOnly;
    }
    const body = (await res.json()) as { iceServers?: RTCIceServerLike | RTCIceServerLike[] };
    const list = Array.isArray(body.iceServers) ? body.iceServers : body.iceServers ? [body.iceServers] : [];
    const turn: RTCIceServerLike[] = [];
    for (const s of list) {
      if (typeof s?.username !== "string" || typeof s?.credential !== "string") continue;
      // Port 53 is blocked by browsers and only makes ICE wait for a timeout.
      const urls = (Array.isArray(s.urls) ? s.urls : [s.urls]).filter(
        (u) => typeof u === "string" && /^turns?:/.test(u) && !/:53(\?|$)/.test(u),
      );
      if (urls.length) turn.push({ urls, username: s.username, credential: s.credential });
    }
    if (!turn.length) console.warn(`TURN credentials: no usable TURN entries in ${list.length} ice servers`);
    return { iceServers: [STUN_SERVERS, ...turn] };
  } catch (e) {
    console.warn(`TURN credentials: ${(e as Error).message}`);
    return stunOnly;
  }
}

// ---------------------------------------------------------------------------
// Worker: routing and CORS

const LOCALHOST = /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/;

function originAllowed(origin: string, env: Env): boolean {
  if (env.ALLOW_LOCALHOST === "true" && LOCALHOST.test(origin)) return true;
  const list = (env.ALLOWED_ORIGINS ?? "").split(/[\s,]+/).filter(Boolean);
  return list.includes(origin);
}

function cors(origin: string | null): Record<string, string> {
  if (!origin) return {};
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  };
}

const json = (body: unknown, status: number, headers: Record<string, string>): Response =>
  new Response(JSON.stringify(body), { status, headers: { ...headers, "Content-Type": "application/json" } });

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    // Browsers always send Origin on cross-origin fetches and on WebSocket
    // upgrades; a request without one is not from a page and needs no CORS.
    const origin = request.headers.get("Origin");
    if (origin && !originAllowed(origin, env)) return new Response("origin not allowed", { status: 403 });
    const h = cors(origin);

    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: h });

    if (url.pathname === "/rooms") {
      if (request.method !== "POST") return new Response("method not allowed", { status: 405, headers: h });
      const room = randomId();
      await env.ROOMS.get(env.ROOMS.idFromName(room)).reserve();
      return json({ room }, 201, h);
    }

    const m = ROOM_PATH.exec(url.pathname);
    if (m) {
      if (request.method !== "GET" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
        return new Response("expected a WebSocket upgrade", { status: 426, headers: h });
      }
      return env.ROOMS.get(env.ROOMS.idFromName(m[1])).fetch(request);
    }

    if (url.pathname === "/") return new Response("gta2-signal\n", { headers: h });
    return new Response("not found", { status: 404, headers: h });
  },
} satisfies ExportedHandler<Env>;

// ---------------------------------------------------------------------------
// Room

interface Attachment {
  role: "host" | "peer";
  peer: string;
  /** Rate limit bucket. */
  tokens: number;
  t: number;
  /** Last message time, for idle expiry. */
  last: number;
}

type Outgoing =
  | { type: "welcome"; role: "host" | "peer"; room: string; peer?: string; ice: IceConfig }
  | { type: "peer"; peer: string }
  | { type: "peer-left"; peer: string }
  | { type: "closed"; reason: string }
  | { type: "error"; reason: string }
  | { type: "pong" }
  | { from: string; msg: unknown };

const send = (ws: WebSocket, m: Outgoing): void => {
  try {
    ws.send(JSON.stringify(m));
  } catch {
    // Socket already closing.
  }
};

/** Close codes (4000-4999 are application codes). */
const CLOSE_REFUSED = 4000;
const CLOSE_ROOM_GONE = 4001;

export class Room extends DurableObject<Env> {
  /** Called by POST /rooms. The host must connect within RESERVE_MS. */
  async reserve(): Promise<void> {
    await this.ctx.storage.put("reserved", Date.now());
    await this.ctx.storage.setAlarm(Date.now() + RESERVE_MS);
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const room = ROOM_PATH.exec(url.pathname)?.[1] ?? "";
    const role: "host" | "peer" = url.searchParams.get("role") === "host" ? "host" : "peer";
    const ice = await mintIce(this.env);
    // No awaits between these checks and acceptWebSocket other than storage,
    // which holds the input gate, so two joins cannot both take the last slot.
    const reserved = (await this.ctx.storage.get<number>("reserved")) !== undefined;
    const hosts = this.ctx.getWebSockets("host");

    let refuse: string | null = null;
    if (role === "host") {
      if (!reserved) refuse = "no such room";
      else if (hosts.length) refuse = "room already has a host";
    } else if (!hosts.length) refuse = "no such room";
    else if (this.ctx.getWebSockets("peer").length >= MAX_PEERS) refuse = "room full";

    const [client, server] = Object.values(new WebSocketPair());
    if (refuse) {
      // A browser cannot read the HTTP status of a failed upgrade, so accept
      // and say why before closing. Not hibernatable: it closes at once.
      server.accept();
      send(server, { type: "closed", reason: refuse });
      server.close(CLOSE_REFUSED, refuse);
      return new Response(null, { status: 101, webSocket: client });
    }

    const now = Date.now();
    const peer = role === "host" ? "host" : randomId();
    this.ctx.acceptWebSocket(server, role === "host" ? ["host"] : ["peer", `p:${peer}`]);
    const att: Attachment = { role, peer, tokens: RATE_BURST, t: now, last: now };
    server.serializeAttachment(att);
    send(server, role === "host" ? { type: "welcome", role, room, ice } : { type: "welcome", role, room, peer, ice });
    if (role === "host") await this.ctx.storage.setAlarm(now + IDLE_MS);
    else send(hosts[0], { type: "peer", peer });
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, data: string | ArrayBuffer): Promise<void> {
    const att = ws.deserializeAttachment() as Attachment;
    const now = Date.now();
    att.tokens = Math.min(RATE_BURST, att.tokens + ((now - att.t) / 1000) * RATE_PER_SEC);
    att.t = now;
    att.last = now;
    const limited = att.tokens < 1;
    if (!limited) att.tokens -= 1;
    ws.serializeAttachment(att);
    if (limited) return send(ws, { type: "error", reason: "rate limited" });

    const size = typeof data === "string" ? new TextEncoder().encode(data).byteLength : data.byteLength;
    if (size > MAX_MESSAGE_BYTES) return send(ws, { type: "error", reason: "message too large" });
    if (typeof data !== "string") return send(ws, { type: "error", reason: "expected JSON text" });

    let m: { type?: unknown; to?: unknown; msg?: unknown };
    try {
      m = JSON.parse(data);
    } catch {
      return send(ws, { type: "error", reason: "expected JSON text" });
    }
    if (typeof m !== "object" || m === null) return send(ws, { type: "error", reason: "expected an object" });
    if (m.type === "ping") return send(ws, { type: "pong" });
    if (typeof m.to !== "string" || typeof m.msg !== "object" || m.msg === null) {
      return send(ws, { type: "error", reason: "expected {to, msg}" });
    }

    if (att.role === "peer") {
      if (m.to !== "host") return send(ws, { type: "error", reason: "peers can only send to host" });
      const host = this.ctx.getWebSockets("host")[0];
      if (host) send(host, { from: att.peer, msg: m.msg });
      return;
    }
    const target = this.ctx.getWebSockets(`p:${m.to}`)[0];
    if (!target) return send(ws, { type: "error", reason: `no such peer: ${m.to}` });
    send(target, { from: "host", msg: m.msg });
  }

  async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    await this.left(ws, code);
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    await this.left(ws, 1011);
  }

  private async left(ws: WebSocket, code: number): Promise<void> {
    try {
      ws.close(code === 1005 || code === 1006 ? 1000 : code, "bye");
    } catch {
      // Already closed.
    }
    const att = ws.deserializeAttachment() as Attachment | null;
    if (!att) return;
    if (att.role === "host") await this.closeRoom("host left");
    else {
      const host = this.ctx.getWebSockets("host").find((h) => h !== ws);
      if (host) send(host, { type: "peer-left", peer: att.peer });
    }
  }

  /** Tells every remaining socket why, disconnects it, and forgets the room. */
  private async closeRoom(reason: string): Promise<void> {
    for (const ws of this.ctx.getWebSockets()) {
      send(ws, { type: "closed", reason });
      ws.serializeAttachment(null); // so its close event does nothing more
      try {
        ws.close(CLOSE_ROOM_GONE, reason);
      } catch {
        // Already closed.
      }
    }
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
  }

  async alarm(): Promise<void> {
    const sockets = this.ctx.getWebSockets();
    if (!this.ctx.getWebSockets("host").length) return this.closeRoom("host left");
    let last = 0;
    for (const ws of sockets) {
      const att = ws.deserializeAttachment() as Attachment | null;
      if (att) last = Math.max(last, att.last);
    }
    if (Date.now() - last >= IDLE_MS) return this.closeRoom("idle");
    await this.ctx.storage.setAlarm(last + IDLE_MS);
  }
}
