# Coverage: script-messages

Rules from [docs/behaviour/script-messages.md](../behaviour/script-messages.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 2.1 The text table and text ids | done | sim/test/script_vm.zig | Ids pass to the client as numbers; named fixed texts use hud.text_named | n. |
| 2.2 The one-line message | done | sim/test/script_vm.zig | 117 at important priority, 90 ticks; voice flag passed to the client in the event. |
| 2.3 Brief (help/status) text | ours | sim/test/script_vm.zig | 118/321/279, queue of 20 by priority, now interrupts and pushes back. Typing time from Level.text_lengths (host), else 60 characters; ours: 90 ticks linger after typing. |
| 2.4 Clearing briefs | done | sim/test/script_vm.zig | 317. |
| 2.5 Is a brief currently showing? | done | sim/test/script_vm.zig | 325. |
| 2.6 Countdown timer display | done | sim/test/script_vm.zig | 119/433/120/416; 4 shared slots. From the data the handle is the first parameter, a display declaration (233), not the command itself. |
| 2.7 On-screen counter display | ours | sim/test/script_vm.zig | 414 (display declaration 413 or 233, counter), 415. Ours: with no free slot it fails silently like the timer. |
