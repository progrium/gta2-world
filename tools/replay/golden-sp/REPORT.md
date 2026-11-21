# Single-player golden: what changed at the last re-record

Re-recorded for the merge of A1 slice 2 (m4ts1u 9acc6ec), E's crew
passenger fix (notes/e 8400673) and F slice 5 (notes/f 71f0248).

| summary line | before | after | why |
|---|---|---|---|
| passed | 0 | 1 | A1: mission end emits mission_pass |
| unhandled | 11 | 0 | A1: the declaration pass skips the VM's own commands |
| invariant_breaks | 3 | 0 | E and F: no police passenger is left in a removed car |

Everything else is unchanged (1 mission started at tick 82, 2 rings).
