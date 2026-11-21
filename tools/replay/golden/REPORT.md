# Golden re-record report

Written by `replay rerecord` (tools/replay). Compare with the previous `stats.txt` in git history; the commit that changes the golden explains why.

- final hash before: `a3fec68cd7a87b10`
- final hash after: `f999fd0d15093ec8`
- state size: 50208 bytes, layout hash `c30ed24d5936b6c4`
- invariant breaks in the new recording: 0

| measure | before | after | change |
|---|---:|---:|---:|
| ticks | 10000 | 10000 | same |
| kills | 10 | 15 | +50.0% |
| player_kills | 6 | 9 | +50.0% |
| run_over | 7 | 10 | +42.9% |
| fire_kills | 3 | 5 | +66.7% |
| suicides | 1 | 3 | +200.0% |
| explosions | 13 | 20 | +53.8% |
| pickups | 17 | 13 | -23.5% |
| rounds | 0 | 0 | same |
| shots | 1123 | 1029 | -8.4% |
| shot_hits | 39 | 46 | +17.9% |
| ped_deaths | 33 | 43 | +30.3% |
| car_wrecks | 5 | 4 | -20.0% |
| boardings | 151 | 154 | +2.0% |
| exits | 138 | 138 | same |
| contacts | 11709 | 15599 | +33.2% |
| impacts | 196 | 512 | +161.2% |
| wall_hits | 14609 | 14554 | -0.4% |
| driven | 15664 | 16307 | +4.1% |
| walked | 3354 | 3446 | +2.7% |
| ticks_in_cars | 91628 | 92848 | +1.3% |
| score_total | 10253 | 15535 | +51.5% |
| max_kills | 2 | 2 | same |
| max_deaths | 2 | 3 | +50.0% |
| final_cars | 21 | 24 | +14.3% |
| final_peds | 126 | 127 | +0.8% |

```
invariants: 10000 ticks checked, 0 breaks
```
