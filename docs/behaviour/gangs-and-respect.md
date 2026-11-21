# Gangs and respect

- **System:** The per-player respect each gang has for the player (−100 to 100), how kills, hijacks and car destruction change it (including knock-on changes for rival gangs), how missions change it, and how it decides which weapon gang members use against the player.
- **Out of scope:** how gang members behave toward the player on the street (ped AI note); which missions a gang offers (script note).
- **Builds on:** `explosions-and-damage.md` (kill credit and causes), `entering-and-exiting-cars.md` (hijacks).
- **Sources read:** the decompilation's gang records and respect arithmetic, the places that change respect (kills, hijacks, destroyed cars, the respect power-up, script commands), and the gang weapon choice.
- **Date and author:** 2026-11-19, Claude (notes writer, reader side).

Tags: **[scr]** set by the mission script, **[gmp]** map file, **[exe]** fixed in the executable.

---

## 1. What the player sees

Each district's gang has a respect bar. Killing a gang's members, stealing their cars or blowing them up lowers it. Doing jobs for a gang raises it, and usually lowers its rivals' respect. Hated, a gang shoots on sight with heavier weapons; respected, they leave you alone or help.

## 2. Inputs

- **Gang definitions [scr]:** the mission script creates each gang and sets:
  - its name, its car model and car colour remap, and its ped remap;
  - its basic, angry and hate weapons, and an "always use basic weapon" switch;
  - how much killing one of its members changes respect ("kill change");
  - for each other gang, a "kill reaction": how that other gang feels when you kill one of this gang's members;
  - whether killing its members affects respect at all.
- **Gang zones [gmp]:** map zones tie areas to gangs, for "current gang" and the respect power-up.
- Up to 10 gangs **[exe]**.

## 3. Rules

### 3.1 The respect value

Each gang holds a respect value per player, from −100 to 100, starting at 0.

- **Raising** caps at 100, including when the arithmetic would wrap. When respect is 80 or more, the gang counts as "high respect" for the player.
- **Lowering** floors at −100.

### 3.2 Events that change respect

| Event | Effect |
|---|---|
| The player kills a gang member (credited kill), not by running him over | that gang: −5 × its kill change; every other gang: + 5 × its kill reaction to this gang |
| The same, but by running him over | as above with 1 instead of 5 |
| The player hijacks a gang car (by its car model) | as a 1-point kill against that gang |
| The player destroys a gang car | as a 1-point kill against that gang |
| Respect power-up | +20 with the gang whose area the player is in |
| Mission script adjusts respect by `n` steps | ± 20 × `n` with that gang; every gang that has a non-zero kill reaction to it moves 20 × `n` the opposite way |

All values **[exe]**.

- Kill reactions can be positive or negative per gang pair, so killing one gang's members can please its rivals.
- Gang members still count as peds for scoring, but give only +1 wanted point (`wanted-level.md`).
- Kills that the gang is set to ignore change nothing.

### 3.3 Weapon choice against the player

When a gang member arms himself:

- in network games, or if the gang is set to always use its basic weapon: the basic weapon;
- respect exactly −100: the hate weapon;
- respect above −60: the basic weapon;
- otherwise (−100 < respect ≤ −60): the angry weapon.

The respect checked is that of the first player.

## 4. Numbers

| Value | Meaning | Source |
|---|---|---|
| −100 … 100 | respect range | [exe] |
| 80 | "high respect" threshold | [exe] |
| −60, −100 | thresholds for the angry and hate weapons | [exe] |
| 5 / 1 | kill weight (normal / run over, hijack, car destroyed) | [exe] |
| 20 | respect step for the power-up and script changes | [exe] |
| 10 | maximum gangs | [exe] |

## 5. Edge cases and quirks worth reproducing

- **Running people over is gentler on respect** (1 instead of 5).
- **Hijacking a gang car** costs as much respect as running over a member.
- **Respect at exactly −100 is special.** Only then do they use the hate weapon.
- **Weapon choice in single player always reads player 1's respect.**

## 6. Open questions

- How gang members decide to attack, ignore or follow the player at each respect level (ped AI note).
- The gang-zone lookup for "current gang" (zone types in the `.gmp`).
