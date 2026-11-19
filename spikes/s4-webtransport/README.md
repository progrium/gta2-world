# Spike S4: WebTransport from Zig

**Question:** can a Zig server speak WebTransport to browsers without Rust?

**Passes when:** Chrome, Firefox and Safari exchange datagrams with a public
server for one hour without stalls.

See [RESULT.md](RESULT.md) for the written answer.

## What is here

One single-threaded Zig 0.17.0 binary, `s4-server`, that serves:

| Port | Protocol | What |
| --- | --- | --- |
| UDP `--port` (4433) | QUIC + HTTP/3 + WebTransport | Echoes datagrams, bidi streams and uni streams on any path |
| TCP `--http-port` (8080) | HTTP/1.1, optionally TLS | `/` test page, `/config`, `POST /report`, `/ws` WebSocket echo |

```
src/main.zig   args, poll loop, cert hash
src/quic.zig   ngtcp2 connection handling, thin HTTP/3 + WebTransport layer
src/tcp.zig    HTTP/1.1, WebSocket echo, optional GnuTLS
src/util.zig   clock, QUIC varints, QPACK integers
web/index.html soak test page (embedded into the binary)
scripts/       dependency build, cert generation, headless Chromium soak
```

### Libraries

- **ngtcp2 1.26.0** does all of QUIC, including DATAGRAM frames (RFC 9221).
- **ngtcp2_crypto_gnutls** + **GnuTLS 3.8** do TLS 1.3. The system OpenSSL
  3.0 has no QUIC API, and GnuTLS is packaged everywhere, so no
  BoringSSL/quictls build is needed.
- **nghttp3 1.19.0** is used only for its QPACK decoder.

nghttp3's connection layer cannot carry WebTransport: it has no way to send
the WebTransport SETTINGS (`SETTINGS_WT_MAX_SESSIONS` and the older draft
identifiers) and it does not hand WebTransport streams (bidi signal `0x41`,
uni type `0x54`) to the application. So `quic.zig` implements the small part
of HTTP/3 that WebTransport needs directly on ngtcp2 streams:

- server control stream with SETTINGS (`ENABLE_CONNECT_PROTOCOL`,
  `H3_DATAGRAM`, `ENABLE_WEBTRANSPORT`, `WT_MAX_SESSIONS`, and their draft
  variants);
- request streams: HEADERS decoded with nghttp3's QPACK decoder, extended
  CONNECT with `:protocol = webtransport` answered with `:status 200`
  (static-table QPACK, no dynamic table);
- client bidi streams starting with `0x41` and uni streams starting with
  `0x54` routed to the echo;
- HTTP datagrams (quarter stream ID + payload) echoed back unchanged.

That layer is about 300 lines. The real game server would keep it and replace
the echo with the I3 framing.

## Build

Needs Zig 0.17.0, cmake, a C compiler, pkg-config, git and GnuTLS dev
headers (`apt install libgnutls28-dev`, or `brew install gnutls`).

```sh
cd spikes/s4-webtransport
scripts/build-deps.sh                 # clones and builds ngtcp2 + nghttp3 into deps/out (~20 s)
zig build -Doptimize=ReleaseSafe      # -> zig-out/bin/s4-server
zig build test
```

## Run locally (self-signed)

```sh
scripts/gen-cert.sh certs             # ECDSA P-256, 13 days, prints its SHA-256
zig-out/bin/s4-server --cert certs/cert.pem --key certs/key.pem
# open http://127.0.0.1:8080/ in Chrome and press Start
```

Self-signed certs work through `serverCertificateHashes`, which only accepts
ECDSA certs valid for at most 14 days; `gen-cert.sh` makes exactly that, and
the page reads the hash from `/config`. Use `127.0.0.1`, not `localhost`, if
the host has no IPv6, because Chrome tries `::1` first for WebTransport.

Headless check (needs `npm i playwright`):

```sh
node scripts/soak-chromium.js 60 3    # 60 s, 3 tabs, plus a uni-stream probe
```

`--loss 5` makes the server drop 5% of UDP packets each way, to see datagram
loss and stream head-of-line delay without `tc netem`.

## The one-hour public soak

This is the actual pass criterion. It needs a public host because Firefox and
Safari have to reach it from real machines.

### 1. Host

- Any Linux VM with a public IPv4 address. 1 vCPU is plenty.
- A DNS name pointing at it, for example `s4.example.com`.
- Firewall: **UDP 443** and **TCP 443** open (TCP 80 too, for certbot).

### 2. Build on the host

```sh
sudo apt install -y git cmake build-essential pkg-config libgnutls28-dev certbot
curl -LO https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz
sudo tar xf zig-x86_64-linux-0.17.0.tar.xz -C /opt && sudo ln -sf /opt/zig-x86_64-linux-0.17.0/zig /usr/local/bin/zig
git clone -b spike/s4 https://github.com/progrium/gta2-world && cd gta2-world/spikes/s4-webtransport
scripts/build-deps.sh && zig build -Doptimize=ReleaseSafe
```

(Use `zig-aarch64-linux-0.17.0.tar.xz` on ARM.)

### 3. Certificate

```sh
sudo certbot certonly --standalone -d s4.example.com
```

A CA-signed cert is the clean path: every browser accepts it with no
`serverCertificateHashes`. If there is no domain, `scripts/gen-cert.sh certs
<public-ip>` plus `--tls-http` still works in Chrome after clicking through
the page's certificate warning, but Firefox and Safari support for cert
hashes is not something to rely on.

### 4. Run

```sh
sudo zig-out/bin/s4-server \
  --cert /etc/letsencrypt/live/s4.example.com/fullchain.pem \
  --key  /etc/letsencrypt/live/s4.example.com/privkey.pem \
  --port 443 --http-port 443 --tls-http --no-cert-hash \
  --report reports.log 2> server.log
```

UDP 443 and TCP 443 are separate sockets, so both can use 443. The server
logs a stats line every 30 s.

### 5. Browsers

On machines on ordinary home or office networks (not the same LAN as the
server), open `https://s4.example.com/` in:

- Chrome (current stable)
- Firefox (current stable)
- Safari (latest macOS or iOS; the page header says "WebTransport NOT available" if this Safari lacks it, which is itself a result)

Leave the defaults (20 messages/s per transport, 200-byte datagrams, 60
minutes, 1000 ms stall threshold) and press **Start** in each.

**Keep every tab visible and the machine awake for the full hour.** Hidden
tabs get their timers throttled, which looks exactly like a stall; the page
detects this and marks the run INVALID. On macOS, `caffeinate -d` keeps the
display awake.

### 6. Read the result

After 60 minutes each page shows **PASS**, **FAIL** or **INVALID**, and
posts a final report. `reports.log` on the server has one JSON line per
browser per minute (sent, echoed, loss, RTT p50/p99, longest gap, stalls,
reconnects for each of WebTransport datagrams, WebTransport stream and
WebSocket). Send `reports.log` and `server.log` back and they go into
RESULT.md.

A **stall** is any gap of more than 1000 ms with no echo while sending at
20 Hz. A browser passes when its WebTransport datagram and stream lanes have
zero stalls and zero reconnects over the hour. WebSocket numbers are recorded
for comparison but do not affect the verdict.

## Known limits (spike code)

- No Retry / address validation, no 0-RTT, no session tickets.
- Single thread, one packet per `sendto`, no GSO; fine for an echo soak.
- The WebTransport session close capsule is not parsed; a FIN on the CONNECT
  stream ends the session.
- Peer SETTINGS are not checked; the server assumes the browser speaks
  WebTransport if it sends extended CONNECT.
