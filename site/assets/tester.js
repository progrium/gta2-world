// Tester guide drawer shared by every spike page.
//
// A page sets window.TESTER = { spike, title, ... } and then loads this file.
// It adds a "Tester guide" panel with the instructions, a short form, and a
// Download button that saves the answers plus whatever the page measured
// (config.collect()) as a JSON file the tester sends back to Jeff.
//
// Config:
//   spike      "s1" .. "s6"
//   title      shown at the top of the panel
//   time       rough time needed, e.g. "15 minutes"
//   needs      HTML: what the tester needs before starting
//   steps      array of HTML strings, shown as a numbered list
//   fields     array of { id, label, type: text|textarea|select|radio, options, help, placeholder }
//   collect    () => object with the page's own measurements (optional)
//   summary    () => short text shown above the Download button (optional)
//   download   false to hide the panel's own Download button (the page has its own)
//   sendNote   HTML shown next to the Download button
//   push       false for full-screen canvas pages; otherwise the page is narrowed
//              so the open guide does not cover it on wide screens
(function () {
  const cfg = window.TESTER;
  if (!cfg) return;
  const KEY = "gta2-tester:" + cfg.spike;
  const NAME_KEY = "gta2-tester:name";
  const OPEN_KEY = "gta2-tester:open:" + cfg.spike;

  const store = {
    get(k, d) { try { const v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch { return d; } },
    set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} },
  };

  function browserName() {
    const ua = navigator.userAgent;
    let m;
    if ((m = ua.match(/Edg\/(\d+)/))) return "Edge " + m[1];
    if ((m = ua.match(/Firefox\/(\d+)/))) return "Firefox " + m[1];
    if ((m = ua.match(/Chrome\/(\d+)/))) return "Chrome " + m[1];
    if ((m = ua.match(/Version\/([\d.]+).*Safari/))) return "Safari " + m[1];
    return "Unknown browser";
  }
  function osName() {
    const ua = navigator.userAgent;
    if (/Windows NT/.test(ua)) return "Windows";
    if (/iPhone|iPad/.test(ua)) return "iOS";
    if (/Mac OS X/.test(ua)) return navigator.maxTouchPoints > 1 ? "iPadOS" : "macOS";
    if (/Android/.test(ua)) return "Android";
    if (/CrOS/.test(ua)) return "ChromeOS";
    if (/Linux/.test(ua)) return "Linux";
    return "Unknown OS";
  }
  function gpuName() {
    try {
      const c = document.createElement("canvas");
      const gl = c.getContext("webgl2") || c.getContext("webgl");
      if (!gl) return "no WebGL";
      const ext = gl.getExtension("WEBGL_debug_renderer_info");
      return ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
    } catch { return "unknown"; }
  }
  function environment() {
    return {
      browser: browserName(), os: osName(), userAgent: navigator.userAgent,
      platform: navigator.userAgentData?.platform || navigator.platform || "",
      gpu: gpuName(), cores: navigator.hardwareConcurrency || null,
      screen: `${screen.width}x${screen.height} @${devicePixelRatio}x`,
      viewport: `${innerWidth}x${innerHeight}`, language: navigator.language,
      page: location.href.split("?")[0],
    };
  }

  const css = `
#tg-root, #tg-root * { box-sizing: border-box; }
#tg-root { --tg-bg:#fbfaf7; --tg-fg:#1c1d1f; --tg-muted:#5d6268; --tg-line:rgba(0,0,0,.13); --tg-accent:#b8432f; --tg-field:#fff; --tg-ok:#1d7a3a;
  position: fixed; top: 0; right: 0; bottom: 0; width: 380px; max-width: 100vw; z-index: 2147483000;
  background: var(--tg-bg); color: var(--tg-fg); border-left: 1px solid var(--tg-line);
  font: 14px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; text-align: left;
  display: flex; flex-direction: column; box-shadow: -8px 0 24px rgba(0,0,0,.18); }
@media (prefers-color-scheme: dark) { #tg-root, #tg-open { --tg-bg:#1b1d20; --tg-fg:#e9e8e4; --tg-muted:#a3a8ae; --tg-line:rgba(255,255,255,.14); --tg-accent:#ff7b66; --tg-field:#26292d; --tg-ok:#5fd08a; } }
#tg-root[hidden] { display: none; }
#tg-root header { padding: 14px 16px 10px; border-bottom: 1px solid var(--tg-line); display: flex; gap: 8px; align-items: flex-start; }
#tg-root header .tg-t { flex: 1; min-width: 0; }
#tg-root .tg-kicker { font-size: 11px; letter-spacing: .06em; text-transform: uppercase; color: var(--tg-muted); }
#tg-root .tg-kicker a { color: inherit; }
#tg-root h2 { font-size: 17px; margin: 2px 0 0; line-height: 1.25; font-weight: 650; text-transform: none; letter-spacing: 0; color: var(--tg-fg); }
#tg-root h3 { font-size: 12px; letter-spacing: .05em; text-transform: uppercase; color: var(--tg-muted); margin: 18px 0 6px; font-weight: 600; }
#tg-root .tg-body { overflow: auto; padding: 4px 16px 18px; flex: 1; }
#tg-root p { margin: 6px 0; color: inherit; max-width: none; }
#tg-root ol { margin: 4px 0; padding-left: 22px; }
#tg-root li { margin: 6px 0; }
#tg-root code, #tg-root kbd { font: 12px ui-monospace, Menlo, monospace; background: var(--tg-field); border: 1px solid var(--tg-line); border-radius: 4px; padding: 0 4px; }
#tg-root .tg-muted { color: var(--tg-muted); font-size: 13px; }
#tg-root .tg-needs { background: var(--tg-field); border: 1px solid var(--tg-line); border-radius: 8px; padding: 8px 10px; margin: 10px 0 0; font-size: 13px; }
#tg-root label.tg-l { display: block; font-size: 13px; font-weight: 550; margin: 10px 0 3px; }
#tg-root .tg-help { font-size: 12px; color: var(--tg-muted); margin: 0 0 3px; }
#tg-root input[type=text], #tg-root textarea, #tg-root select {
  width: 100%; font: inherit; font-size: 14px; color: var(--tg-fg); background: var(--tg-field);
  border: 1px solid var(--tg-line); border-radius: 6px; padding: 6px 8px; margin: 0; }
#tg-root textarea { min-height: 64px; resize: vertical; }
#tg-root .tg-radios { display: flex; flex-wrap: wrap; gap: 4px 14px; }
#tg-root .tg-radios label { font-weight: 400; display: inline-flex; gap: 5px; align-items: center; font-size: 14px; }
#tg-root button { font: inherit; font-size: 14px; color: var(--tg-fg); background: var(--tg-field); border: 1px solid var(--tg-line);
  border-radius: 7px; padding: 6px 12px; cursor: pointer; }
#tg-root button.tg-primary { background: var(--tg-accent); border-color: var(--tg-accent); color: #fff; font-weight: 600; }
#tg-root .tg-x { padding: 2px 9px; font-size: 18px; line-height: 1.2; }
#tg-root .tg-send { border-top: 1px solid var(--tg-line); padding: 12px 16px 14px; background: var(--tg-bg); }
#tg-root .tg-summary { font: 12px/1.45 ui-monospace, Menlo, monospace; white-space: pre-wrap; margin: 0 0 8px; color: var(--tg-muted); max-height: 9em; overflow: auto; }
#tg-root .tg-row { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
#tg-root .tg-status { font-size: 12px; color: var(--tg-ok); }
#tg-root details { margin-top: 12px; font-size: 13px; }
#tg-root details pre { font: 11px ui-monospace, Menlo, monospace; white-space: pre-wrap; word-break: break-all; }
#tg-open { position: fixed; right: 14px; bottom: 14px; z-index: 2147483000; font: 600 14px system-ui, sans-serif;
  background: #b8432f; color: #fff; border: 0; border-radius: 999px; padding: 9px 16px; cursor: pointer; box-shadow: 0 4px 14px rgba(0,0,0,.3); }
#tg-open[hidden] { display: none; }
@media (max-width: 520px) { #tg-root { width: 100vw; } }
@media (min-width: 1000px) { html.tg-push { padding-right: 380px; } }
`;
  const style = document.createElement("style");
  style.textContent = css;
  document.head.appendChild(style);

  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const saved = store.get(KEY, {});
  if (!saved.name) saved.name = store.get(NAME_KEY, "");

  const common = [
    { id: "name", label: "Your name", type: "text", placeholder: "So Jeff knows who sent it" },
    { id: "machine", label: "Computer", type: "text", placeholder: "e.g. 2021 MacBook Pro M1, Windows desktop RTX 3060", help: `Detected: ${esc(osName())}, ${esc(browserName())}` },
  ];
  const fields = cfg.download === false ? [] : common.concat(cfg.fields || []);

  function fieldHtml(f) {
    const v = saved[f.id] ?? "";
    const help = f.help ? `<div class="tg-help">${f.help}</div>` : "";
    const ph = f.placeholder ? ` placeholder="${esc(f.placeholder)}"` : "";
    if (f.type === "textarea") return `<label class="tg-l" for="tg-${f.id}">${f.label}</label>${help}<textarea id="tg-${f.id}" data-f="${f.id}"${ph}>${esc(v)}</textarea>`;
    if (f.type === "select") return `<label class="tg-l" for="tg-${f.id}">${f.label}</label>${help}<select id="tg-${f.id}" data-f="${f.id}"><option value="">Choose…</option>${f.options.map((o) => `<option${o === v ? " selected" : ""}>${esc(o)}</option>`).join("")}</select>`;
    if (f.type === "radio") return `<label class="tg-l">${f.label}</label>${help}<div class="tg-radios">${f.options.map((o) => `<label><input type="radio" name="tg-${f.id}" data-f="${f.id}" value="${esc(o)}"${o === v ? " checked" : ""}> ${esc(o)}</label>`).join("")}</div>`;
    return `<label class="tg-l" for="tg-${f.id}">${f.label}</label>${help}<input type="text" id="tg-${f.id}" data-f="${f.id}" value="${esc(v)}"${ph}>`;
  }
  function groupHtml(list) {
    let out = "";
    for (const f of list) out += f.heading ? `<h3>${f.heading}</h3>` : fieldHtml(f);
    return out;
  }

  const root = document.createElement("aside");
  root.id = "tg-root";
  root.setAttribute("aria-label", "Tester guide");
  root.innerHTML = `
<header><div class="tg-t"><div class="tg-kicker"><a href="../">gta2-world tests</a> · spike ${esc(cfg.spike.toUpperCase())}${cfg.time ? " · about " + esc(cfg.time) : ""}</div>
<h2>${cfg.title}</h2></div><button class="tg-x" title="Hide the guide" aria-label="Hide the guide">×</button></header>
<div class="tg-body">
  ${cfg.intro ? `<p>${cfg.intro}</p>` : ""}
  ${cfg.needs ? `<div class="tg-needs"><b>You need:</b> ${cfg.needs}</div>` : ""}
  <h3>Steps</h3>
  <ol>${(cfg.steps || []).map((s) => `<li>${s}</li>`).join("")}</ol>
  ${fields.length ? `<h3>Your answers</h3><form autocomplete="off" onsubmit="return false">${groupHtml(fields)}</form>` : ""}
  ${cfg.download === false ? "" : `<details><summary>What the file will contain</summary><pre class="tg-preview"></pre></details>`}
</div>
${cfg.download === false ? (cfg.sendNote ? `<div class="tg-send"><p class="tg-muted" style="margin:0">${cfg.sendNote}</p></div>` : "") : `
<div class="tg-send">
  <div class="tg-summary" hidden></div>
  <div class="tg-row"><button class="tg-primary tg-dl">Download results</button><span class="tg-status"></span></div>
  <p class="tg-muted" style="margin:8px 0 0">${cfg.sendNote || "Send the downloaded file back to Jeff. Your answers are kept in this browser until you clear them, so you can come back and add to them."}</p>
  <p class="tg-muted" style="margin:4px 0 0"><a href="#" class="tg-clear" style="color:inherit">Clear my answers on this page</a></p>
</div>`}`;
  const openBtn = document.createElement("button");
  openBtn.id = "tg-open";
  openBtn.textContent = "Tester guide";

  // Keep typing in the guide from driving the car or flying the camera.
  for (const t of ["keydown", "keyup", "keypress"]) root.addEventListener(t, (e) => e.stopPropagation());

  const values = () => {
    const out = {};
    for (const f of fields) {
      if (f.heading) continue;
      if (f.type === "radio") { const c = root.querySelector(`input[name="tg-${f.id}"]:checked`); out[f.id] = c ? c.value : ""; }
      else { const el = root.querySelector(`[data-f="${f.id}"]`); out[f.id] = el ? el.value.trim() : ""; }
    }
    return out;
  };
  const report = () => ({
    spike: cfg.spike, page: cfg.title, savedAt: new Date().toISOString(),
    tester: values(), environment: environment(),
    results: cfg.collect ? cfg.collect() : null,
  });
  const persist = () => { const v = values(); store.set(KEY, v); if (v.name) store.set(NAME_KEY, v.name); refresh(); };
  root.addEventListener("input", persist);
  root.addEventListener("change", persist);

  const slug = (x) => (x || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
  function download() {
    const r = report();
    const d = new Date(), p = (n) => String(n).padStart(2, "0");
    const stamp = `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}`;
    const name = ["gta2", cfg.spike, slug(r.tester.name) || "tester", slug(browserName().split(" ")[0]), stamp].join("-") + ".json";
    const blob = new Blob([JSON.stringify(r, null, 2)], { type: "application/json" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob); a.download = name;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 5000);
    root.querySelector(".tg-status").textContent = "Saved " + name;
  }
  function refresh() {
    const sum = root.querySelector(".tg-summary");
    if (sum && cfg.summary) { const s = cfg.summary(); sum.hidden = !s; sum.textContent = s || ""; }
    const pre = root.querySelector(".tg-preview");
    if (pre && pre.closest("details").open) pre.textContent = JSON.stringify(report(), null, 2);
  }

  const setOpen = (open) => {
    root.hidden = !open; openBtn.hidden = open;
    document.documentElement.classList.toggle("tg-push", open && cfg.push !== false);
    store.set(OPEN_KEY, open);
    dispatchEvent(new Event("resize"));
    if (open) refresh();
  };
  root.querySelector(".tg-x").onclick = () => setOpen(false);
  openBtn.onclick = () => setOpen(true);
  const dl = root.querySelector(".tg-dl");
  if (dl) dl.onclick = () => {
    if (!values().name && !confirm("Download without your name? Jeff will not know who sent it.")) return;
    download();
  };
  const clr = root.querySelector(".tg-clear");
  if (clr) clr.onclick = (e) => {
    e.preventDefault();
    if (!confirm("Clear your answers on this page?" + (cfg.clear ? " This also clears the results recorded by the test." : ""))) return;
    store.set(KEY, {});
    for (const el of root.querySelectorAll("[data-f]")) { if (el.type === "radio") el.checked = false; else if (el.dataset.f !== "name") el.value = ""; }
    if (cfg.clear) cfg.clear();
    refresh();
  };
  root.querySelector("details")?.addEventListener("toggle", refresh);

  const mount = () => {
    document.body.appendChild(root);
    document.body.appendChild(openBtn);
    setOpen(store.get(OPEN_KEY, true));
    setInterval(() => { if (!root.hidden) refresh(); }, 1500);
  };
  if (document.body) mount(); else addEventListener("DOMContentLoaded", mount);
  window.TESTER.refresh = refresh;
  window.TESTER.download = download;
})();
