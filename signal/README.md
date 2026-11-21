# gta2-signal

A small Cloudflare Worker for browser-hosted games: WebRTC signalling rooms
(one Durable Object per room, WebSocket hibernation) and TURN credentials.
It never carries game traffic; once a peer's data channels are open the page
closes its signalling socket.

The page side is [`client/shell/src/net/signal-ws.ts`](../client/shell/src/net/signal-ws.ts)
(`hostRoom(base)`, `joinRoom(base, room)`), implementing the `Signaller`
contract in [`signal.ts`](../client/shell/src/net/signal.ts).

## HTTP

| Request | Result |
| --- | --- |
| `POST /rooms` | `201 {"room":"<8 chars a-z2-7>"}`. The host must connect within 2 minutes. |
| `GET /r/<room>?role=host` (WebSocket) | The host. One per room; the room lives while this socket is open. |
| `GET /r/<room>` (WebSocket) | A joining peer; the server assigns its id. |
| `OPTIONS *` | CORS preflight. |

Requests with an `Origin` header that is not allowed get `403`. Allowed:
the origins in `ALLOWED_ORIGINS` (comma-separated), plus any
`http(s)://localhost|127.0.0.1|[::1]:<port>` when `ALLOW_LOCALHOST` is
`"true"` (`npm run dev` sets it). Requests without `Origin` (not from a page)
are not restricted.

## WebSocket messages

All JSON text frames.

Server to client:

| Message | When |
| --- | --- |
| `{"type":"welcome","role":"host","room":R,"ice":{"iceServers":[...]}}` | First message to the host. |
| `{"type":"welcome","role":"peer","room":R,"peer":P,"ice":{"iceServers":[...]}}` | First message to a peer. |
| `{"type":"peer","peer":P}` | To the host: peer `P` arrived. |
| `{"type":"peer-left","peer":P}` | To the host: peer `P`'s socket closed (normally because its data channels opened). |
| `{"from":F,"msg":M}` | Forwarded message; `F` is a peer id, or `"host"` when received by a peer. |
| `{"type":"closed","reason":S}` | Just before the server closes the socket. Reasons: `host left`, `idle`, and on refusal `no such room`, `room already has a host`, `room full`. |
| `{"type":"error","reason":S}` | The last message was dropped: `message too large`, `rate limited`, `expected JSON text`, `expected {to, msg}`, `peers can only send to host`, `no such peer: P`. The socket stays open. |
| `{"type":"pong"}` | Reply to a ping. |

Client to server:

| Message | Meaning |
| --- | --- |
| `{"to":T,"msg":M}` | Forward `M` (an object, a `SignalMsg`: offer, answer, ice, bye) to `T`: a peer id from the host, `"host"` from a peer. |
| `{"type":"ping"}` | Keeps the room from expiring as idle. `signal-ws.ts` sends one from the host every 5 minutes. |

Close codes: `4000` refused (the `closed` message says why), `4001` room
closed (host left or idle).

ICE servers come in `welcome`, not from a separate endpoint, so TURN
credentials are only minted for sockets that are in a live room.

## Limits

- 16 peers per room (plus the host).
- 16 KB per client message.
- Rate limit per socket: bursts of 60 messages, 20 per second sustained; extra messages are dropped with an `error`.
- A room reserved by `POST /rooms` whose host never connects is dropped after 2 minutes.
- A room where nobody (host or peer) sent anything for 30 minutes is closed (`idle`). The host's ping prevents this while its page is open.
- When the host's socket closes, every peer gets `closed` / `host left`, the room is forgotten, and the id cannot be reused.

## ICE and TURN

Always: `stun:stun.cloudflare.com:3478` and `stun:stun.l.google.com:19302`.

With the secrets `TURN_KEY_ID` and `TURN_KEY_API_TOKEN` set, each `welcome`
also carries TURN credentials valid for 1 hour, minted by

```
POST https://rtc.live.cloudflare.com/v1/turn/keys/<TURN_KEY_ID>/credentials/generate-ice-servers
Authorization: Bearer <TURN_KEY_API_TOKEN>
Content-Type: application/json

{"ttl": 3600}
```

The Worker keeps only the entries with a username and credential, and drops
the port 53 URLs (browsers block that port, so they only delay ICE). The API
token never reaches a browser. If the secrets are missing or the call fails,
`welcome` has STUN only.

Cloudflare's docs say the TTL should exceed how long a client uses TURN, so a
game relayed through TURN for more than an hour may lose that connection.
If that matters, either raise `TURN_TTL_SECONDS` in `src/index.ts` or have
the page fetch fresh credentials and call `RTCPeerConnection.setConfiguration()`.

## Develop and test

```sh
cd signal
npm ci
npm run check   # TypeScript
npm test        # bundles the Worker and runs it in Miniflare (offline; TURN API mocked)
npm run e2e     # wrangler dev + two Chromium pages open a data channel via signal-ws.ts
npm run dev     # wrangler dev on http://localhost:8787 with localhost pages allowed
```

`npm run e2e` needs Playwright with Chromium (`npm i playwright` and
`npx playwright install chromium` on a machine without them).

## Deploy (first time)

1. Have a Cloudflare account (the free plan is enough, see below).
2. `cd signal && npm ci`
3. `npx wrangler login` (opens a browser to authorise wrangler).
4. Set the page origin in `wrangler.toml`, e.g.
   `ALLOWED_ORIGINS = "https://<user>.github.io"` (an origin has no path).
5. Create a TURN key in the Cloudflare dashboard (under **Realtime**, TURN;
   the menu names change from time to time). It shows a key ID and an API
   token; the token is shown once. Then:
   ```sh
   npx wrangler secret put TURN_KEY_ID          # paste the key ID
   npx wrangler secret put TURN_KEY_API_TOKEN   # paste the API token
   ```
   Skipping this step works too: the Worker then hands out STUN only, which
   fails for players behind symmetric NATs.
6. `npx wrangler deploy`. It prints the URL,
   `https://gta2-signal.<account-subdomain>.workers.dev`; that is the `base`
   for `hostRoom` / `joinRoom`.
7. Check: `curl -X POST https://gta2-signal.<sub>.workers.dev/rooms` returns `{"room":"..."}`.

Later deploys: `npx wrangler deploy`. Logs: `npx wrangler tail`.

## What the free tier covers

As of November 2026 (check Cloudflare's pricing pages before relying on it):

- **Workers**: 100,000 requests a day. Each `POST /rooms` and each WebSocket connect is one.
- **Durable Objects** (SQLite-backed, which is what `wrangler.toml` declares; the free plan has only those): 100,000 requests and 13,000 GB-s of duration a day. Incoming WebSocket messages count 20 to 1 as requests; outgoing messages are free. Hibernation means a room that is just waiting uses no duration. A join is roughly the connect plus a few dozen offer/answer/ICE messages, so thousands of joins a day fit.
- **TURN**: the first 1,000 GB of relayed traffic a month is free (shared with Cloudflare's SFU), then $0.05/GB. Only players whose direct connection fails use it.

Going over a free daily limit makes further requests fail until 00:00 UTC; nothing is billed on the free plan.
