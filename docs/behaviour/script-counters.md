# Script command reference: counters

- **System:** Script counter *variables* — the general-purpose numeric slots a mission uses to keep tallies, timers-by-hand, and anything else that isn't one of the game's own built-in stats. Covers declaring a counter, setting its value directly, incrementing/decrementing it, doing arithmetic on it against a literal or another counter, comparing it against a literal or another counter, and how counters are (or aren't) carried across a save/reload.
- **Out of scope:** binding an already-declared counter's value to the on-screen counter display, which `script-messages.md` §2.7 already covers — this note is the counter variable itself, not how its value gets shown. Also out of scope: the many commands elsewhere in the reference that read some other piece of state (a car's speed, the player's score, a multiplier, a life count, and so on) into a counter, or that take a counter as the destination for some unrelated reading — those are each documented in the family they belong to (`script-cars.md`, `script-player.md`), as a side effect of that family's own command, not of the counter itself. This note's commands are the only ones that create a counter or change its value by their own arithmetic.
- **Builds on:** `mission-scripts.md` §3.1 (the level-start declaration pass) and §3.5 (counters are saved and restored with the game). `script-declarations.md` §2's "looked up by command number" convention, which counters use the same way every other declared thing does. `script-flow-control.md` §2.1 (the IF combinator and the pending condition result it reads), which this note's comparison commands feed.
- **Sources read:** the decompilation's level-start declaration-pass dispatch (to see what, if anything, runs for each of the counter declaration types), the per-tick command dispatch and handler functions for every command that sets, increments, decrements, compares, or does arithmetic on a counter, the parameter layouts for each of those commands, and the save-game routines that save and restore counter values plus the fixed-size table they write into.
- **Date and author:** 2026-11-20, Claude (notes writer, reader side).

Tags: **[scr]** the compiled script file format, **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

Nothing directly — a counter is pure bookkeeping a mission uses internally (how many targets are left, how many times something has happened, a hand-rolled timer). The player only ever sees a counter's effects secondhand: through an on-screen counter display bound to it (`script-messages.md`), through a mission reading it to decide what to do next, or through whatever that decision changes (a message, a spawn, a mission pass/fail).

## 2. Inputs: the counter commands [scr]

These run like any other script command (`mission-scripts.md` §3.2): one per tick, in thread order, as the thread's current command, unless a declaration (2.1) runs during the level-start pass instead.

### 2.1 Declaring a counter

A counter is declared, not created at runtime — it's one of the one-shot declaration types `mission-scripts.md` §3.1 applies to every command from 1 to 5999 before any thread starts, the same pass `script-declarations.md` documents for cars, characters and the rest. There's no separate "create a counter" runtime command; a counter only ever exists because a command slot was compiled as one of the four types below.

| Type | Parameters | Effect |
|---|---|---|
| (unnamed) | none | Declares a counter at this command number, starting at zero. |
| (unnamed) | a starting value | Declares a counter at this command number, starting at the given value instead of zero. |
| (unnamed) | none | Same as the bare declare, but also marks this counter to be written to and restored from the save game (2.5). |
| (unnamed) | a starting value | Same as the declare-with-value, but also marked for save-game persistence (2.5). |

All four are pure reservations: nothing runs for any of them at level start beyond the ordinary bookkeeping that gives every declared command a handle (`script-declarations.md` §2's "looked up by command number"). A counter's current value lives directly in its own declaring command from that point on — every command below that names "an earlier-declared counter" is naming this same command number, the same way a car-trigger names an earlier-declared car.

### 2.2 Setting a counter directly

| Type | Parameters | Effect |
|---|---|---|
| (unnamed) | an earlier-declared counter, a value | Writes the given value into the counter, replacing whatever it held. |

A second command type that looks like it ought to copy another counter's live value into this one is declared in the command-type table but has no handler anywhere in the engine — like several of `script-flow-control.md`'s flow-control types, it's never reached at runtime (see Open questions).

### 2.3 Incrementing and decrementing

| Type | Parameters | Effect |
|---|---|---|
| (unnamed) | an earlier-declared counter | Adds exactly 1 to the counter. |
| (unnamed) | an earlier-declared counter | Subtracts exactly 1 from the counter. |

There's no parameter for a step size — moving a counter by any other fixed amount goes through 2.4's arithmetic family instead.

### 2.4 Arithmetic: counter = operand op operand

This is the family that actually stores a computed result back into a counter, as opposed to 2.5's comparisons, which never change any counter. Which of five operations — add, subtract, multiply, divide, or remainder (modulo) — is used is baked into the command's own type, not passed as a parameter.

| Type | Parameters | Effect |
|---|---|---|
| (unnamed) × 5 | a destination counter, a first counter, a second counter | Combines the two counters with the command's operation and writes the result into the destination counter. |
| (unnamed) × 5 | a destination counter, a source counter, a literal value | Combines the source counter with the literal value and writes the result into the destination counter. |

The destination can be the same counter as one of the operands — that's how a script adds or multiplies a counter "in place." There's no dedicated "add this amount to a counter" command; a script gets that by naming the counter as both its own destination and its first operand.

### 2.5 Comparing a counter

Distinct from 2.4: this family never changes any counter. It only ever leaves an outcome in the pending condition result that `script-flow-control.md` §2.1's combinator reads on the very next command, the same mechanism every other condition test in the reference feeds.

| Type | Parameters | Effect |
|---|---|---|
| (unnamed) × ~15 | two operands — a counter and either a literal value or another counter, in either order | Compares the two operands (less-than, less-or-equal, greater-than, greater-or-equal, or equal — which one is baked into the command's type) and leaves true or false in the pending condition result. |

Two command types that sit in the same numeric family as these comparisons, and are dispatched by the very same handful of handler routines, don't compare at all — they add or subtract the two operands and leave the raw sum or difference in the pending condition result instead of a plain true/false (see Edge cases). A script wanting an actual stored arithmetic result must use 2.4 instead; this family, including its two odd add/subtract members, only ever feeds a condition.

### 2.6 Saving and restoring counters across the game

As `mission-scripts.md` §3.5 notes, script counters are saved and restored with the game — but only the ones declared with one of 2.1's two save-marked types. At save time, every still-declared counter of those two types has its command number and current value written into a fixed-size save-game table (Numbers); every other counter (declared with either of the two non-save types) isn't saved at all. At load time, each saved entry is written back into the counter at the matching command number. A counter that wasn't marked for saving simply starts over at its declared value the next time a save is loaded, exactly as if the level had just started.

## 3. Rules

Each command above does its one effect — write, increment/decrement, compute, or compare — and advances to the next command, the same one-tick cost as any other script command (`mission-scripts.md` §3.2). None of 2.2–2.5 cares whether the counter(s) it names were declared with a save-marked type or not; persistence only matters at save/load time (2.6), never to how a counter is read or written during normal play.

## 4. Numbers

| Value | Meaning | Source |
|---|---|---|
| 300 | maximum number of save-marked counters written to, and restored from, the save game at once | [exe] |

Everything else here — a counter's own range, and the range of a literal value a script can write into a "set," arithmetic, or comparison command — isn't a value worth tabulating on its own; see Edge cases for what's actually observable about it.

## 5. Edge cases and quirks worth reproducing

- **A counter's own stored value and a literal value compiled into a command aren't the same size.** A counter comfortably holds any score, count or hand-rolled timer a mission needs. A literal number written directly into a "set," arithmetic, or comparison command is noticeably narrower — comfortably large for small tallies, but a mission that tried to compile in a very large literal (in the tens of thousands or more) would have it silently truncated or misread by the compiler rather than stored as given. **[scr]**
- **Overflowing a counter wraps instead of clamping.** Arithmetic that pushes a counter past its range isn't checked; it wraps around the same way ordinary signed-integer overflow does, rather than stopping at a maximum or minimum.
- **Dividing or taking the remainder of a counter by zero isn't guarded against.** If the divisor — a literal zero, or another counter that currently holds zero — is zero, the game crashes the same way any ordinary zero-divide would. A script (or whatever else is allowed to change the divisor counter) has to keep it away from zero itself; the engine does nothing to protect against it.
- **The comparison family's two "odd" members (2.5) don't compare anything.** They share their dispatch with the five true comparisons, but for these two the command's operation is add or subtract, and whatever that produces — not a plain true or false — is left as the pending condition result. The following IF-style combinator (`script-flow-control.md` §2.1) still treats it as true if nonzero and false if exactly zero, so these only work as a "the sum/difference isn't zero" test, never as a way to compute and keep a value. Reproduce them as a quirky pair of condition tests, not as hidden arithmetic commands.
- **A "copy one counter into another" command is declared but dead** (2.2), the same dead-code pattern `script-flow-control.md`'s Edge cases found for several flow-control types. Don't give it a handler; treat any script that compiles to this type the way an unreachable declared type is treated elsewhere in the reference.
- **Non-persisted counters silently reset on load.** A mission that needs a counter's value to survive a save and reload has to declare that counter with one of 2.1's save-marked types. Declaring it the plain way works identically during play, but the value quietly goes back to its declared starting value the moment a save is loaded — easy to mistake for a bug if a script author expected it to keep counting across sessions.

## 6. Open questions

- **Whether the bare counter declare (2.1, no starting value) is actually guaranteed to start at zero.** Nothing in the declaration pass sets it explicitly — the value simply comes from whatever the command's own compiled data holds, which is zero as long as the script compiler always leaves that field blank for a bare declare. This pass's sources didn't include an actual compiled level or its compiler to confirm that assumption from the other side.
- **Whether a real, compiled mission script ever emits the dead "copy counter into counter" type** (2.2), the same caveat `script-flow-control.md` gives its own dead command types: if an implementer ever finds this type in an actual level file, that's this question resurfacing, not settled behaviour.
- **Whether any debug-only sanity check validates a counter reference at level load**, the way `script-messages.md`'s Edge cases found one for message ids. Nothing like that turned up for counters in this pass's sources, but it wasn't ruled out as thoroughly as the message-id case was.
