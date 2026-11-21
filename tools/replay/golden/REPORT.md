# Golden re-record report

Written by `replay rerecord` (tools/replay). Compare with the previous `stats.txt` in git history; the commit that changes the golden explains why.

- final hash before: `9c01d83f84431a51`
- final hash after: `6568effe299ccbb2`
- state size: 50208 bytes, layout hash `c30ed24d5936b6c4`
- invariant breaks in the new recording: 0

| measure | before | after | change |
|---|---:|---:|---:|
| ticks | 10000 | 10000 | same |
| kills | 7 | 14 | +100.0% |
| player_kills | 4 | 8 | +100.0% |
| run_over | 3 | 9 | +200.0% |
| fire_kills | 3 | 5 | +66.7% |
| suicides | 2 | 2 | same |
| explosions | 15 | 20 | +33.3% |
| pickups | 30 | 23 | -23.3% |
| rounds | 0 | 0 | same |
| shots | 1137 | 1538 | +35.3% |
| shot_hits | 28 | 45 | +60.7% |
| ped_deaths | 23 | 39 | +69.6% |
| car_wrecks | 6 | 5 | -16.7% |
| boardings | 161 | 125 | -22.4% |
| exits | 145 | 114 | -21.4% |
| contacts | 10754 | 13145 | +22.2% |
| impacts | 290 | 232 | -20.0% |
| wall_hits | 15023 | 11671 | -22.3% |
| driven | 16532 | 12359 | -25.2% |
| walked | 3264 | 4493 | +37.7% |
| ticks_in_cars | 95501 | 73168 | -23.4% |
| score_total | 8271 | 11585 | +40.1% |
| max_kills | 1 | 2 | +100.0% |
| max_deaths | 2 | 3 | +50.0% |
| final_cars | 23 | 23 | same |
| final_peds | 116 | 126 | +8.6% |

```
invariants: 10000 ticks checked, 0 breaks
```
