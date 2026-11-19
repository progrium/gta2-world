// Headless Chromium soak: node scripts/soak-chromium.js SECONDS TABS [base-url]
// Needs playwright (npm i playwright) and a running s4-server.
const { chromium } = require('playwright');
(async () => {
  const secs = +(process.argv[2] || 15), tabs = +(process.argv[3] || 1);
  const base = process.argv[4] || 'http://127.0.0.1:8080';
  const b = await chromium.launch();
  const ctxOpts = { ignoreHTTPSErrors: true };
  const pages = [];
  for (let i = 0; i < tabs; i++) {
    const ctx = await b.newContext(ctxOpts);
    const p = await ctx.newPage();
    p.on('pageerror', e => console.log('pageerror', e));
    await p.goto(`${base}/?autostart=1&dur=${Math.ceil(secs / 60)}`);
    pages.push(p);
  }
  // Uni-stream probe on the first tab.
  const uni = await pages[0].evaluate(async () => {
    const c = await (await fetch('/config')).json();
    const raw = Uint8Array.from(atob(c.certHash), ch => ch.charCodeAt(0));
    const wt = new WebTransport(`https://${location.hostname}:${c.wtPort}/uni`, { serverCertificateHashes: [{ algorithm: 'sha-256', value: raw }] });
    await wt.ready;
    const s = await wt.createUnidirectionalStream();
    const w = s.getWriter(); await w.write(new TextEncoder().encode('hello uni')); await w.close();
    const r = wt.incomingUnidirectionalStreams.getReader();
    const { value: inc } = await r.read();
    let out = ''; const rr = inc.getReader();
    for (;;) { const { value, done } = await rr.read(); if (done) break; out += new TextDecoder().decode(value); }
    wt.close(); return out;
  }).catch(e => 'ERR ' + e);
  console.log('uni echo:', JSON.stringify(uni));
  const t0 = Date.now();
  while (Date.now() - t0 < secs * 1000) await new Promise(r => setTimeout(r, 5000));
  for (const [i, p] of pages.entries()) {
    const s = await p.evaluate(() => window.__s4.summary());
    for (const [k, v] of Object.entries(s.transports))
      console.log(`tab${i} ${k.padEnd(6)} sent=${v.sent} recv=${v.recv} lost=${v.lost} (${v.lossPct}%) rtt p50=${v.rttP50?.toFixed(1)} p99=${v.rttP99?.toFixed(1)} maxGap=${v.maxGapMs} stalls=${v.stalls} connects=${v.connects} drops=${v.disconnects} err=${v.lastError}`);
    console.log(`tab${i} verdict: ${await p.evaluate(() => document.getElementById('verdict').textContent)}`);
  }
  await b.close();
})();
