# Script command reference: flow control

- **System:** The script commands that steer a mission thread's own execution path, as opposed to acting on a car, character or object. Covers: the IF/THEN/ELSE/ENDIF combinator and its underlying runtime primitive, GOTO, GOSUB/RETURN, WHILE-style loops, the EXEC and WHILE_EXEC block markers, wait/delay commands, starting or stopping another thread, and thread-level flags.
- **Out of scope:** the condition *tests* themselves (is a car wrecked, is a character dead, is the player in an area, and so on) — those are the per-entity query commands already documented in `script-cars.md`, `script-characters.md`, `script-objects.md` and `script-player.md`. This note only covers the commands that consume a condition result and decide where the thread goes next. Also out of scope: the one-shot thread-start-point declarations attached to a phone, a car or an on-foot area (`script-declarations.md` §2.10) — this note covers what happens once such a thread is running, not how it's wired to a trigger.
- **Builds on:** `mission-scripts.md` §3.2 (a thread's fields: current command, flags, condition result, gosub stack, phone timer, stopped flag; the one-command-per-tick default; the EXEC/WHILE_EXEC block rules at a high level) and §3.3 (the forced two-level-unwind mission-fail path). This note identifies the actual command types behind that machinery.
- **Sources read:** the decompilation's per-tick script-command dispatch switch and every flow-control handler it routes to (the condition-combinator, GOSUB/RETURN, thread create/stop, EXEC/WHILE_EXEC block markers, and the two wait commands); the compiled command-type table, read in full to check every type in and around the flow-control numeric range for a runtime handler, not just the ones a handler happened to name; and the per-tick block-execution loop that reads the EXEC nesting count and the WHILE_EXEC marker on each command.
- **Date and author:** 2026-11-20, Claude (notes writer, reader side).

Tags: **[scr]** the compiled script file format, **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

Nothing here is its own visible event; it's the machinery that decides which of a mission's instructions actually run, and in what order. It's why a mission can wait for the player to do something before moving on, why failing an objective sends the mission back to try again instead of failing outright, why some setup runs instantly (several lines in a single moment) while the rest of the mission ticks along one instruction at a time, and why a side job can run quietly in the background while the main mission continues.

## 2. Inputs: the flow-control commands [scr]

These commands run like any other script command (`mission-scripts.md` §3.2): one per tick, in thread order, as the thread's current command, unless they're inside an EXEC or WHILE_EXEC block (§2.4). The "looked up by command number" convention from `script-declarations.md` §2 still applies to the command numbers these take as jump targets.

### 2.1 The IF combinator

A mission script's IF/THEN/ELSE/ENDIF and its AND/OR condition-joining are written at a higher level than the compiled command stream actually needs. Only one runtime command type does the branching: it reads the condition result a condition-test command (from the cars/characters/objects/player families) left behind on the line immediately before it, and decides whether to jump or fall through.

| Type | Parameters | Effect |
|---|---|---|
| (unnamed combinator) | a flag marking this line as part of an OR-combination of conditions (as opposed to the default AND-combination), a jump-target command number | Reads the pending condition result. For an AND-style line: if the result is false, jump to the target (wired to the matching ELSE, or to whatever follows ENDIF if there's no ELSE); otherwise fall through to the next command. For an OR-style line: if the result is true, jump to the target (wired to the start of the THEN body); otherwise fall through. Chaining several of these, one per condition test, is how a script combines multiple conditions with AND or OR before deciding whether to run a THEN body — each test short-circuits the rest of its own chain. |
| (unnamed) | none | Not itself a branch: inverts the pending condition result (true becomes false and vice versa). A script places this between a condition test and the combinator above to get a "not" on that one test. |

**ENDIF itself has no command type.** The end of an IF's THEN (or ELSE) body isn't marked by any special command — it's just whichever ordinary command the compiler happened to place there, and the combinator's jump target points straight at it (or at the line after it, if ENDIF is the very last thing in the mission). There's nothing to document about "ENDIF" beyond that it's a jump destination, not an instruction.

### 2.2 GOTO

There is no dedicated GOTO command either. Every command's own header already carries the number of the command to run next (`mission-scripts.md` §2's four-field header), and advancing a thread normally means "go to the next-command number stored on the line that just ran." A GOTO in the mission's source is compiled by simply pointing that stored next-command number somewhere other than the following line — so at runtime it costs nothing extra: the thread just advances the same way it always does, to wherever that line's next-command field says. The same mechanism is what lets the combinator in §2.1 and the GOSUB/RETURN pair in §2.3 "jump" to an arbitrary line: they overwrite the thread's next-command for one tick instead of relying on the current line's own stored value.

### 2.3 GOSUB and RETURN

| Type | Parameters | Effect |
|---|---|---|
| GOSUB | a command number to jump to | Pushes a new frame onto the thread's gosub stack, recording the command that would otherwise have run next (the line right after this GOSUB) and the condition result the thread had going into the call. Then jumps to the target command. |
| RETURN | none | Pops the top frame off the gosub stack. If there was one, jumps back to the command recorded in it and restores the condition result that was active before the call — discarding whatever the called routine's own IF-tests left behind (see Edge cases). If the stack was already empty, the thread ends instead (the same as reaching level end, `mission-scripts.md` §3's 0xFFFF sentinel). |

A normal RETURN only ever pops one frame. The forced mission-fail path (`mission-scripts.md` §3.3) is a separate, harsher version of this: it discards the top two frames outright and only then performs an ordinary RETURN, which pops (and returns through) what was the third frame down. A script with fewer than two levels of GOSUB nesting active can't rely on that path landing anywhere sensible — it's written expecting the two-level unwind.

### 2.4 Starting and stopping a thread

A thread can only be started at a command number that was marked, during the level-start declaration pass, as a valid thread entry point. `script-declarations.md` §2.10 already covers the three forms that also attach a phone, car or on-foot trigger to that entry point. There's a fourth, plainer declaration type in the same numeric block that marks a command as an entry point with no trigger attached — it has no parameters of its own and does nothing beyond making the command number a legal target for the "start a thread" command below.

| Type | Parameters | Effect |
|---|---|---|
| (unnamed) | a command to start the new thread at, a (possibly different) declared entry-point command to link it to | Creates a new thread, with a fresh gosub stack, no pending condition result, and not stopped, starting at the given command. The entry-point command named by the second parameter has its thread handle filled in, so a later "stop thread" naming that same entry point can find and stop this specific thread. The new thread inherits the creating thread's own flags (see §2.6). |
| (unnamed) | a declared entry-point command | If the thread most recently started from that entry point is still the one running (it hasn't since ended and been replaced by an unrelated thread reusing the same slot), marks it stopped. A stopped thread does nothing on any later tick (`mission-scripts.md` §3.2) — it isn't removed, just inert. |

The two parameters on the "start a thread" command are usually the same command number in practice (the line a thread starts at is usually its own declared entry point), but they don't have to be — a script could start execution at one line while registering the handle under a different entry point.

### 2.5 EXEC and WHILE_EXEC blocks

These are the two run-to-completion mechanisms `mission-scripts.md` §3.2 already describes; this section is the pair of commands (and the one data-only marker) that drive them.

| Type | Parameters | Effect |
|---|---|---|
| start exec | none | Opens an EXEC block: raises the thread's exec-nesting count by one, unless it's already open (nesting doesn't increase past one level deep from a single start — see Edge cases). |
| end exec | none | Closes one level of EXEC nesting: lowers the count by one, unless it's already at zero. |

A thread whose current command is a "start exec" keeps executing commands, one after another, within the same tick, until its exec-nesting count drops back to zero (normally via a matching "end exec" line) or the thread reaches level end.

**WHILE_EXEC has no command type of its own either.** Instead, every command inside a WHILE_EXEC block has its header's return-value field pre-set to 1 at compile time (the same field `mission-scripts.md` §2 lists in the four-field header). Each tick, if the thread's current command has that field set, it keeps running commands in the same tick for as long as the *next* command also has it set — stopping as soon as it reaches a command that doesn't (including a plain "end exec," which has no reason to carry the flag), or reaches level end, or an EXEC block opens partway through (an EXEC start line inside a WHILE_EXEC body takes over and is finished out before the WHILE_EXEC check resumes). There is no separate "start a WHILE_EXEC" instruction to execute — the block's extent is baked into which lines carry the flag, not into anything a thread does at runtime.

### 2.6 Thread-level flags

A thread carries a one-byte flags field, inherited by any thread it starts (§2.4). No path anywhere in the decompiled script engine ever sets this field to anything other than zero, and nothing ever reads it to make a decision — see Open questions. Whatever behaviour a nonzero value (such as "don't restart this thread if the game reloads") was meant to control isn't implemented in this version of the engine; document a reload/restart policy from observed play if one turns out to exist, rather than from this field.

### 2.7 Wait and delay

| Type | Parameters | Effect |
|---|---|---|
| wait-here | a tick count | The thread does not advance. The first time it reaches this line it starts counting down from the given value; each later tick it's still here, the count drops by one. Once the count reaches zero, the thread finally advances to the next command. No condition result is involved — a script just places this line where it wants a flat pause. |
| delay | a tick count | The thread always advances to the next command, every tick — but while counting down it sets the condition result to true ("still waiting"), and to false once the count reaches zero. A script pairs this with the combinator in §2.1, placed right after it with its jump target pointing back to this same line: while the count is still running, the combinator jumps back here (built the same way any GOTO is, §2.2), so the thread sits in a one-line loop for the requested number of ticks; once the count expires, the condition result goes false and the combinator falls through instead. This is the only "while"-shaped loop construct in the compiled command stream — there's no dedicated loop command (see Edge cases); a script gets looping behaviour entirely from an ordinary condition-test (or this delay) wired back to itself through the IF combinator. |

## 3. Order of events

No ordering beyond the general thread rule (`mission-scripts.md` §3.2 and §3.3): each flow-control command is an ordinary one-tick command (unless it's inside an EXEC or WHILE_EXEC block, §2.5), and the mission-fail check runs before a thread's command on every tick, ahead of whatever that command would otherwise do.

## 4. Numbers

| Value | Meaning | Source |
|---|---|---|
| 0xFFFF | level/thread-end command number (shared with `mission-scripts.md` §5) | [scr] |

Everything else here (tick counts for the wait/delay commands, which command numbers a GOTO/GOSUB/combinator targets) is a script-supplied value with no fixed range worth tabulating; this note doesn't repeat `mission-scripts.md`'s header-layout numbers.

## 5. Edge cases and quirks worth reproducing

- **Most of the "obvious" flow-control command types are declared but never used at runtime.** The compiled command-type table reserves named slots for IF, THEN, ELSE, AND, OR, GOTO, WHILE, FOR-style and DO-WHILE-style loops, and a named function construct — eleven types in total, sitting in one contiguous block — and not one of them is referenced by any handler anywhere in the decompiled engine. Only seven real runtime commands cover everything a compiled script actually does with control flow: the condition combinator and its "not," GOSUB/RETURN, and start/stop-EXEC, plus the separately-numbered combinator, thread-start/stop and wait/delay commands documented above. This strongly suggests the higher-level constructs are a source-language concept only, fully resolved by the script compiler into the primitives this note documents, and never reach the compiled file at all — see Open questions.
- **Returning from a GOSUB throws away the subroutine's own condition result.** Whatever IF-tests ran inside the called routine, RETURN restores the condition result the *caller* had right before the call, not whatever the routine last computed. A script that wants a subroutine's test result after returning has to communicate it some other way (a counter, say), not through the condition result.
- **A thread's flags field is carried around and inherited by every thread it starts, but is always zero and never read.** See §2.6 and Open questions.
- **EXEC nesting only tracks depth as a plain up/down count, clamped so it can't go visibly negative or double-count a redundant "start exec.**" Two "start exec" lines in a row without an intervening "end exec" only register as one level deep; it takes exactly one "end exec" to close that, not two.
- **One-line wait loops (§2.7) depend on the IF combinator's jump target pointing back at the same delay line.** Reproduce this as a loop that keeps re-running the delay-and-test pair, not as a dedicated "wait until" primitive — there isn't one.

## 6. Open questions

- **Whether the dead IF/THEN/ELSE/AND/OR/GOTO/WHILE/FOR-loop/DO-WHILE/function command types are truly unreachable, or whether a script compiler could still emit them in some compiled file this pass didn't see.** Every handler and every case label in the engine's own dispatch was checked and none of them appears; if an implementer ever encounters one of these type numbers in an actual level file, treat it as this note's open question resurfacing, not as settled behaviour.
- **What the thread flags field (§2.6) was for.** It's plumbed all the way through thread creation and inheritance, which is a lot of machinery to keep around for a value that's always zero and never tested — it reads like a feature (plausibly something like "don't restart this thread across a reload") that was planned but never wired up, rather than something already removed. Flagging rather than guessing at the intended behaviour.
- **Whether a mission ever relies on GOSUB nesting deeper than the two levels the mission-fail path assumes.** `mission-scripts.md` §3.3 already flags this from the other side; nothing in this note's sources settled it either way.
