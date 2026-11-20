# Scoring and cash

- **System:** How the player earns points (money): kills by victim type and method, quick-succession kill combos, destroying and damaging cars, hijacking, buses, the score multiplier, the floating "exploding score" numbers, and what counts toward crime statistics.
- **Out of scope:** mission rewards and bonus targets set by scripts (script note); kill-frenzy bonuses (script and bonus note).
- **Builds on:** `explosions-and-damage.md` (kill credit and causes), `gangs-and-respect.md`, `power-ups-death-and-arrest.md` (multiplier).
- **Sources read:** the decompilation's player score tracker (ped kill, car destroyed, car damaged, hijack, bus, full-bus, accuracy) and the player's score-add helper.
- **Date and author:** 2026-11-19, Claude (notes writer, reader side).

Tags: **[gci]** car data file, **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

Every kill and wreck pops a floating number and adds money. Kills in quick succession are worth more (×2, ×3 … up to ×5). Police and military are worth more than civilians, and running people over is worth less than shooting them. Electrocution and running someone over in their own stolen car pay extra. Each car pays according to its value, more for destroying it than for stealing it. Everything is multiplied by the score multiplier.

## 2. Inputs

- **Car value:** the 3rd byte of each car's `.gci` record, its "value" field **[gci]**.
- **Victim:** occupation, gang membership, cause of death.
- **Player:** multiplier (1–99), recent kill times.

## 3. Rules

### 3.1 How points are added

`money += points × multiplier`. The floating number shown at the victim is also `points × multiplier`. In network games the same amount goes to the player's frag/points total.

### 3.2 Killing peds

1. **Combo.** If the previous credited kill was 15 ticks ago or more **[exe]**, the kill combo resets to 1. Each scored kill then uses the current combo and raises it by 1, up to 5.
2. **Base points by victim class, for a kill by weapon or explosion:**

   | Victim | Base |
   |---|---|
   | ordinary civilian | 20 |
   | mugger or car thief | 40 |
   | member of a gang other than the killer's | 50 |
   | Elvis | 100 (fixed, any method, with its own 15-tick combo) |
   | police, medic, firefighter, guard, roadblock cop | 200 |
   | SWAT | 300 |
   | FBI | 400 |
   | army (soldiers, tank crew) | 500 |

   All values **[exe]**. *(These eight values are the only table in this note. Flag for review against the brief's "no long tables" rule.)*

3. **Method factor:**
   - run over: ×½
   - weapon or explosion: ×1
   - electrocuted: ×2½
   - run over in a car the victim owned (his own car, stolen from him): ×5

   Drowned and other causes score nothing unless set elsewhere **[obs]**.
4. **Points** = base × method factor × combo.
5. **Network games**, when the victim is another player: 2000 for weapons, 1000 for running over, 10000 for running over in a stolen car, 5000 for electrocuting or drowning.
6. **Regional versions:** in builds where killing police scores nothing (the French version), police-type victims give no points.
7. **Crime report:** the kill also files a report: gang member killed, lawman killed, civilian run down, or civilian murdered (`wanted-level.md`).
8. **Bonus system:** the kill is passed to the bonus and kill-frenzy system with victim type, gang, remap, cause, killer's car and zone.

### 3.3 Cars

| Event | Points | Notes |
|---|---|---|
| Hijack | value | [gci] value |
| Destroy | value × 5 × car combo | car combo: 1–5, resets after 15 ticks without a credited destruction |
| Damage (each credited hit) | 1 if the damage dealt is under 300, 10 under 400, 100 above | also files a "car damaged" report |
| Steal a bus | 10 | |
| Destroy a bus carrying 10 or more | 100 | replaces the normal destroy score |
| Kill an ordinary background driver by destroying his car | + 20 × multiplier money | extra cash |

All values **[exe]**.

**Emergency-vehicle tracking:** destroying an ambulance, a police, SWAT or FBI car, or a fire truck within 150 ticks of the last such destruction builds up a set of "kinds destroyed", used by bonus targets. The set resets after 150 ticks with none.

### 3.4 Accuracy

Every projectile hit by the player is counted as a hit on a threat or a hit on someone else, by weapon. This is used for end-of-level statistics.

## 4. Numbers

| Value | Meaning | Source |
|---|---|---|
| 15 ticks | kill and car combo window | [exe] |
| 5 | maximum combo | [exe] |
| ×½ / ×2½ / ×5 | run over / electrocuted / run over in own stolen car | [exe] |
| ×5 | destroyed car factor over hijack value | [exe] |
| 300 / 400 | car damage score bands | [exe] |
| 10 / 100 | bus stolen / full bus destroyed | [exe] |
| 150 ticks | emergency-vehicle kill window | [exe] |

## 5. Edge cases and quirks worth reproducing

- **Car value comes from the `.gci`.** Modded data changes rewards.
- **Combos are by time, not by streak length.** Five quick kills reach ×5.
- **The multiplier applies after everything else,** and the floating number shows the multiplied total.

## 6. Open questions

- Whether drowning and other causes score for ordinary victims.
- The bonus and kill-frenzy rules that consume the bonus events (script note).
