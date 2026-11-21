# Coverage: script-flow-control

Rules from [docs/behaviour/script-flow-control.md](../behaviour/script-flow-control.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 2.1 The IF combinator | done | sim/test/script_vm.zig | Type 98 (or-flag, target) and the not, type 71, identified from the player's scripts (WHILE NOT loops compile to test, 71, 98). The or-flag is 0 in every level script. |
| 2.2 GOTO | done | sim/test/script_vm.zig | The header's next field. Types 67 (label before a routine), 77 (end of a while body) and 272 only advance. |
| 2.3 GOSUB and RETURN | done | sim/test/script_vm.zig | 78 and 68 (273 shares RETURN). RETURN restores the caller's condition; empty stack ends the thread. |
| 2.4 Starting and stopping a thread | ours | sim/test/script_vm.zig | No level script uses them: numbers 207 (start), 208 (stop), 210 (plain entry declaration) are ours. Trigger on/off 215/216 are from the data (215 re-enables a phone trigger after the training mission, 216 disables one when it fires). |
| 2.5 EXEC and WHILE_EXEC blocks | done | sim/test/script_vm.zig | 63/64; nesting clamps at one. WHILE_EXEC by the header flag; see mission-scripts 3.2 for the end-exec rule. |
| 2.6 Thread-level flags | done | sim/test/script_vm.zig | Carried and inherited, always 0. |
| 2.7 Wait and delay | ours | sim/test/script_vm.zig | No level script uses them: numbers 61 (wait) and 62 (delay) are ours. The tick it arrives counts as the first of the count. |
