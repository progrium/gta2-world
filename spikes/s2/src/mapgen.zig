//! Synthetic collision grid standing in for a real .gmp district (no game data
//! available to this spike). Deterministic integer generator.
//!
//! Layout: solid ground at layer 0; a street grid (4-block roads every 16
//! blocks); lots between roads are buildings 1-5 layers tall, open plazas, or
//! raised platforms reached by ramps (slope blocks). Map edge is a wall.

const sim = @import("sim");
const map = sim.map;

pub fn generate(g: *map.Grid, seed: u32) void {
    @memset(std.mem.asBytes(g), 0);
    var r: u32 = seed | 1;
    const nextRand = struct {
        fn f(s: *u32) u32 {
            s.* ^= s.* << 13;
            s.* ^= s.* >> 17;
            s.* ^= s.* << 5;
            return s.*;
        }
    }.f;
    for (0..map.size_y) |y| for (0..map.size_x) |x| g.set(@intCast(x), @intCast(y), 0, map.Type.solid);

    var ly: u32 = 0;
    while (ly < 16) : (ly += 1) {
        var lx: u32 = 0;
        while (lx < 16) : (lx += 1) {
            // Lot interior: x in [lx*16+4, lx*16+16), same for y.
            const x0 = lx * 16 + 4;
            const y0 = ly * 16 + 4;
            const kind = nextRand(&r) % 10;
            if (kind < 6) {
                // Building, with an alley through it sometimes.
                const h = 1 + nextRand(&r) % 5;
                const alley = nextRand(&r) % 3 == 0;
                for (0..12) |dy| for (0..12) |dx| {
                    if (alley and dx >= 5 and dx < 7) continue;
                    for (1..h + 1) |z| g.set(x0 + @as(u32, @intCast(dx)), y0 + @as(u32, @intCast(dy)), @intCast(z), map.Type.solid);
                };
            } else if (kind < 8) {
                // Raised platform (top at z=2) with a ramp on its west side.
                for (0..12) |dy| for (2..12) |dx| g.set(x0 + @as(u32, @intCast(dx)), y0 + @as(u32, @intCast(dy)), 1, map.Type.solid);
                for (4..8) |dy| {
                    g.set(x0 + 0, y0 + @as(u32, @intCast(dy)), 1, map.makeSlope(map.Rise.pos_x));
                    g.set(x0 + 1, y0 + @as(u32, @intCast(dy)), 1, map.makeSlope(map.Rise.pos_x));
                }
                // Railings on the remaining west edge so the ramp is the way up.
                for (0..12) |dy| {
                    if (dy >= 4 and dy < 8) continue;
                    g.set(x0 + 1, y0 + @as(u32, @intCast(dy)), 1, map.Type.solid);
                }
            } else {
                // Open plaza with a few pillars.
                for (0..4) |_| {
                    const px = x0 + 1 + nextRand(&r) % 10;
                    const py = y0 + 1 + nextRand(&r) % 10;
                    g.set(px, py, 1, map.Type.solid);
                    g.set(px, py, 2, map.Type.solid);
                }
            }
        }
    }
    // Perimeter wall.
    for (0..map.size_x) |i| {
        for (1..4) |z| {
            g.set(@intCast(i), 0, @intCast(z), map.Type.solid);
            g.set(@intCast(i), map.size_y - 1, @intCast(z), map.Type.solid);
            g.set(0, @intCast(i), @intCast(z), map.Type.solid);
            g.set(map.size_x - 1, @intCast(i), @intCast(z), map.Type.solid);
        }
    }
}

const std = @import("std");
