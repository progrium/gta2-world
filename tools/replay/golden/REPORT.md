# Golden re-record report

Written by `replay rerecord` (tools/replay). Compare with the previous `stats.txt` in git history; the commit that changes the golden explains why.

- final hash before: `6caa7344aad42ca0`
- final hash after: `f34317734cc83643`
- state size: 50208 bytes, layout hash `c30ed24d5936b6c4`
- invariant breaks in the new recording: 0

| measure | before | after | change |
|---|---:|---:|---:|
| ticks | 10000 | 10000 | same |
| kills | 19 | 15 | -21.1% |
| player_kills | 6 | 6 | same |
| run_over | 8 | 6 | -25.0% |
| fire_kills | 11 | 8 | -27.3% |
| suicides | 2 | 3 | +50.0% |
| explosions | 11 | 11 | same |
| pickups | 24 | 19 | -20.8% |
| rounds | 0 | 0 | same |
| shots | 1469 | 1338 | -8.9% |
| shot_hits | 27 | 37 | +37.0% |
| ped_deaths | 49 | 41 | -16.3% |
| car_wrecks | 6 | 7 | +16.7% |
| boardings | 127 | 133 | +4.7% |
| exits | 115 | 123 | +7.0% |
| contacts | 13890 | 12830 | -7.6% |
| impacts | 433 | 305 | -29.6% |
| wall_hits | 11012 | 13168 | +19.6% |
| driven | 13302 | 14407 | +8.3% |
| walked | 4475 | 4045 | -9.6% |
| ticks_in_cars | 74617 | 81369 | +9.0% |
| score_total | 9509 | 12007 | +26.3% |
| max_kills | 1 | 1 | same |
| max_deaths | 4 | 3 | -25.0% |
| final_cars | 22 | 21 | -4.5% |
| final_peds | 129 | 127 | -1.6% |

```
invariants: 10000 ticks checked, 0 breaks
```
