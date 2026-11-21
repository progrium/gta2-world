# Entering and leaving cars (including carjacking)

- **System:** What happens when the player presses the enter/exit key: which car is chosen, walking to a door, opening it, pulling out a driver (carjacking), getting in, and getting out. Also the limits: moving cars, cars too far away, parking-garage cars, doors that are blocked.
- **Builds on:** `ped-movement.md` (walking, knock-overs), `explosions-and-damage.md` (being thrown), `car-handling.md` (car speed).
- **Sources read:** the decompilation's player enter/exit key handling, the nearest-car search used for it, the ped "enter car" objective and door handling, the entering and exiting ped states, and the car's "can exit" test.
- **Date and author:** 2026-11-19, Claude (notes writer, reader side).

Tags: **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

Pressing enter near a car makes the player run to its door, open it and climb in. If someone is driving, he yanks them out and takes the car; the victim tumbles out and may fight back or flee. Gang members don't like having their cars taken. You can't get into a car that's moving quickly. A car that drives off while you're reaching for the door knocks you away. Pressing enter while driving gets you out, but only when the car is almost stopped. You can't get out at speed.

## 2. Inputs

- **Control:** the enter/exit key, on a fresh press only.
- **Car:** position, speed, door positions and which doors are usable (style data per model), current driver.
- **Player:** whether he's already heading for a car, his state (dead, down, held).

## 3. Rules

### 3.1 Pressing enter on foot

1. **Not if** the player is dead, or already leaving a car.
2. **Choose a car:** look for the nearest car to a point half a block in front of the player, searching outward up to 3 rings of grid cells **[exe]**. A train carriage only counts if its train is stopped.
3. **Order:** if a car is found, the player is ordered to "enter it as driver" (or "enter train"), with the door to be chosen.
4. **Cancelling:** any movement or turn key cancels the order while he's still on foot (`ped-movement.md` 2).

### 3.2 Walking to the door

Each tick while the order stands:

1. **Too far:** if the car is more than 4 blocks away, the order fails (except for script-created peds and emergency workers).
2. **Garage:** if the car is being parked in a garage, the order is dropped.
3. **Door choice:** pick the first usable door. A door is usable if its position isn't blocked by a wall or another car **[obs]**. If none is usable, close any door already opened. If the ped was mid-entry, he's bumped back 45° off the car's heading at 0.05 with the knock-over reaction. Then he walks away.
4. **Arrival:** he arrives when the car's speed is below 0.2 blocks/tick (0.1 for police and other law enforcement entering), he is within 5/32 block of the door, and his collision box overlaps the car's in height. Then:
   - he stops;
   - he is marked as just having left a vehicle, which blocks jumping for a moment;
   - he moves to the door and the door records him;
   - the car's alarm goes off.
5. **Otherwise he runs toward the door** at run speed. He stops and waits beside the car when he's within 2 blocks, overlaps it in height, is within ¾ block on a ramp or 1 block on the flat, or is touching it.

All distances **[exe]**.

### 3.3 Opening the door and getting in

- **Facing:** he turns to the car's heading and plays the door-entry animation. Doors set far from the car's side use a wider variant.
- **Someone else got there first:** if another ped is already entering as driver, he gives up and stands still.
- **Driver present (carjack):**
  - **Refused:** on the third animation frame, if the car refuses this ped (for example, a player trying to take a car the script has locked), the order is dropped.
  - **Hijack:** on the fifth frame, the animation skips ahead to the pull-out frames. A player scores a hijack (scoring note). If the car belongs to a gang, that gang's respect for him drops (gangs note).
  - **Pull-out:** the driver goes through being pulled out and is left on the pavement (ped AI note). Passengers stay.
- **Moving car:** if the car moves away during entry, the entering ped is thrown off.
- **Seated:** when the animation completes, the ped is the car's driver. For the player, the car switches to player handling (`car-handling.md`).

### 3.4 AI peds that steal cars

A non-player ped that completes "enter car as driver" says a line, starts driving it under AI control, and after 600 ticks **[exe]** (≈20 s) is told to get out again. If the car is despawned while he's in or entering it, the ped is removed too.

### 3.5 Getting out

- **Driving:** pressing enter while driving tries to get out. This is only allowed if the car's physics speed is below 0.3 blocks/tick and the car isn't zoomed (being lifted by a crane or similar) **[exe]**. Trains use "leave train". Getting out plays the exit animation from the driver's door.
- **Water:** exiting into deep water drowns the ped immediately (`ped-movement.md` 3.7).
- **Handbrake:** when a driver leaves, the car's handbrake is set if the driver wasn't a player, or kept as the player left it. An abandoned car rolls only if the player let go of the handbrake.

## 4. Order of events

1. Read the enter/exit key (fresh press).
2. On foot: choose a car and set the order. In a car: check "can exit" and set the leave order.
3. Ped update: walk to the door (3.2), then enter (3.3) or exit (3.5) through the ped state machine.
4. The car's driver changes at the end of the animation.

## 5. Numbers

| Value | Meaning | Source |
|---|---|---|
| ½ block ahead, 3 rings | where the enter search looks | [exe] |
| 4 blocks | giving up on a car that's too far | [exe] |
| 0.2 / 0.1 | max car speed to arrive at the door (normal / law enforcement) | [exe] |
| 5/32 | door arrival distance | [exe] |
| 2, 1, ¾ | approach-and-wait distances | [exe] |
| frame 3 / frame 5 | refuse check / hijack moment in the entry animation | [exe] |
| 600 ticks | AI thief drive time | [exe] |
| 0.3 | max car speed to get out | [exe] |

## 6. Edge cases and quirks worth reproducing

- **You can get out of a car that's still rolling** quite fast (0.3 blocks/tick is about 9 blocks per second), so bailing out at moderate speed works.
- **Every entry sets off the alarm** of a car that has one, even an empty parked car.
- **The search point is in front of you.** Facing matters for which car you go for.
- **Law enforcement need the car slower** (0.1) before they can get in.

## 7. Open questions

- Exactly how a door is judged usable (wall and car checks at the door position) and the door order per model.
- The victim's behaviour after being pulled out (fight back, flee, chase); ped AI note.
- Passenger entry (the player can't choose it from the keyboard; scripts can).
