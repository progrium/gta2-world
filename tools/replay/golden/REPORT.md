# Golden re-record report

Written by `replay rerecord` (tools/replay). Compare with the previous `stats.txt` in git history; the commit that changes the golden explains why.

- final hash before: `708a7151b7b242e5`
- final hash after: `9c01d83f84431a51`
- state size: 48672 bytes, layout hash `fe352047295ea12e`
- invariant breaks in the new recording: 0

| measure | before | after | change |
|---|---:|---:|---:|
| ticks | 10000 | 10000 | same |
| kills | 13 | 7 | -46.2% |
| player_kills | 4 | 4 | same |
| run_over | 6 | 3 | -50.0% |
| fire_kills | 7 | 3 | -57.1% |
| suicides | 1 | 2 | +100.0% |
| explosions | 19 | 15 | -21.1% |
| pickups | 22 | 30 | +36.4% |
| rounds | 0 | 0 | same |
| shots | 1564 | 1137 | -27.3% |
| shot_hits | 21 | 28 | +33.3% |
| ped_deaths | 40 | 23 | -42.5% |
| car_wrecks | 8 | 6 | -25.0% |
| boardings | 144 | 161 | +11.8% |
| exits | 132 | 145 | +9.8% |
| contacts | 14905 | 10754 | -27.8% |
| impacts | 448 | 290 | -35.3% |
| wall_hits | 16186 | 15023 | -7.2% |
| driven | 15538 | 16532 | +6.4% |
| walked | 4057 | 3264 | -19.5% |
| ticks_in_cars | 85033 | 95501 | +12.3% |
| score_total | 7827 | 8271 | +5.7% |
| max_kills | 1 | 1 | same |
| max_deaths | 3 | 2 | -33.3% |
| final_cars | 20 | 23 | +15.0% |
| final_peds | 116 | 116 | same |

```
invariants: 10000 ticks checked, 0 breaks
```
