# Shape and map collision (overlap tests)

- **System:** How the game decides that a moving thing (car, pedestrian, object) overlaps a wall in the map or another thing: each thing's collision box, which block faces count as walls, how slopes, diagonal walls and partial blocks are treated, and the sprite-against-sprite test. This is the "is it touching?" question. What happens next is in `car-collision.md` (and later the ped and object notes).
- **Out of scope:** height: whether something is resting on, inside or above the ground, falling, and ramps (car height note). Bullets against walls (weapons note).
- **Builds on:** `car-handling.md` for units and conventions.
- **Sources read:** the decompilation's sprite collision shapes and overlap tests, its spatial grid for finding nearby sprites, and the map module's wall, diagonal-wall and block lookups.
- **Date and author:** 2026-11-19, Claude (notes writer, reader side).

Tags: **[gmp]** map file, **[sty]** style file, **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

Cars and people are stopped by building walls but drive and walk freely over flat ground, pavements and up ramps. Ramps have no invisible side walls of their own; the edge of a ramp blocks you only where the neighbouring block has a real wall face. Diagonal building corners are solid along their diagonal. Small decorative half-blocks (partial blocks) don't block anything. Things on different floors of a multi-level junction pass over and under each other.

## 2. Inputs

### Collision boxes

Every thing has a rectangle in the ground plane (width × length, rotated by its heading) and a vertical extent centred on its height.

| Thing | Ground rectangle | Vertical extent |
|---|---|---|
| Car | car info width × height **[sty]**, in pixels ÷ 64 | 0.5 block **[exe]** |
| Pedestrian | small fixed square (see ped note) | 0.25 block **[exe]** |
| Object | the object's own definition | the object's own definition |

The box is centred on the thing's position. The vertical extent runs from height − half to height + half, capped at just under 8 (the top of the map).

### Map data **[gmp]**

Each block in the `.gmp` has four side faces (left, right, top, bottom, as seen on the map, where "top" faces north, i.e. smaller y) and a lid. Each face word holds a tile number plus flag bits. The ones that matter here:

- **wall** (bit 10): blocks cars and pedestrians.
- **bullet wall** (bit 11): blocks projectiles (weapons note).

Each block also has a slope byte: the low two bits are the ground type (air, road, pavement, field) and the upper six bits are the slope type. Slope types used here:

| Slope type | Meaning for collision |
|---|---|
| 1–44 | gradient slopes (1-, 2- and 8-block ramps): see slopes below |
| 45–48 | diagonal walls: solid along one diagonal of the block |
| 49–52 | three-sided diagonal blocks: treated as a full solid block **and** as a diagonal wall |
| 53–61 | partial blocks: ignored entirely for wall collision |

*(Public map documentation calls 53 the four-sided diagonal block. The game nonetheless groups it with the partial blocks for wall tests, so it doesn't block. [obs])*

## 3. Rules

### 3.1 Two things touching (sprite against sprite)

Two things touch when all of these hold:

1. **Coarse test:** their axis-aligned bounding boxes overlap on x, y **and** height. Each box is the smallest upright box around the rotated rectangle and vertical extent. Overlap is inclusive, so boxes that just meet count.
2. **Fine test:** if both rectangles are axis-aligned (heading a multiple of 90°), or either has zero width, the coarse test is the answer. Otherwise use the separating-axis test for two rotated rectangles. They touch unless one of the four edge directions (two from each rectangle) separates them. The game tries the axes of the first rectangle, then those of the second; either finding overlap counts.

Because height is part of the coarse test, a car on a bridge and a car below it never touch. A car is 0.5 block tall, so cars whose heights differ by more than half a block pass each other.

**Filters before testing.** Each kind of thing can veto a partner. For cars:

- trains on different tracks don't collide;
- cars on opposite sides of a special "layer" flag don't collide;
- a car being crushed doesn't collide with a non-heavy car;
- a wreck and a car with a certain "ghost" flag don't collide.

*(What sets those two flags is an open question.)* Pedestrians and objects have their own filters (their notes).

**Search order.** The game looks through nearby things row by row (north to south) and, within a row, west to east. The caller can name a preferred kind (for example "cars"). The first touching thing of that kind is returned straight away. If none of that kind is found, the first touching thing of any other kind seen during the search is returned. Each thing is tested at most once per search.

### 3.2 Touching a wall

Work out the block column and row the thing's centre is in, and its integer level (height rounded down). Then check the block faces around that block for any face with the **wall** bit that the rectangle crosses. A face is a one-block-long line segment along a block boundary. "Crosses" means the rotated rectangle overlaps that segment.

For a ground-bound thing the checks are:

1. **The centre block's own faces** on each side the rectangle reaches into. A side is skipped if the rectangle doesn't extend past it.
2. **Each neighbour's facing face:** the right face of the west neighbour, the left face of the east neighbour, the bottom face of the north neighbour, the top face of the south neighbour. Both blocks sharing a boundary can mark the wall; either one blocks.
3. **Diagonal neighbours:** where the rectangle reaches past two sides at once, the four faces meeting at that corner are checked too. Each of the two straight neighbours' side faces is checked only if that neighbour's level is not above the other's. The corner block itself is looked up at the higher of the two neighbours' levels.
4. **Wide things:** if the rectangle covers more than three blocks across in a direction, the strip of blocks at the far edge is checked the same way, using the level found for the neighbour on that side.

A missing block (outside the column's stored range) has no faces. Partial blocks (53–61) count as missing. Three-sided diagonal blocks (49–52) count as a plain solid block with wall faces on all four sides as stored.

**Things in the air** (not resting on ground and not on a ramp) skip the neighbour logic. Every wall face inside the rectangle's block footprint at the thing's level is tested directly.

### 3.3 Slopes

On a gradient slope:

- **The ramp's own side faces don't block.** On a north–south ramp, its left and right faces are ignored, and on an east–west ramp its top and bottom faces are ignored. The neighbouring block's facing face still counts.
- **Bottom tile of a ramp.** On the bottom tile (first step) of a ramp, two things change on the uphill side. The face checked there is the matching face of the block one level up. The uphill neighbour is also looked up one level higher. Driving up a ramp therefore checks walls at the level you're climbing to.
- When checking a straight neighbour that is itself a ramp, the same "its own side faces don't count" rule applies to that neighbour.

### 3.4 Diagonal walls

For a block with slope type 45–52, the wall is the block's diagonal:

- types 45, 48, 49 and 52: from the block's south-west corner to its north-east corner;
- types 46, 47, 50 and 51: from its north-west corner to its south-east corner.

A thing touches it if the line crosses the thing's rotated rectangle. The diagonal blocks inside the thing's footprint at its level are checked before any sprite-against-sprite tests.

When this happens, the game reports the contact as a hit on a special invisible "diagonal wall" object placed at the block's centre, one object per diagonal direction. The collision response treats it as an object, and the car unstick nudge has a special case for it (see `car-collision.md`).

### 3.5 Map edge

At the top map level (height 7 and above), being less than 1 block from any side of the 256 × 256 block map counts as touching a straight wall along that side. Below level 7 there is no special edge rule.

## 4. Order of events

For one "is this pose touching anything?" check on a car:

1. Map edge (top level only).
2. Wall faces, with the slope rules (3.2–3.3).
3. Diagonal walls (3.4).
4. Other sprites (3.1), preferring nothing in particular for cars.
5. If the car tows a trailer and nothing was found, repeat 1–4 for the trailer.

The first hit found is the one reported, which matters because only one contact is handled per sub-step.

## 5. Numbers

| Value | Meaning | Source |
|---|---|---|
| 64 px = 1 block | box size unit | [sty] |
| 0.5 block | car collision height | [exe] |
| 0.25 block | pedestrian collision height | [exe] |
| just under 8 | highest point any box reaches | [exe] |
| 256 × 256 × 8 | map size in blocks | [gmp] |
| 3 blocks | widest a thing can be before the far-edge strip check kicks in | [exe] |

## 6. Edge cases and quirks worth reproducing

- **Ramps have no side walls of their own.** Cars can scrape off the side of a ramp if there's no neighbouring wall.
- **Wall faces are one-sided in the data but two-sided in effect.** A wall bit on either block at a boundary blocks movement both ways.
- **Partial blocks and type 53 don't stop anything** even if their faces are marked as walls.
- **Diagonal-wall hits are object hits.** They produce object-style bounces, not wall-style ones.
- **The top level is boxed in; lower levels aren't.** Lower levels rely on the map's own blocks.
- **Inclusive overlap.** Things exactly touching count as colliding, which is part of why stacked cars are pushed apart.

## 7. Open questions

- The exact pedestrian footprint and the per-object collision sizes (ped and object notes).
- What the car "layer" and "ghost" collision flags are used for.
- Which corner of the car's rectangle is reported as the contact point for a wall face, and how "front, back, left or right quarter" is chosen for dents. `car-collision.md` gives the contact-point rule; the quarter choice is still to be traced.
- Whether a car can be wider than 3 blocks in practice (buses and trains are long, but the strip check is about the extent in x or y on the map).
