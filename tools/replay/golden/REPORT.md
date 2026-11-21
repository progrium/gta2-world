# Golden re-record report

Written by `replay rerecord` (tools/replay). Compare with the previous `stats.txt` in git history; the commit that changes the golden explains why.

- final hash before: `f34317734cc83643`
- final hash after: `a3fec68cd7a87b10`
- state size: 50208 bytes, layout hash `c30ed24d5936b6c4`
- invariant breaks in the new recording: 0

| measure | before | after | change |
|---|---:|---:|---:|
| ticks | 10000 | 10000 | same |
| kills | 15 | 10 | -33.3% |
| player_kills | 6 | 6 | same |
| run_over | 6 | 7 | +16.7% |
| fire_kills | 8 | 3 | -62.5% |
| suicides | 3 | 1 | -66.7% |
| explosions | 11 | 13 | +18.2% |
| pickups | 19 | 17 | -10.5% |
| rounds | 0 | 0 | same |
| shots | 1338 | 1123 | -16.1% |
| shot_hits | 37 | 39 | +5.4% |
| ped_deaths | 41 | 33 | -19.5% |
| car_wrecks | 7 | 5 | -28.6% |
| boardings | 133 | 151 | +13.5% |
| exits | 123 | 138 | +12.2% |
| contacts | 12830 | 11709 | -8.7% |
| impacts | 305 | 196 | -35.7% |
| wall_hits | 13168 | 14609 | +10.9% |
| driven | 14407 | 15664 | +8.7% |
| walked | 4045 | 3354 | -17.1% |
| ticks_in_cars | 81369 | 91628 | +12.6% |
| score_total | 12007 | 10253 | -14.6% |
| max_kills | 1 | 2 | +100.0% |
| max_deaths | 3 | 2 | -33.3% |
| final_cars | 21 | 21 | same |
| final_peds | 127 | 126 | -0.8% |

```
invariants: 10000 ticks checked, 0 breaks
```
