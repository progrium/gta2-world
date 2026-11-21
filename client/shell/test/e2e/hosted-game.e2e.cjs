const { chromium } = require('playwright');
const http = require('http'), fs = require('fs'), path = require('path');
// Two browser profiles play a real game: A hosts (files shared), B joins by link
// through a local signalling Worker, so the files must transfer over WebRTC.
// Usage: client/build-web.sh /tmp/webout; (cd signal && npm run dev) &
//   GTA2_DATA=~/gta2/data node client/shell/test/e2e/hosted-game.e2e.cjs
// Needs your own wil.gmp and wil.sty in GTA2_DATA (nyc.gci too, if there, for
// car handling); nothing is copied into the repo.
const root = process.env.WEB_OUT || '/tmp/webout';
const data = process.env.GTA2_DATA; if (!data) { console.error('set GTA2_DATA'); process.exit(2); }
const signal = process.env.SIGNAL || 'ws://127.0.0.1:8787';
const types = { '.html':'text/html', '.js':'text/javascript', '.wasm':'application/wasm', '.css':'text/css', '.map':'application/json' };
const srv = http.createServer((q, r) => { let p = path.join(root, decodeURIComponent(q.url.split('?')[0])); if (p.endsWith('/')) p += 'index.html';
  fs.readFile(p, (e, b) => { if (e) { r.writeHead(404); r.end(); return; } r.writeHead(200, {'content-type': types[path.extname(p)] || 'application/octet-stream', 'cross-origin-opener-policy':'same-origin','cross-origin-embedder-policy':'require-corp'}); r.end(b); }); });
srv.listen(0, '127.0.0.1', async () => {
  const base = `http://127.0.0.1:${srv.address().port}`;
  const br = await chromium.launch({ args: ['--use-gl=swiftshader','--enable-unsafe-swiftshader','--disable-features=WebRtcHideLocalIpsWithMdns'] });
  const ca = await br.newContext(), cb = await br.newContext();
  const ua = await ca.newPage(); let hostCars = null, carsB = null;
  ua.on('console', m => { const t = m.text(); const c = /^\[host\] \d+ car models \(hash (\w+)\)/.exec(t); if (c) hostCars = c[1]; m.type()!=='debug' && console.log('[A]', t.slice(0,200)); }); ua.on('pageerror', e=>console.log('[A] ERR', e.message));
  await ua.goto(`${base}/index.html?signal=${signal}`);
  const gci = fs.existsSync(path.join(data,'nyc.gci')) ? [path.join(data,'nyc.gci')] : [];
  await ua.locator('input[type=file][accept]').setInputFiles([path.join(data,'wil.gmp'),path.join(data,'wil.sty'),...gci]);
  await ua.locator('button.host-game').click();
  const opts = await ua.locator('select.mapsel option').allTextContents(); console.log('maps', opts);
  await ua.locator('select.mapsel').selectOption({ index: 0 });
  await ua.locator('input.share').check();
  await ua.locator('button.start').click();
  const link = await ua.locator('input.joinlink').inputValue({ timeout: 20000 });
  console.log('link', link);
  const ub = await cb.newPage(); ub.on('console', m => { const t = m.text(); const c = /^\[cars\] \d+ models \(hash (\w+)\)/.exec(t); if (c) carsB = c[1]; m.type()!=='debug' && console.log('[B]', t.slice(0,200)); }); ub.on('pageerror', e=>console.log('[B] ERR', e.message));
  const t0 = Date.now();
  await ub.goto(link);
  await ua.locator('button.play').click();
  const netA = () => ua.evaluate(() => document.querySelector('.hudtop')?.textContent ?? '');
  const netB = () => ub.evaluate(() => (document.querySelector('.hudtop')?.textContent ?? '') + ' | ' + (document.querySelector('.join-status')?.textContent ?? ''));
  for (let i = 0; i < 12; i++) { await ua.waitForTimeout(2500); console.log(`t=${((Date.now()-t0)/1000).toFixed(1)}s A:`, (await netA()).slice(0,160)); console.log('   B:', (await netB()).slice(0,200)); }
  await ub.keyboard.down('ArrowUp'); await ua.waitForTimeout(3000); await ub.keyboard.up('ArrowUp');
  console.log('after driving B:', (await netB()).slice(0,200));
  // Both players must build the host's car models (the Worker's are logged as [host] N car models).
  const hashes = [hostCars, carsB]; console.log('car model hashes host/B:', hashes);
  const ok = /webrtc · rtt \d+ ms/.test(await ub.evaluate(() => document.body.textContent)) && hashes[0] !== null && hashes[0] === hashes[1]; console.log(ok ? 'PASS: joiner is in the game over WebRTC with the host\'s car models' : 'FAIL'); process.exitCode = ok ? 0 : 1;
  await br.close(); srv.close();
});
