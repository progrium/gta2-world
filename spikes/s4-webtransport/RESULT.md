# Spike S4 result

**Answer: yes for Chrome, measured; Firefox and Safari still to be measured.**

**Accepted (19 Nov 2026), with known caveats.** Jeff judged the spike results good enough to move on. No tester results were submitted for S4. The known caveat is that the pass criterion's public-host run in Firefox and Safari hasn't happened, because it needs a publicly reachable server. Until it does, WebTransport stays provisional and WebSocket is the fallback.
A Zig server speaks WebTransport to Chrome with no Rust, using ngtcp2 for
QUIC, GnuTLS for TLS and nghttp3 only for QPACK. It held one hour of
datagrams and a stream with no stalls. The pass criterion also covers Firefox
and Safari against a public server. That run needs a public host and real
browsers, and has not happened yet (see the README runbook).

Until that run: keep WebTransport as the provisional primary transport. If
Firefox or Safari fail it, they fall back to the WebSocket path, which the
same binary already serves.

## Findings

1. **ngtcp2 is enough for QUIC, and GnuTLS avoids a custom TLS build.**
   ngtcp2 1.26 supports DATAGRAM frames, and its GnuTLS crypto backend
   works with the stock Ubuntu 24.04 GnuTLS 3.8.3. No BoringSSL or quictls
   build was needed. The two C libraries build in about 20 s and link into
   Zig 0.17.0 through `addTranslateC` (`@cImport` is gone in 0.17).
2. **nghttp3 cannot do WebTransport by itself.** It cannot send the
   WebTransport SETTINGS and does not expose WebTransport stream types, so
   using its connection layer would mean patching it. Instead, a thin HTTP/3
   layer in Zig (about 300 lines in `src/quic.zig`) handles the control
   stream, SETTINGS, extended CONNECT and stream routing. nghttp3 is kept only
   for QPACK header decoding. This layer is small enough to own, and it is
   the piece the real server keeps.
3. **Self-signed certs work in Chrome** through `serverCertificateHashes`,
   with an ECDSA P-256 cert valid for 13 days. Production should use a
   CA-signed cert.
4. **Chrome tries `::1` first for `localhost`.** On a host without IPv6,
   use `127.0.0.1`.

## Local measurements (2026-11-19, headless Chromium 157, loopback)

Each tab sent 20 msgs/s on each lane: 200-byte datagrams, 64-byte messages
on one bidi stream, and 200-byte WebSocket messages. A stall is a gap of
more than 1 s with no echo.

| Run | Duration | Lane | Sent | Echoed | Lost | RTT p50 / p99 | Longest gap | Stalls | Reconnects |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 3 tabs, no loss | 60.5 min | datagrams | 72,594 per tab | all | 0 | 0.6 / 2.9 ms | 274 ms | 0 | 0 |
| | | stream | 72,594 per tab | all | 0 | 0.6 / 2.6 ms | 275 ms | 0 | 0 |
| | | WebSocket | 72,594 per tab | all | 0 | 0.7 / 2.7 ms | 266 ms | 0 | 0 |
| 1 tab, 2% UDP loss each way | 60.5 min | datagrams | 72,598 | 69,847 | 3.78% | 0.5 / 2.8 ms | 249 ms | 0 | 0 |
| | | stream | 72,598 | all | 0 | 0.5 / 4.2 ms | 234 ms | 0 | 0 |
| | | WebSocket (TCP, no loss) | 72,597 | all | 0 | 0.7 / 2.9 ms | 235 ms | 0 | 0 |

- Server memory stayed flat at 7.5 MB RSS for the whole hour, and CPU was
  1.4% of one core for 3 clients.
- Uni stream echo and 5% loss runs (about 9.7% datagram loss, all stream
  data delivered) also passed in short runs.
- The longest gaps, around 250 ms, appear in every lane including
  WebSocket, so they come from the shared headless browser or VM scheduling,
  not from QUIC.
- Raw output is in `results/2026-11-19-local/`.

Loopback does not test real-world paths, NAT rebinding, or Firefox and
Safari. Those come from the public run.

## Still to do for a final yes or no

- [ ] Public host with a domain and a Let's Encrypt cert (README steps 1–4).
- [ ] One hour each in Chrome, Firefox and Safari from real networks (steps 5–6).
- [ ] Add `reports.log` results here and update the answer line.
