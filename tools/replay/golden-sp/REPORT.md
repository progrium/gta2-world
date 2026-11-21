# Single-player golden: what changed at the last re-record

Re-recorded for A1 slice 2 (claude/project-thread-m4ts1u 9acc6ec): the
declaration pass no longer counts the VM's own commands as unhandled, and
mission end emits mission_pass. The VM state grew, so every hash moved.

| summary line | before | after |
|---|---|---|
| passed | 0 | 1 |
| unhandled | 11 | 0 |

Everything else is unchanged (1 mission started at tick 82, 2 rings, 3
invariant breaks: police passengers left in removed cars, with E).
