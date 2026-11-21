# Golden re-record report

Written by `replay rerecord` (tools/replay). Compare with the previous `stats.txt` in git history; the commit that changes the golden explains why.

- final hash before: `6568effe299ccbb2`
- final hash after: `6caa7344aad42ca0`
- state size: 50208 bytes, layout hash `c30ed24d5936b6c4`
- invariant breaks in the new recording: 0

| measure | before | after | change |
|---|---:|---:|---:|
| ticks | 10000 | 10000 | same |
| kills | 14 | 19 | +35.7% |
| player_kills | 8 | 6 | -25.0% |
| run_over | 9 | 8 | -11.1% |
| fire_kills | 5 | 11 | +120.0% |
| suicides | 2 | 2 | same |
| explosions | 20 | 11 | -45.0% |
| pickups | 23 | 24 | +4.3% |
| rounds | 0 | 0 | same |
| shots | 1538 | 1469 | -4.5% |
| shot_hits | 45 | 27 | -40.0% |
| ped_deaths | 39 | 49 | +25.6% |
| car_wrecks | 5 | 6 | +20.0% |
| boardings | 125 | 127 | +1.6% |
| exits | 114 | 115 | +0.9% |
| contacts | 13145 | 13890 | +5.7% |
| impacts | 232 | 433 | +86.6% |
| wall_hits | 11671 | 11012 | -5.6% |
| driven | 12359 | 13302 | +7.6% |
| walked | 4493 | 4475 | -0.4% |
| ticks_in_cars | 73168 | 74617 | +2.0% |
| score_total | 11585 | 9509 | -17.9% |
| max_kills | 2 | 1 | -50.0% |
| max_deaths | 3 | 4 | +33.3% |
| final_cars | 23 | 22 | -4.3% |
| final_peds | 126 | 129 | +2.4% |

```
invariants: 10000 ticks checked, 0 breaks
```
