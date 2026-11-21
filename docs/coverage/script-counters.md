# Coverage: script-counters

Rules from [docs/behaviour/script-counters.md](../behaviour/script-counters.md). Status: done, ours, stubbed, blocked or todo (see tools/coverage/rollup.mjs). The owning workstream keeps this file; QA rolls it up into docs/milestones.md.

| rule | status | test | notes |
|---|---|---|---|
| 2.1 Declaring a counter | ours | sim/test/script_vm.zig | 21 from the data, plus 276, a second counter declaration with a value the bil and ste scripts use the same way (which of the two is save-marked is not settled). All carry a 16-bit start value. 22 and 24 (bare forms) are ours; no script uses them. 23 is the arrow declaration (script-declarations 2.6), not a counter. |
| 2.2 Setting a counter directly | done | sim/test/script_vm.zig | 340 (counter, value). The dead copy type is ours (341), no handler. |
| 2.3 Incrementing and decrementing | done | sim/test/script_vm.zig | 96 and 97 (the second parameter word is padding). |
| 2.4 Arithmetic: counter = operand op operand | ours | sim/test/script_vm.zig | No level script uses them: 108-112 (counter op counter) and 79-83 (counter op literal), add/sub/mul/div/mod, are ours. Wraps; divide or remainder by zero leaves the counter unchanged (the original crashed). |
| 2.5 Comparing a counter | ours | sim/test/script_vm.zig | From the data: 94 equal, 90 greater (a wanted-level ladder), 86 less (a timer at half time), 92 greater-or-equal, all counter vs literal. Ours: odd 87-95 the counter vs counter forms, 88 less-or-equal, 84/85 the sum and difference tests. |
| 2.6 Saving and restoring counters across the game | blocked |  | Save-game note missing; in-session save() keeps every counter. |
