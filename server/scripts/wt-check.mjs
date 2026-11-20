// End-to-end check of the WebTransport path in headless Chromium.
//
//   node scripts/wt-check.mjs MAP_SHA256_HEX [seconds] [session] [base]
//
// Opens the server's HTTP origin (a secure context on 127.0.0.1), then in
// the page: WebTransport to /s/<session> with the dev cert hash from
// /config, I3 hello on the bidi stream, welcome + baseline, then 30 Hz input
// datagrams with acks and 8-frame redundancy for `seconds`. Prints what the
// page saw and exits nonzero if no snapshots arrived over datagrams.
// Needs playwright (preinstalled here; elsewhere `npm i playwright`).
import { createRequire } from 'node:module';
const { chromium } = createRequire(import.meta.url)('playwright');

const [mapHash, secs = '10', session = 'wtcheck', base = 'http://127.0.0.1:8080'] = process.argv.slice(2);
if (!/^[0-9a-f]{64}$/.test(mapHash || '')) {
  console.error('usage: node scripts/wt-check.mjs MAP_SHA256_HEX [seconds] [session] [base]');
  process.exit(2);
}

const browser = await chromium.launch();
const page = await browser.newPage();
page.on('console', (m) => console.log('page:', m.text()));
await page.goto(`${base}/healthz`);
const result = await page.evaluate(async ({ mapHash, secs, session }) => {
  const cfg = await (await fetch('/config')).json();
  const url = `https://127.0.0.1:${cfg.wtPort}/s/${session}`;
  const opts = cfg.certHash ? { serverCertificateHashes: [{ algorithm: 'sha-256', value: Uint8Array.from(atob(cfg.certHash), (c) => c.charCodeAt(0)) }] } : {};
  const wt = new WebTransport(url, opts);
  await wt.ready;
  const stream = await wt.createBidirectionalStream();
  const sw = stream.writable.getWriter();
  const dw = wt.datagrams.writable.getWriter();

  // --- I3 encoding helpers
  const uvarint = (n) => { const out = []; do { let b = n & 0x7f; n = Math.floor(n / 128); if (n) b |= 0x80; out.push(b); } while (n); return out; };
  const hex = (h) => h.match(/../g).map((x) => parseInt(x, 16));
  const frameOut = (body) => new Uint8Array([...uvarint(body.length), ...body]);
  const layout = BigInt('0x' + cfg.layoutHash);
  const hello = [];
  const dv8 = new DataView(new ArrayBuffer(8));
  hello.push(0x01);
  dv8.setUint32(0, 0x31573247, true); hello.push(...new Uint8Array(dv8.buffer, 0, 4));
  hello.push(cfg.protocol & 0xff, cfg.protocol >> 8, cfg.abi & 0xff, cfg.abi >> 8);
  dv8.setBigUint64(0, layout, true); hello.push(...new Uint8Array(dv8.buffer));
  hello.push(...hex(mapHash));
  hello.push(...new Array(16).fill(0));
  hello.push(0); // transport: webtransport
  const name = new TextEncoder().encode('wt-check');
  hello.push(1, ...uvarint(name.length), ...name);
  await sw.write(frameOut(hello));

  // --- state
  const st = { welcome: null, baseline: false, reject: null, snapshots: 0, bytes: 0, infos: 0, events: 0, inputs: 0, rttMs: [], slack: null, inputAck: null };
  let ackSeq = 0, ackBits = 0, tick = 0, firstTick = 0, nextGen = 0, buffer = 2;
  const frames = new Map();
  const t0 = performance.now();
  const now16 = () => Math.floor(performance.now() - t0) & 0xffff;
  const ack = (seq) => {
    if (ackBits === 0) { ackSeq = seq; ackBits = 1; return; }
    const d = (seq - ackSeq) & 0xffff;
    if (d === 0 || d >= 0x8000) return;
    ackBits = d >= 32 ? 1 : ((ackBits << d) | 1) >>> 0;
    ackSeq = seq;
  };
  const onSnapHeader = (b, isBaseline) => {
    const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
    const seq = v.getUint16(1, true), stick = v.getUint32(3, true), echo = v.getUint16(7, true), hold = v.getUint16(9, true);
    const n = v.getUint8(11);
    for (let i = 0; i < n; i++) { st.inputAck = v.getUint32(13 + i * 6, true); st.slack = v.getInt8(17 + i * 6); }
    ack(seq);
    if (!isBaseline && echo) st.rttMs.push(((now16() - echo - hold) & 0xffff));
    if (!isBaseline && st.slack !== null) {
      if (st.slack < buffer * 4 - 2) tick++; else if (st.slack > buffer * 4 + 6) tick--;
      if (tick - stick < 1) tick = stick + buffer;
    }
  };

  // --- reliable stream reader
  (async () => {
    const r = stream.readable.getReader();
    let buf = new Uint8Array(0);
    for (;;) {
      const { value, done } = await r.read();
      if (done) return;
      const nb = new Uint8Array(buf.length + value.length); nb.set(buf); nb.set(value, buf.length); buf = nb;
      for (;;) {
        let len = 0, shift = 0, i = 0;
        for (; i < buf.length && i < 10; i++) { len += (buf[i] & 0x7f) * 2 ** shift; shift += 7; if (!(buf[i] & 0x80)) break; }
        if (i >= buf.length || buf.length < i + 1 + len) break;
        const body = buf.subarray(i + 1, i + 1 + len);
        buf = buf.slice(i + 1 + len);
        const v = new DataView(body.buffer, body.byteOffset, body.byteLength);
        switch (body[0]) {
          case 0x02: st.welcome = { clientId: v.getUint32(3, true), serverTick: v.getUint32(23, true), slots: [body[body.length - 1]] }; tick = st.welcome.serverTick + 3; firstTick = nextGen = tick; buffer = body[29]; break;
          case 0x03: st.reject = new TextDecoder().decode(body.subarray(3)); break;
          case 0x04: st.baseline = true; onSnapHeader(body, true); break;
          case 0x0b: st.infos++; break;
          case 0x0a: st.events++; break;
        }
      }
    }
  })();
  // --- datagram reader
  (async () => {
    const r = wt.datagrams.readable.getReader();
    for (;;) {
      const { value, done } = await r.read();
      if (done) return;
      if (value[0] !== 0x20) continue;
      st.snapshots++; st.bytes += value.length;
      onSnapHeader(value, false);
    }
  })();

  // --- 30 Hz input
  const sendInput = () => {
    if (!st.baseline || !st.welcome) return;
    const t = tick++;
    for (; nextGen <= t; nextGen++) frames.set(nextGen, { steer: ((nextGen * 7) % 81) - 40, throttle: 100, seq: nextGen & 0xffff });
    const since = st.inputAck === null ? 8 : t - st.inputAck;
    const count = Math.max(1, Math.min(8, since, t - firstTick + 1));
    const out = new Uint8Array(10 + 6 + count * 8);
    const v = new DataView(out.buffer);
    v.setUint8(0, 0x10); v.setUint16(1, ackSeq, true); v.setUint32(3, ackBits, true); v.setUint16(7, now16(), true); v.setUint8(9, 1);
    v.setUint8(10, st.welcome.slots[0]); v.setUint32(11, t, true); v.setUint8(15, count);
    for (let k = 0; k < count; k++) {
      const f = frames.get(t - count + 1 + k);
      const o = 16 + k * 8;
      v.setInt8(o, f.steer); v.setInt8(o + 1, f.throttle); v.setUint16(o + 2, 0, true); v.setUint16(o + 4, 0, true); v.setUint16(o + 6, f.seq, true);
    }
    dw.write(out);
    st.inputs++;
  };
  const iv = setInterval(sendInput, 1000 / 30);
  await new Promise((res) => setTimeout(res, secs * 1000));
  clearInterval(iv);
  await sw.write(frameOut([0x0c, 0])); // bye
  wt.close();
  const rtt = st.rttMs.sort((a, b) => a - b);
  return { ...st, rttMs: undefined, rttP50: rtt[Math.floor(rtt.length / 2)], rttP99: rtt[Math.floor(rtt.length * 0.99)], lag: tick - st.inputAck };
}, { mapHash, secs: Number(secs), session });
console.log(JSON.stringify(result, null, 1));
await browser.close();
process.exit(result.welcome && result.baseline && result.snapshots > 0 && !result.reject ? 0 : 1);
