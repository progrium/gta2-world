# Coverage: map-geometry

Rules from [docs/behaviour/map-geometry.md](../behaviour/map-geometry.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 3.1 Ramp geometry from the slope type | done | sim/map.zig |  |
| 3.2 Height on a ramp tile | ours | sim/map.zig | exact fractions, not the 0.4985 and 0.1272 scales or the 1/64 minimum |
| 3.3 Ground height at a point | done | sim/map.zig, sim/test/bodies_void.zig | three-sided diagonal blocks 49-52 are flat on top; partial block tops are floors over their part |
