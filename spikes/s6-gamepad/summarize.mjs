// Usage: node summarize.mjs results/*.json
// Prints one row per probe run: the matrix the S6 verdict is written from.
import { readFileSync } from "node:fs";

const rows = process.argv.slice(2).map((f) => {
  const r = JSON.parse(readFileSync(f, "utf8"));
  const pad = (r.padsSeen || [])[0] || {};
  const m = r.mapping, a = r.axes, l = r.latency;
  const felt = (k) => {
    const e = (r.rumble || []).filter((x) => x.effect === k);
    if (!e.length) return "-";
    return e.some((x) => x.felt === true) ? "yes" : e.some((x) => x.error) ? "err" : e.some((x) => x.felt === false) ? "no" : "?";
  };
  return {
    file: f.split("/").pop(),
    browser: r.tester.browser,
    os: r.tester.os,
    pad: r.tester.controller,
    conn: r.tester.connection,
    mapping: JSON.stringify(pad.mapping ?? null),
    mapOk: m ? `${m.matched}/${m.results.length - m.skipped.length}` : "-",
    mismatches: m ? m.mismatched.map((x) => x.control).join("; ") : "-",
    trig: a ? a.triggers.map((t) => (t.analog == null || (!t.analog && !(t.max > 0)) ? "?" : t.analog ? "A" : "D")).join("") : "-",
    restMax: a ? Math.max(...a.axes.slice(0, 4).map((x) => x.rest.maxAbs)) : "-",
    diagL: a ? Math.max(...[1, 3, 5, 7].map((i) => a.stickLeft.octantMax[i])) : "-",
    padHz: l ? l.padUpdateRateHz : "-",
    staleP95: l?.stalenessAtFrameReadMs ? l.stalenessAtFrameReadMs.p95 : "-",
    frameP50: l?.frameIntervalMs ? l.frameIntervalMs.p50 : "-",
    underFrame: l ? l.verdictUnderOneFrame : "-",
    rumble: pad.vibrationActuator ? (pad.vibrationActuator.effects || []).join("+") || pad.vibrationActuator.type : "none",
    felt: `${felt("strong")}/${felt("weak")}/${felt("trigger")}`,
    hotplug: r.hotplug?.summary ? `${r.hotplug.summary.connectedEvents}c ${r.hotplug.summary.disconnectedEvents}d sameIdx=${r.hotplug.summary.reconnectSameIndex}` : "-",
    id: pad.id,
  };
});
console.table(rows);
