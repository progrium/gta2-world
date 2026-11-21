# Script coverage

Written by `tools/scrasm coverage` (workstream A1) from the player's own level scripts: type numbers and counts only. Each level is also loaded into the sim on the synthetic test map and run for 3000 ticks with no player.

## Levels

| level | missions | commands | threads at end | unhandled met | stuck threads |
|---|---|---|---|---|---|
| bil | 22 | 1060 | 1 | 1153 | 0 |
| downtown-6p | 0 | 472 | 0 | 612 | 0 |
| industrial-6p | 0 | 582 | 0 | 750 | 0 |
| lorne2e | 0 | 467 | 0 | 560 | 0 |
| lorne2h | 0 | 470 | 0 | 558 | 0 |
| lorne2m | 0 | 469 | 0 | 563 | 0 |
| mike1e | 0 | 662 | 0 | 857 | 0 |
| mike1h | 0 | 655 | 0 | 847 | 0 |
| mike1m | 0 | 656 | 0 | 847 | 0 |
| mike2e | 0 | 222 | 0 | 233 | 0 |
| mike2h | 0 | 222 | 0 | 233 | 0 |
| mike2m | 0 | 222 | 0 | 233 | 0 |
| mp1-6p | 0 | 61 | 0 | 82 | 0 |
| mp2-6p | 0 | 115 | 0 | 147 | 0 |
| mp5-6p | 0 | 125 | 0 | 162 | 0 |
| res-6p | 0 | 458 | 0 | 689 | 0 |
| ste | 22 | 1546 | 1 | 1808 | 0 |
| wil | 23 | 1266 | 1 | 7092 | 0 |

## Command types used

| type | name | uses | handler |
|---|---|---|---|
| 5 | player_ped | 48 | unhandled |
| 6 |  | 467 | unhandled |
| 9 |  | 330 | unhandled |
| 10 |  | 8 | unhandled |
| 11 |  | 15 | unhandled |
| 14 |  | 228 | unhandled |
| 15 |  | 59 | unhandled |
| 16 |  | 655 | unhandled |
| 18 |  | 184 | unhandled |
| 20 |  | 100 | unhandled |
| 21 | counter | 1430 | A1 done |
| 23 | save_counter | 56 | A1 done |
| 26 |  | 8 | unhandled |
| 27 |  | 36 | unhandled |
| 30 |  | 413 | unhandled |
| 32 |  | 147 | unhandled |
| 35 |  | 50 | unhandled |
| 38 |  | 35 | unhandled |
| 39 |  | 8 | unhandled |
| 40 |  | 16 | unhandled |
| 41 |  | 18 | unhandled |
| 42 |  | 380 | unhandled |
| 43 |  | 48 | unhandled |
| 44 |  | 169 | unhandled |
| 45 |  | 1 | unhandled |
| 46 |  | 1 | unhandled |
| 47 |  | 66 | unhandled |
| 49 |  | 121 | unhandled |
| 52 |  | 1 | unhandled |
| 59 | level_start | 18 | A1 done |
| 60 | level_end | 18 | A1 done |
| 63 | exec | 41 | A1 done |
| 64 | endexec | 91 | A1 done |
| 67 | label | 276 | A1 done |
| 68 | return | 898 | A1 done |
| 71 | not | 643 | A1 done |
| 77 | endwhile | 380 | A1 done |
| 78 | gosub | 170 | A1 done |
| 86 | lt | 55 | A1 done |
| 90 | gt | 14 | A1 done |
| 92 | ge | 3 | A1 done |
| 94 | eq | 2825 | A1 done |
| 96 | inc | 495 | A1 done |
| 97 | dec | 246 | A1 done |
| 98 | if | 5535 | A1 done |
| 100 |  | 61 | unhandled |
| 101 |  | 4 | unhandled |
| 102 |  | 114 | unhandled |
| 103 |  | 72 | unhandled |
| 104 |  | 6 | unhandled |
| 105 |  | 6 | unhandled |
| 106 |  | 2 | unhandled |
| 107 |  | 35 | unhandled |
| 113 |  | 389 | unhandled |
| 114 |  | 208 | unhandled |
| 116 |  | 570 | unhandled |
| 117 | message | 901 | A1 done |
| 118 | brief | 778 | A1 done |
| 119 | timer | 48 | A1 done |
| 120 | timer_clear | 63 | A1 done |
| 121 |  | 284 | unhandled |
| 122 |  | 67 | unhandled |
| 123 |  | 65 | unhandled |
| 126 |  | 1 | unhandled |
| 127 |  | 469 | unhandled |
| 128 |  | 28 | unhandled |
| 129 |  | 1 | unhandled |
| 131 |  | 171 | unhandled |
| 132 |  | 194 | unhandled |
| 133 |  | 209 | unhandled |
| 134 |  | 130 | unhandled |
| 138 |  | 334 | unhandled |
| 139 |  | 4 | unhandled |
| 140 |  | 248 | unhandled |
| 141 |  | 224 | unhandled |
| 142 |  | 38 | unhandled |
| 144 |  | 43 | unhandled |
| 145 |  | 76 | unhandled |
| 146 |  | 47 | unhandled |
| 147 |  | 62 | unhandled |
| 151 |  | 363 | unhandled |
| 152 |  | 457 | unhandled |
| 153 |  | 80 | unhandled |
| 154 |  | 290 | unhandled |
| 157 |  | 3 | unhandled |
| 158 |  | 2 | unhandled |
| 160 |  | 110 | unhandled |
| 161 |  | 105 | unhandled |
| 162 |  | 56 | unhandled |
| 163 |  | 179 | unhandled |
| 164 |  | 29 | unhandled |
| 165 |  | 1 | unhandled |
| 166 |  | 1 | unhandled |
| 167 |  | 2 | unhandled |
| 171 |  | 7 | unhandled |
| 173 |  | 15 | unhandled |
| 175 |  | 1 | unhandled |
| 177 |  | 66 | unhandled |
| 178 |  | 18 | unhandled |
| 179 |  | 31 | unhandled |
| 180 |  | 74 | unhandled |
| 182 |  | 41 | unhandled |
| 183 |  | 57 | unhandled |
| 184 |  | 6 | unhandled |
| 185 |  | 110 | unhandled |
| 186 |  | 141 | unhandled |
| 187 |  | 95 | unhandled |
| 188 |  | 4 | unhandled |
| 189 |  | 6 | unhandled |
| 190 |  | 77 | unhandled |
| 194 |  | 68 | unhandled |
| 195 |  | 3 | unhandled |
| 198 |  | 2 | unhandled |
| 205 |  | 183 | unhandled |
| 211 | car_trigger | 22 | unhandled |
| 213 | phone_trigger | 55 | unhandled |
| 214 | area_trigger | 49 | unhandled |
| 215 | trigger_on | 1 | A1 done |
| 216 | trigger_off | 60 | A1 done |
| 218 |  | 34 | unhandled |
| 223 |  | 15 | unhandled |
| 224 |  | 9 | unhandled |
| 226 |  | 22 | unhandled |
| 229 |  | 1 | unhandled |
| 230 |  | 9 | unhandled |
| 231 |  | 6 | unhandled |
| 232 |  | 34 | unhandled |
| 233 | display_decl | 20 | A1 done |
| 234 |  | 15 | unhandled |
| 235 |  | 10 | unhandled |
| 236 |  | 4 | unhandled |
| 237 |  | 1 | unhandled |
| 238 |  | 8 | unhandled |
| 240 |  | 7 | unhandled |
| 241 |  | 3 | unhandled |
| 242 |  | 102 | unhandled |
| 243 |  | 20 | unhandled |
| 244 |  | 1 | unhandled |
| 245 |  | 66 | unhandled |
| 246 |  | 9 | unhandled |
| 247 |  | 5 | unhandled |
| 248 |  | 11 | unhandled |
| 249 |  | 11 | unhandled |
| 251 |  | 79 | unhandled |
| 253 |  | 11 | unhandled |
| 254 |  | 14 | unhandled |
| 256 |  | 4 | unhandled |
| 257 |  | 39 | unhandled |
| 258 |  | 249 | unhandled |
| 259 |  | 15 | unhandled |
| 260 |  | 32 | unhandled |
| 261 |  | 32 | unhandled |
| 262 |  | 20 | unhandled |
| 263 | gang_phone | 27 | A1 done |
| 264 |  | 1 | unhandled |
| 265 |  | 44 | unhandled |
| 266 |  | 21 | unhandled |
| 267 |  | 5 | unhandled |
| 268 |  | 544 | unhandled |
| 270 |  | 101 | unhandled |
| 271 |  | 5 | unhandled |
| 272 | mission_begin | 67 | A1 done |
| 273 | mission_end | 67 | A1 done |
| 274 | mission | 19 | A1 done |
| 275 |  | 22 | unhandled |
| 276 | counter_v | 364 | A1 done |
| 278 |  | 65 | unhandled |
| 279 | brief_now | 965 | A1 done |
| 282 |  | 82 | unhandled |
| 283 |  | 4 | unhandled |
| 284 |  | 12 | unhandled |
| 285 |  | 20 | unhandled |
| 286 |  | 2 | unhandled |
| 287 |  | 42 | unhandled |
| 288 | challenge | 81 | A1 done |
| 290 | challenge_c | 7 | A1 done |
| 292 | challenge_passed | 28 | A1 done |
| 293 | challenge_failed | 25 | A1 done |
| 294 | challenge_done | 18 | A1 done |
| 299 |  | 3 | unhandled |
| 300 |  | 3 | unhandled |
| 301 |  | 50 | unhandled |
| 302 |  | 2 | unhandled |
| 303 |  | 8 | unhandled |
| 304 |  | 9 | unhandled |
| 305 |  | 3 | unhandled |
| 306 |  | 11 | unhandled |
| 307 |  | 85 | unhandled |
| 308 |  | 10 | unhandled |
| 309 |  | 6 | unhandled |
| 310 |  | 78 | unhandled |
| 311 |  | 31 | unhandled |
| 312 |  | 8 | unhandled |
| 313 |  | 20 | unhandled |
| 315 |  | 8 | unhandled |
| 316 |  | 11 | unhandled |
| 317 | clear_briefs | 810 | A1 done |
| 318 |  | 3 | unhandled |
| 319 |  | 103 | unhandled |
| 321 | brief_soon | 8 | A1 done |
| 325 | brief_showing | 3 | A1 done |
| 326 |  | 144 | unhandled |
| 327 |  | 192 | unhandled |
| 328 |  | 159 | unhandled |
| 329 | gang_phone_open | 18 | A1 done |
| 330 |  | 39 | unhandled |
| 334 |  | 9 | unhandled |
| 335 |  | 3 | unhandled |
| 338 |  | 3 | unhandled |
| 340 | set | 3605 | A1 done |
| 342 |  | 6 | unhandled |
| 343 |  | 3 | unhandled |
| 344 |  | 3 | unhandled |
| 345 |  | 3 | unhandled |
| 346 |  | 3 | unhandled |
| 347 |  | 3 | unhandled |
| 348 |  | 3 | unhandled |
| 349 |  | 3 | unhandled |
| 350 |  | 5 | unhandled |
| 353 |  | 6 | unhandled |
| 355 |  | 55 | unhandled |
| 356 |  | 74 | unhandled |
| 357 |  | 17 | unhandled |
| 358 |  | 18 | unhandled |
| 359 |  | 11 | unhandled |
| 360 |  | 82 | unhandled |
| 361 |  | 4 | unhandled |
| 362 |  | 35 | unhandled |
| 363 |  | 6 | unhandled |
| 364 |  | 47 | unhandled |
| 365 |  | 8 | unhandled |
| 366 |  | 1 | unhandled |
| 367 |  | 22 | unhandled |
| 368 |  | 1 | unhandled |
| 369 |  | 1 | unhandled |
| 370 |  | 2 | unhandled |
| 371 |  | 1 | unhandled |
| 373 |  | 4 | unhandled |
| 375 |  | 4 | unhandled |
| 378 |  | 45 | unhandled |
| 381 |  | 20 | unhandled |
| 382 |  | 6 | unhandled |
| 386 |  | 3 | unhandled |
| 387 |  | 3 | unhandled |
| 388 |  | 3 | unhandled |
| 389 |  | 3 | unhandled |
| 390 |  | 3 | unhandled |
| 391 | mission_cleanup | 67 | A1 done |
| 392 |  | 1 | unhandled |
| 393 |  | 148 | unhandled |
| 395 |  | 40 | unhandled |
| 398 |  | 3 | unhandled |
| 399 |  | 31 | unhandled |
| 400 |  | 3 | unhandled |
| 401 | challenge_dead | 72 | A1 done |
| 402 | challenge_progress | 10 | A1 done |
| 403 |  | 1 | unhandled |
| 406 |  | 62 | unhandled |
| 407 |  | 4 | unhandled |
| 408 |  | 29 | unhandled |
| 410 |  | 6 | unhandled |
| 413 | counter_display_decl | 18 | A1 done |
| 414 | show_counter | 28 | A1 done |
| 415 | counter_clear | 24 | A1 done |
| 416 | clock_clear | 1 | A1 done |
| 417 |  | 2 | unhandled |
| 418 |  | 2 | unhandled |
| 419 |  | 15 | unhandled |
| 421 |  | 2 | unhandled |
| 422 | frenzy | 60 | A1 done |
| 423 | frenzy_run | 60 | A1 done |
| 424 |  | 100 | unhandled |
| 425 |  | 180 | unhandled |
| 426 |  | 248 | unhandled |
| 429 |  | 3 | unhandled |
| 430 |  | 3 | unhandled |
| 431 |  | 3 | unhandled |
| 432 |  | 28 | unhandled |
| 435 |  | 3 | unhandled |
| 436 |  | 3 | unhandled |
| 437 |  | 3 | unhandled |
| 438 |  | 3 | unhandled |
| 439 |  | 16 | unhandled |
| 441 |  | 3 | unhandled |
| 442 |  | 8 | unhandled |
| 443 |  | 58 | unhandled |
| 444 |  | 144 | unhandled |

287 types: 50 A1 done, 0 A2 done, 0 A2 stubbed, 237 unhandled.
