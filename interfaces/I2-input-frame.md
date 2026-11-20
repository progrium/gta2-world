# I2. Input frame

**Status:** frozen at v1, 2026-11-19.
**Between:** input layer (shell, bots, replay files), the sim, and the wire.
**Code:** [`zig/src/input.zig`](zig/src/input.zig), [`ts/src/input.ts`](ts/src/input.ts).

One frame drives one player slot for one tick. Every device produces the same frame, so neither the sim nor the netcode knows which device was used.

## Layout

8 bytes, little-endian, no padding. The memory layout is the wire layout.

| Offset | Field | Type | Meaning |
| --- | --- | --- | --- |
| 0 | `steer` | i8 | −127..127. Positive turns clockwise (right on screen). |
| 1 | `throttle` | i8 | −127..127. Positive accelerates or walks forward; negative brakes, reverses or walks back. In direct mode, 0..127 is walking speed. |
| 2 | `buttons` | u16 | Bit mask, below. |
| 4 | `aim` | u16 | Binary angle (I1 convention). Only meaningful with `direct`; it must be 0 otherwise. |
| 6 | `seq` | u16 | Low 16 bits of the tick this frame drives. |

−128 is never sent. `sanitize` maps it to −127, clears reserved bits and zeroes `aim` outside direct mode. The server sanitizes every frame it receives, and the sim may assume sanitized input.

## Buttons

| Bit | Name | Acted on |
| --- | --- | --- |
| 0 | `fire` | while held |
| 1 | `enter_exit` | rising edge |
| 2 | `handbrake_jump` | while held. Handbrake in a car, jump on foot; the original shares one key. |
| 3 | `weapon_next` | rising edge |
| 4 | `weapon_prev` | rising edge |
| 5 | `special` | while held (horn) |
| 6 | `direct` | per frame: on-foot direct mode, below |
| 7 | `run` | while held, on foot |
| 8–15 | reserved | must be 0 |

The sim finds edges by comparing with `Controller.prev_buttons`. A repeated frame therefore never fires a second edge.

## On-foot control schemes

- **Tank** (`direct` clear): `steer` turns the character and `throttle` walks forward or back. This is the original's scheme and the keyboard default.
- **Direct** (`direct` set): `aim` is the heading the character turns toward and `throttle` is the speed. The shell computes `aim` from the left stick with `angleFromVector` and `throttle` from its magnitude. This is the gamepad default. In a vehicle, `direct` and `aim` are ignored and steer and throttle apply as usual.

Independent twin-stick aiming is not part of v1. It would need a second heading and a reserved bit, through a proposal.

## Ticks and seq

A frame with `seq = s` drives the step that takes the state from tick `T` to `T + 1`, where `T & 0xFFFF == s`. Receivers expand `seq` to a full tick with `expandSeq(seq, reference)`, using serial-number arithmetic. That is valid within ±32768 ticks (18 minutes) of the reference, which is always the receiver's current tick.

If the server has no frame for a tick, it repeats the previous frame's controls with the new `seq`.

## Device rules (shell)

- Analog values go through `quantizeAxis`: multiply by 127, round half away from zero, clamp to ±127.
- Sticks use `radialDeadzone` (default 0.15) before quantizing.
- Triggers give `throttle = quantize(rt − lt)`. Some pads have digital triggers (S6: Switch Pro ZL/ZR read only 0 or 1). They then give ±127, and the sim's own pedal ramp, which S5 takes from the original, provides the build-up. The shell never ramps.
- Keyboard keys give full deflection.
- Gamepads are latched once per sim tick from the most recent animation-frame poll. A press and release that both fall between two polls of one tick still sets the bit for that tick: the shell ORs edge buttons across the polls of a tick.
- Each local player (split-screen) has its own slot and its own frame stream.

## Size check

The frame is 8 bytes. With up to 8 redundant frames for each of up to 4 local players, the input datagram stays under 300 bytes (I3).
