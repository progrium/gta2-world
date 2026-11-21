# Golden re-record report

Written by `replay rerecord` (tools/replay). Compare with the previous `stats.txt` in git history; the commit that changes the golden explains why.

- final hash before: `4fa9b2caeb050f5f`
- final hash after: `708a7151b7b242e5`
- state size: 47904 bytes, layout hash `af63c8676ab2351e`
- invariant breaks in the new recording: 0

| measure | before | after | change |
|---|---:|---:|---:|
| ticks | 10000 | 10000 | same |
| kills | 6 | 13 | +116.7% |
| player_kills | 4 | 4 | same |
| run_over | 3 | 6 | +100.0% |
| fire_kills | 2 | 7 | +250.0% |
| suicides | 1 | 1 | same |
| explosions | 17 | 19 | +11.8% |
| pickups | 23 | 22 | -4.3% |
| rounds | 0 | 0 | same |
| shots | 1426 | 1564 | +9.7% |
| shot_hits | 25 | 21 | -16.0% |
| ped_deaths | 29 | 40 | +37.9% |
| car_wrecks | 6 | 8 | +33.3% |
| boardings | 137 | 144 | +5.1% |
| exits | 125 | 132 | +5.6% |
| contacts | 15117 | 14905 | -1.4% |
| impacts | 170 | 448 | +163.5% |
| wall_hits | 15990 | 16186 | +1.2% |
| driven | 15195 | 15538 | +2.3% |
| walked | 3680 | 4057 | +10.2% |
| ticks_in_cars | 82889 | 85033 | +2.6% |
| score_total | 8795 | 7827 | -11.0% |
| max_kills | 1 | 1 | same |
| max_deaths | 1 | 3 | +200.0% |
| final_cars | 21 | 20 | -4.8% |
| final_peds | 116 | 116 | same |

```
invariants: 10000 ticks checked, 0 breaks
```
