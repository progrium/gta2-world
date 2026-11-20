# Script command reference: messages

- **System:** The runtime script commands that put text on screen for the player: a single big banner message, a queued "brief" (help/status text with a talking-head portrait), a countdown-timer display, and a live on-screen counter display, plus the commands that clear or query them. Also covers the text lookup these commands share — a global table of in-game text, separate from the per-level string table `mission-scripts.md` §2 already documents.
- **Out of scope:** the death/wasted/busted text itself, already covered by `power-ups-death-and-arrest.md`. Which message id a mission-fail shows and how it's chosen (`mission-scripts.md` §3.3, `script-declarations.md` §2.16) — this note covers how a chosen id gets displayed once something else has decided it, not the choice itself. Counter *variables* — declaring one, setting it, doing arithmetic on it — belong to the not-yet-written Counters note; this note only covers binding an already-declared counter's value to an on-screen display. The mission and kill-frenzy "template" commands that bundle a timer, a counter display, a brief and a reward into one command belong to the not-yet-written Missions note; they're cross-referenced here only where they reuse this note's display mechanisms. The general HUD rendering system (fonts, layout, the pager icon's artwork) belongs to a later HUD note; this note only covers the script-level commands that drive it.
- **Builds on:** `mission-scripts.md` (file format, tick model, the declaration pass, the per-level string table for zone names — a different lookup from this note's text table). `script-declarations.md` §2's "looked up by command number" convention, which the timer and counter display commands reuse to attach a handle to themselves. `script-player.md`, which first identified these commands as belonging here. `car-handling.md` §5 for the engine's standard tick rate, reused below for the timer commands' seconds-to-ticks conversion.
- **Sources read:** the decompilation's script-command dispatch for the message, brief, timer and on-screen-counter command types; the declaration pass's pass-through handling of the same message/brief types; the HUD widgets behind each (the single-slot banner message, the queued talking-head brief list, and the shared timer/counter display slots); the global text-table lookup they all share; and the mission-fail path and kill-frenzy/phone mission templates, read only far enough to see how they reuse these same display commands.
- **Date and author:** 2026-11-20, Claude (notes writer, reader side).

Tags: **[scr]** the compiled script file format, **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

A short line of text appears centered on screen in capitals for a few seconds, then disappears — used for things like a pickup's value, "mission failed," or a kill-frenzy starting. Only one of these is ever visible at once; a new one cuts the old one off (unless the old one is more urgent). Separately, a small talking-head portrait with a line of help or status text plays in a corner of the screen, typing itself out letter by letter while the face's mouth and eyes animate; several of these can be queued up to play one after another, and an urgent one can jump the queue. Elsewhere on screen, a pager-shaped icon can show a countdown clock (minutes and seconds, flashing when it's nearly out) and/or a running number — used for mission time limits and "targets remaining"-style counts.

## 2. Inputs: the message commands [scr]

These commands run like any other script command (`mission-scripts.md` §3.2): one per tick, in thread order, as the thread's current command.

### 2.1 The text table and text ids

Separately from the per-level string table (`mission-scripts.md` §2, used for zone names and mission sub-script names), the game keeps one global table of in-game text, loaded once for the whole game rather than per level. Entries are found by a short text key. A script almost always names its text by a plain number; the engine turns that number into its ordinary decimal digits and looks up that string as the key (message id 500 becomes the key "500"). A handful of fixed, named keys exist too (for example the generic "mission failed" banner), but a script command never names one of those directly — only the engine's own mission-fail and kill-frenzy handling does, as noted under Edge cases.

### 2.2 The one-line message

| Type | Parameters | Effect |
|---|---|---|
| 117 | a message id, a voice-cue flag | Looks the id up in the text table (2.1) and shows it as the single big banner message, replacing whatever banner message is currently shown unless that one is more urgent (see Numbers for the two priority levels and Edge cases for which is used). The voice-cue flag, if 1 or 2, also plays a fixed "job complete" or "job fail" voice line alongside the text — this is independent of the message's own content. |

### 2.3 Brief (help/status) text

| Type | Parameters | Effect |
|---|---|---|
| 118 | a message id, a voice-cue flag | Queues the id's text as a brief at normal priority (2.3's queue rule). |
| 279 | same | Queues the text at the highest priority: it always interrupts whatever brief is currently showing and starts immediately. |
| 321 | same | Queues the text at the middle priority, ahead of normal-priority entries already queued but behind an interrupting one. |

All three share the voice-cue flag described in 2.2 — any of them can also trigger the "job complete"/"job fail" voice line, independently of the text shown.

Briefs are queued, not overwritten: up to a shared pool of entries can be waiting at once (see Numbers), ordered by priority, and a lower-or-equal-priority brief queues behind any higher-or-equal-priority ones already waiting rather than replacing them. The one exception is the highest priority (type 279): it always jumps straight to the front and starts at once, pushing whatever was showing (if it had already started) onto a "shown previously" list rather than discarding it — the player can step back through that list (bound to a player input, not a script command — **[obs]** which one). Each brief types itself onto screen at a fixed rate per character (a player-adjustable game option, Numbers) alongside a talking-head portrait that "lip-syncs" to the text's characters. The portrait's face is chosen by an optional two-character marker at the very start of the text naming a gang, the police, or "neutral" — plain text with no such marker gets a neutral face.

### 2.4 Clearing briefs

| Type | Parameters | Effect |
|---|---|---|
| 317 | none | Discards every queued and currently-showing brief, at every priority. |

### 2.5 Is a brief currently showing?

| Type | Parameters | Effect |
|---|---|---|
| 325 | none | A condition: true if a brief is actively showing right now (not merely queued). |

### 2.6 Countdown timer display

These share the "looked up by command number" idiom (`script-declarations.md` §2): the command that creates a timer attaches its handle to its own command number, the same way a declaration does, even though it's an ordinary runtime command rather than a one-shot declaration. A later command names that same command number to act on the timer it created.

| Type | Parameters | Effect |
|---|---|---|
| 119 | a duration in seconds | Creates a countdown timer showing that many seconds, counting down once per tick, and attaches its handle to this command's own number. Seconds are converted to ticks at the engine's standard tick rate (`car-handling.md` §5). If every shared display slot (Numbers) is already in use, the timer silently fails to appear — nothing is attached, and later commands naming this one find nothing to act on. |
| 433 | an earlier timer-display command's number, a number of seconds | Adds that many seconds (converted to ticks the same way) to the named timer's remaining time. This works even on a timer that has already reached zero — there's no separate "still running" flag, just a count that keeps ticking down past zero, so adding time to an expired timer restarts it. |
| 120 | an earlier timer-display command's number | Clears the whole display slot the named timer is using — both the countdown and, if an on-screen counter (2.7) happens to share the same slot, that counter too. |
| 416 | an earlier timer-display command's number | Clears only the countdown part of the named slot, leaving any on-screen counter sharing it untouched. |

### 2.7 On-screen counter display

| Type | Parameters | Effect |
|---|---|---|
| 414 | an earlier-declared counter | Binds that counter's live value to an on-screen number display, attaching its own handle the same self-referencing way 2.6's timer-creating command does. A display slot that already has a countdown timer running on it is reused in preference to an empty one, so a mission's timer and its "targets remaining"-style counter commonly end up sharing one slot and showing together; if no slot is free at all, which counter ends up bound is unconfirmed (see Open questions). |
| 415 | an earlier on-screen-counter command's number | Clears only the counter part of the named slot, leaving any countdown timer sharing it untouched. |

Both the timer and the counter are drawn through the same small set of shared display slots (Numbers); a slot can hold a timer, a counter, or one of each at once, each cleared independently by 2.6/2.7's "clear" commands unless the timer-side "clear whole slot" command (type 120) is used.

## 3. Rules

Nothing here runs over more than one tick from the thread's point of view — each command above does its one effect and advances, the same as any other script command (`mission-scripts.md` §3.2). The visible countdown, counter, message, and brief widgets each update once per game tick independently of script threads, the same tick the thread itself runs on.

## 4. Numbers

| Value | Meaning | Source |
|---|---|---|
| 90 ticks (≈3 s) | how long the one-line banner message (2.2) stays up once shown | [exe] |
| two priority levels | the banner message's own priority: normal (in-game events — bonuses, pickups, death text) and important (mission messages, game over) — a new message only replaces the shown one if its priority is at least as high | [exe] |
| three priority levels | a brief's priority: normal, soon (queues ahead of normal), now (always interrupts) | [exe] |
| 20 | shared pool of queued/shown brief entries | [exe] |
| 3 ticks/character (default) | how fast a brief types itself out; a player-adjustable game option, not fixed | [exe] |
| 4 | shared timer/on-screen-counter display slots | [exe] |
| ×30 | seconds-to-ticks conversion the two timer commands (2.6) use, matching the engine's standard tick rate (`car-handling.md` §5) | [exe] |

## 5. Edge cases and quirks worth reproducing

- **Mission-fail display combines two of this note's commands.** When a mission fails from death or arrest (`mission-scripts.md` §3.3), the engine clears every queued/shown brief, queues the chosen one of the five per-gang fail messages (`script-declarations.md` §2.16) as a normal-priority brief, and separately shows a single fixed "mission failed" banner message at important priority — the specific reason only ever appears in the brief, never in the banner itself.
- **A handful of specific message ids also trigger a voice line just by being displayed**, regardless of the voice-cue flag and regardless of which of the four display commands (2.2/2.3) shows them — for example lap-counter announcements in a race and a set of "you got hurt"/"nice work"-style taunts. The full set is a fixed list of ids baked into the executable, not something a script chooses; a script that reused one of those exact ids for unrelated text would unexpectedly trigger that voice line. The list itself is a game constant and out of scope here, the same way `script-declarations.md` treats its car-model power-up list.
- **Clearing a timer (type 120) is not the same as clearing only the timer.** It wipes the entire shared display slot, counter included if one happens to be sharing it, unlike the dedicated "clear only the clock" (416) or "clear only the counter" (415) commands.
- **Pairing a counter with a timer links their lifetimes.** If an on-screen counter ends up sharing a slot with a countdown timer, the counter disappears the moment the timer's slot is fully cleared (type 120) — even if the counter's own value hasn't reached anything meaningful — but not when only the clock half is cleared (416).
- **The underlying brief-display routine also supports substituting a numeric value into the shown text** (for something like a cost or amount), but none of the four script display commands ever pass one — they always leave it unused. This looks like it's meant for some other, non-script-triggered use of the same brief widget rather than something scripts can do.
- **A declaration-pass sanity check exists for message ids**, but only when a particular debug setting is turned on: at level load, every id named by one of the four display commands (2.2/2.3) is checked against the text table, and a missing id is treated as a fatal load error. This is a development tool, off by default, not something to reproduce as gameplay behaviour.

## 6. Open questions

- **What input lets the player step back through previously-shown briefs**, referenced in 2.3. **[obs]**
- **What happens when `script-messages.md`'s on-screen-counter command (414) is asked to bind a counter and every shared display slot already has one bound.** Creating a timer (2.6) fails safely and silently when slots are full; whether the counter command fails the same way, or behaves unpredictably, wasn't confirmed from this pass's sources.
- **Two declared command types look like they ought to pre-register a timer or an on-screen-counter slot before 2.6/2.7's commands use it, but no handler for either was found anywhere in the engine.** `script-declarations.md`'s "declarations ignore control flow but still need a handler" framing doesn't apply here — these two simply aren't wired to anything, the same way several flow-control types turned out to be dead (`script-flow-control.md`'s Edge cases). The timer- and counter-display commands documented above don't need any such predeclaration; they self-register the first time they run. Flagging this as unconfirmed dead content rather than settled behaviour, in case some compiled level does use it.
