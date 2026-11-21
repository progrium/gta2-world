// `?hudtest`: a made-up single-player HUD state that cycles through every
// part of the HUD, so it can be looked at before the script engine, career
// and wanted level fill the real one. The ids are message numbers; with the
// player's .gxt loaded they show its text, otherwise their numbers.

import type { SpHud } from "../game/wasm.ts";

export function demoHud(tick: number): SpHud {
  const phase = Math.floor(tick / 300) % 4;
  return {
    lives: 3 - (phase % 2),
    multiplier: 1 + phase,
    points: tick * 37,
    jailCards: 0,
    stars: Math.floor(tick / 60) % 7,
    wantedPoints: 0,
    careerFlags: 0,
    out: false,
    banner: tick % 300 < 90 ? 1001 : 0,
    bannerTicks: tick % 300 < 90 ? 90 - (tick % 300) : 0,
    bannerVoice: 0,
    brief: phase === 1 || phase === 2 ? 2940 : 0,
    briefTicks: tick % 600,
    briefTotal: 600,
    briefsQueued: phase === 1 || phase === 2 ? 2 : 0,
    displays: [
      { timer: phase >= 2 ? Math.max(0, 3600 - (tick % 1200) * 3) : null, counter: phase === 3 ? 5 : null },
      { timer: null, counter: null },
      { timer: null, counter: null },
      { timer: null, counter: null },
    ],
    arrow: { x: 128 + 20 * Math.cos(tick / 90), y: 128 + 20 * Math.sin(tick / 90), entity: false },
    hudFlags: 0,
    tick,
  };
}
