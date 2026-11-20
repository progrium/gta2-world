# Map geometry: ground height and slopes

- **System:** How the game turns `.gmp` blocks into a ground height at any point: flat blocks, the three ramp lengths and their per-tile height profile, which block in a column counts as the ground, and the small rounding quirks. Every height-following system (cars, peds, objects, the camera) uses this.
- **Builds on:** `shape-and-map-collision.md` (block faces, slope numbering), `car-height.md` and `ped-movement.md` (who uses it).
- **Sources read:** the decompilation's map lookups for the highest block in a column, ground height at a point, the per-slope-type geometry table and the gradient scale factors.
- **Date and author:** 2026-11-19, Claude (notes writer, reader side).

Tags: **[gmp]** map file, **[exe]** fixed in the executable.

---

## 1. What the player sees

Roads and pavements sit on the tops of blocks. Ramps rise smoothly over 1, 2 or 8 blocks of travel per level. Bridges and flyovers have open space underneath.

## 2. Inputs **[gmp]**

- **Columns:** each map square holds a column of blocks from a base level up to a height.
- **Blocks:** each block has a slope byte. The low 2 bits are the ground type (air, road, pavement, field) and the high 6 bits are the slope type (`shape-and-map-collision.md`).
- **Arrows:** a direction-arrow byte used by traffic and the arrow snap (`car-handling.md`).

## 3. Rules

### 3.1 Ramp geometry from the slope type

Slope types 1–44 are ramps. Each has an **uphill direction**, a **length** (blocks per level) and a **step** (which tile of the ramp it is, counted from the top: 0 is the highest tile). The table is regular, so it can be generated:

| Slope types | Length | Uphill direction | Steps |
|---|---|---|---|
| 1–8 | 2 | pairs: 1–2 north, 3–4 south, 5–6 west, 7–8 east | first of each pair is the lower tile (step 1), second the upper (step 0) |
| 9–40 | 8 | groups of 8: 9–16 north, 17–24 south, 25–32 west, 33–40 east | within a group, the first is the lowest tile (step 7) and the last the highest (step 0) |
| 41–44 | 1 | 41 north, 42 south, 43 west, 44 east | single tile (step 0) |

All other slope types have no gradient.

A ramp tile's **lower edge height** within its level is `(length − 1 − step) / length`: 0 or 0.5 for 2-block ramps, eighths for 8-block ramps, 0 for 1-block ramps. "North" means toward smaller y.

### 3.2 Height on a ramp tile

For a point at `(x, y)` on a ramp tile at level `L`:

1. **Position along the tile** in the uphill direction, from 0 at the downhill edge to 1 at the uphill edge:
   - north: `1 − frac(y)`
   - south: `frac(y)`
   - west: `1 − frac(x)`
   - east: `frac(x)`
2. **Height** = `L + lower edge + position × scale`. The scale is:

   | Ramp length | Scale |
   |---|---|
   | 1 | 1 |
   | 2 | 8168/16384 ≈ 0.4985 **[exe]** |
   | 8 | 2084/16384 ≈ 0.1272 **[exe]** |

3. If the result within the level is exactly 0, it becomes 1/64 instead **[exe]**.

### 3.3 Ground height at a point

- Find the highest block in the column under `(x, y)` that isn't an air block.
- If it's a ramp (and not air-typed), the ground is the ramp height on it (3.2), using that block's level.
- Otherwise the ground is the **top** of that block: its level + 1.
- With no such block, the ground height is 0. Cars then treat it as 1 (`car-height.md`).

"Ground below a height" searches the same way, but starts from a given level and goes down, so the space under a bridge has its own ground.

## 4. Numbers

| Value | Meaning | Source |
|---|---|---|
| 1, 2, 8 blocks | ramp lengths per level | [gmp] |
| ≈0.4985, ≈0.1272 | 2-block and 8-block ramp scale | [exe] |
| 1/64 | minimum non-zero height within a level on a ramp | [exe] |
| 8 | number of levels | [gmp] |

## 5. Edge cases and quirks worth reproducing

- **Ramp joins aren't exact.**
  - On 2-block ramps, each tile rises about 0.0015 less than half a level, so there's a tiny step at the join and at the top.
  - On 8-block ramps, each tile rises about 0.0022 **more** than an eighth, so a tile slightly overshoots the next tile's start.

  Cars and peds bump very slightly at ramp joins. With exact fractions, heights near ramp edges come out marginally different.
- **Zero becomes 1/64.** The bottom edge of a ramp's lowest tile reports 1/64 above the level, not exactly the level.
- **Air-typed blocks are never ground,** even if they have a slope type.

## 6. Open questions

- The ground height of partial and diagonal blocks (they count as no gradient, so their top is level + 1 if they're the highest block). Confirm that peds can stand on top of partial blocks.
- How lid tiles marked transparent or flat affect ground (rendering only, or also walking?).
