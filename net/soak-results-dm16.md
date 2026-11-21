# Soak results on sim/ (dm16)

`zig build -Dsim=real -Doptimize=ReleaseFast && zig-out/bin/soak 120`, 2026-11-20. Workstream A's sim with placeholder handling; players spawn near each other (M2 spawn rule) and start in cars. Default budget is now 400 B; the 187 B and 300 B rows set it explicitly.

## Synthetic test map


## wil.gmp (Jeff's map file, run locally, not committed)


## Reading it

- The 15-chaser rows are the budget test. On the test map the stalest entity waits 21 ticks on average at 187 B, 4.2 at 300 B and 1.8 at 400 B; other-car correction p95 goes 0.18, 0.10, 0.08 blocks. On wil the same three are 5.9, 1.8 and 1.2 ticks. 400 B is the new default; it measured 42 to 56 kbit/s, since the budget is only spent when there is something to send.
- With placeholder handling the chasers pile into one heap within seconds (a contact every sample), so these rows say little about feel. Flickers and wanderers mostly end up parked against walls on the real sim (few corrections), so their rows are not comparable with the arena table in soak-results.md.
- Players joining in the same tick used to spawn far apart; the soak found it and the spawn rule now sees peds spawned earlier in the same tick.
