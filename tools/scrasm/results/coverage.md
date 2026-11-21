# Script coverage

Written by `tools/scrasm coverage` (workstream A1) from the player's own level scripts: type numbers and counts only. Each level is also loaded into the sim on the synthetic test map and run for 3000 ticks with no player.

## Levels

| level | missions | commands | threads at end | unhandled met | stuck threads |
|---|---|---|---|---|---|
| bil | 22 | 1060 | 1 | 36 | 0 |
| downtown-6p | 0 | 472 | 0 | 6 | 0 |
| industrial-6p | 0 | 582 | 0 | 12 | 0 |
| lorne2e | 0 | 467 | 1 | 64 | 0 |
| lorne2h | 0 | 470 | 1 | 68 | 0 |
| lorne2m | 0 | 469 | 1 | 65 | 0 |
| mike1e | 0 | 662 | 1 | 69 | 0 |
| mike1h | 0 | 655 | 1 | 65 | 0 |
| mike1m | 0 | 656 | 1 | 65 | 0 |
| mike2e | 0 | 222 | 0 | 26 | 0 |
| mike2h | 0 | 222 | 0 | 26 | 0 |
| mike2m | 0 | 222 | 0 | 26 | 0 |
| mp1-6p | 0 | 61 | 0 | 5 | 0 |
| mp2-6p | 0 | 115 | 0 | 42 | 0 |
| mp5-6p | 0 | 125 | 0 | 42 | 0 |
| res-6p | 0 | 458 | 0 | 50 | 0 |
| ste | 22 | 1546 | 1 | 365 | 0 |
| wil | 23 | 1266 | 1 | 3021 | 0 |

## Command types used

| type | name | uses | handler |
|---|---|---|---|
| 5 | player_ped | 48 | A2 done |
| 6 |  | 467 | unhandled |
| 9 |  | 330 | unhandled |
| 10 |  | 8 | A2 done |
| 11 |  | 15 | A2 done |
| 14 |  | 228 | unhandled |
| 15 |  | 59 | A2 done |
| 16 |  | 655 | A2 done |
| 18 |  | 184 | A2 done |
| 20 |  | 100 | A2 done |
| 21 | counter | 1430 | A1 done |
| 23 | arrow | 56 | A1 done |
| 26 |  | 8 | A2 done |
| 27 |  | 36 | A2 done |
| 30 |  | 413 | A2 done |
| 32 |  | 147 | A2 done |
| 35 |  | 50 | A2 done |
| 38 |  | 35 | A2 stubbed |
| 39 |  | 8 | A2 stubbed |
| 40 |  | 16 | A2 done |
| 41 |  | 18 | A2 done |
| 42 |  | 380 | A2 done |
| 43 |  | 48 | A2 done |
| 44 |  | 169 | A2 done |
| 45 |  | 1 | A2 done |
| 46 |  | 1 | A2 done |
| 47 |  | 66 | A2 done |
| 49 |  | 121 | A2 done |
| 52 |  | 1 | A2 done |
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
| 100 |  | 61 | A2 done |
| 101 |  | 4 | unhandled |
| 102 |  | 114 | A2 done |
| 103 |  | 72 | unhandled |
| 104 |  | 6 | unhandled |
| 105 |  | 6 | unhandled |
| 106 |  | 2 | unhandled |
| 107 |  | 35 | unhandled |
| 113 | arrow_at | 389 | A1 done |
| 114 | arrow_pos | 208 | A1 done |
| 116 | arrow_clear | 570 | A1 done |
| 117 | message | 901 | A1 done |
| 118 | brief | 778 | A1 done |
| 119 | timer | 48 | A1 done |
| 120 | timer_clear | 63 | A1 done |
| 121 |  | 284 | A2 done |
| 122 |  | 67 | A2 done |
| 123 |  | 65 | A2 done |
| 126 |  | 1 | A2 done |
| 127 |  | 469 | A2 done |
| 128 |  | 28 | A2 done |
| 129 |  | 1 | A2 done |
| 131 |  | 171 | A2 done |
| 132 |  | 194 | A2 done |
| 133 |  | 209 | A2 done |
| 134 |  | 130 | unhandled |
| 138 |  | 334 | A2 done |
| 139 |  | 4 | A2 done |
| 140 |  | 248 | A2 done |
| 141 |  | 224 | A2 done |
| 142 |  | 38 | A2 done |
| 144 |  | 43 | A2 done |
| 145 |  | 76 | A2 done |
| 146 |  | 47 | A2 done |
| 147 |  | 62 | A2 done |
| 151 |  | 363 | A2 done |
| 152 |  | 457 | A2 done |
| 153 |  | 80 | A2 done |
| 154 |  | 290 | A2 done |
| 157 |  | 3 | A2 done |
| 158 |  | 2 | A2 done |
| 160 |  | 110 | A2 stubbed |
| 161 |  | 105 | unhandled |
| 162 |  | 56 | unhandled |
| 163 |  | 179 | A2 done |
| 164 |  | 29 | A2 done |
| 165 |  | 1 | A2 done |
| 166 |  | 1 | A2 done |
| 167 |  | 2 | A2 done |
| 171 |  | 7 | A2 done |
| 173 |  | 15 | unhandled |
| 175 |  | 1 | A2 done |
| 177 |  | 66 | A2 done |
| 178 |  | 18 | A2 done |
| 179 |  | 31 | A2 done |
| 180 |  | 74 | A2 done |
| 182 |  | 41 | unhandled |
| 183 |  | 57 | unhandled |
| 184 |  | 6 | unhandled |
| 185 |  | 110 | unhandled |
| 186 |  | 141 | unhandled |
| 187 |  | 95 | unhandled |
| 188 |  | 4 | A2 stubbed |
| 189 |  | 6 | A2 done |
| 190 |  | 77 | A2 done |
| 194 |  | 68 | A2 done |
| 195 |  | 3 | A2 done |
| 198 |  | 2 | A2 stubbed |
| 205 |  | 183 | unhandled |
| 211 | car_trigger | 22 | A2 done |
| 213 | phone_trigger | 55 | A2 done |
| 214 | area_trigger | 49 | A2 done |
| 215 | trigger_on | 1 | A1 done |
| 216 | trigger_off | 60 | A1 done |
| 218 |  | 34 | unhandled |
| 223 |  | 15 | A2 stubbed |
| 224 |  | 9 | unhandled |
| 226 |  | 22 | unhandled |
| 229 |  | 1 | A2 done |
| 230 |  | 9 | A2 done |
| 231 |  | 6 | A2 stubbed |
| 232 |  | 34 | A2 stubbed |
| 233 | display_decl | 20 | A1 done |
| 234 |  | 15 | A2 done |
| 235 |  | 10 | A2 done |
| 236 |  | 4 | A2 done |
| 237 |  | 1 | A2 done |
| 238 |  | 8 | unhandled |
| 240 |  | 7 | A2 done |
| 241 |  | 3 | A2 stubbed |
| 242 |  | 102 | A2 done |
| 243 |  | 20 | A2 done |
| 244 |  | 1 | A2 stubbed |
| 245 |  | 66 | A2 done |
| 246 |  | 9 | A2 stubbed |
| 247 |  | 5 | A2 stubbed |
| 248 |  | 11 | unhandled |
| 249 |  | 11 | unhandled |
| 251 |  | 79 | A2 done |
| 253 |  | 11 | A2 done |
| 254 |  | 14 | A2 done |
| 256 |  | 4 | A2 done |
| 257 |  | 39 | unhandled |
| 258 |  | 249 | A2 stubbed |
| 259 |  | 15 | A2 done |
| 260 |  | 32 | unhandled |
| 261 |  | 32 | unhandled |
| 262 |  | 20 | A2 stubbed |
| 263 | gang_phone | 27 | A1 done |
| 264 |  | 1 | A2 done |
| 265 |  | 44 | A2 done |
| 266 |  | 21 | A2 done |
| 267 |  | 5 | A2 done |
| 268 |  | 544 | A2 done |
| 270 |  | 101 | A2 done |
| 271 |  | 5 | unhandled |
| 272 | mission_begin | 67 | A1 done |
| 273 | mission_end | 67 | A1 done |
| 274 | mission | 19 | A1 done |
| 275 |  | 22 | unhandled |
| 276 | counter_v | 364 | A1 done |
| 278 |  | 65 | A2 stubbed |
| 279 | brief_now | 965 | A1 done |
| 282 |  | 82 | A2 done |
| 283 |  | 4 | unhandled |
| 284 |  | 12 | unhandled |
| 285 |  | 20 | A2 stubbed |
| 286 |  | 2 | A2 stubbed |
| 287 |  | 42 | A2 stubbed |
| 288 | challenge | 81 | A1 done |
| 290 | challenge_c | 7 | A1 done |
| 292 | challenge_passed | 28 | A1 done |
| 293 | challenge_failed | 25 | A1 done |
| 294 | challenge_done | 18 | A1 done |
| 299 |  | 3 | unhandled |
| 300 |  | 3 | unhandled |
| 301 |  | 50 | unhandled |
| 302 |  | 2 | A2 stubbed |
| 303 |  | 8 | A2 stubbed |
| 304 |  | 9 | A2 done |
| 305 |  | 3 | A2 done |
| 306 |  | 11 | A2 stubbed |
| 307 |  | 85 | A2 stubbed |
| 308 |  | 10 | unhandled |
| 309 |  | 6 | unhandled |
| 310 |  | 78 | A2 stubbed |
| 311 |  | 31 | A2 stubbed |
| 312 |  | 8 | A2 stubbed |
| 313 |  | 20 | A2 stubbed |
| 315 |  | 8 | A2 done |
| 316 |  | 11 | A2 stubbed |
| 317 | clear_briefs | 810 | A1 done |
| 318 |  | 3 | unhandled |
| 319 |  | 103 | unhandled |
| 321 | brief_soon | 8 | A1 done |
| 325 | brief_showing | 3 | A1 done |
| 326 |  | 144 | unhandled |
| 327 |  | 192 | A2 stubbed |
| 328 |  | 159 | unhandled |
| 329 | gang_phone_open | 18 | A1 done |
| 330 |  | 39 | A2 done |
| 334 |  | 9 | unhandled |
| 335 |  | 3 | unhandled |
| 338 |  | 3 | unhandled |
| 340 | set | 3605 | A1 done |
| 342 |  | 6 | A2 done |
| 343 |  | 3 | A2 done |
| 344 |  | 3 | A2 done |
| 345 |  | 3 | A2 done |
| 346 |  | 3 | A2 done |
| 347 |  | 3 | A2 done |
| 348 |  | 3 | A2 done |
| 349 |  | 3 | A2 done |
| 350 |  | 5 | unhandled |
| 353 |  | 6 | A2 done |
| 355 |  | 55 | A2 done |
| 356 |  | 74 | A2 stubbed |
| 357 |  | 17 | A2 done |
| 358 |  | 18 | A2 done |
| 359 |  | 11 | A2 stubbed |
| 360 |  | 82 | A2 done |
| 361 |  | 4 | A2 stubbed |
| 362 |  | 35 | A2 done |
| 363 |  | 6 | A2 done |
| 364 |  | 47 | A2 done |
| 365 |  | 8 | unhandled |
| 366 |  | 1 | A2 done |
| 367 |  | 22 | A2 done |
| 368 |  | 1 | A2 done |
| 369 |  | 1 | A2 stubbed |
| 370 |  | 2 | A2 stubbed |
| 371 |  | 1 | A2 done |
| 373 |  | 4 | unhandled |
| 375 |  | 4 | A2 done |
| 378 |  | 45 | A2 done |
| 381 |  | 20 | A2 done |
| 382 |  | 6 | A2 done |
| 386 |  | 3 | A2 done |
| 387 |  | 3 | A2 done |
| 388 |  | 3 | A2 done |
| 389 |  | 3 | A2 done |
| 390 |  | 3 | A2 done |
| 391 | mission_cleanup | 67 | A1 done |
| 392 |  | 1 | A2 done |
| 393 |  | 148 | A2 stubbed |
| 395 |  | 40 | A2 done |
| 398 |  | 3 | A2 done |
| 399 |  | 31 | A2 done |
| 400 |  | 3 | A2 done |
| 401 | challenge_dead | 72 | A1 done |
| 402 | challenge_progress | 10 | A1 done |
| 403 |  | 1 | A2 done |
| 406 |  | 62 | A2 done |
| 407 |  | 4 | A2 done |
| 408 |  | 29 | A2 stubbed |
| 410 |  | 6 | A2 done |
| 413 | counter_display_decl | 18 | A1 done |
| 414 | show_counter | 28 | A1 done |
| 415 | counter_clear | 24 | A1 done |
| 416 | clock_clear | 1 | A1 done |
| 417 |  | 2 | A2 stubbed |
| 418 |  | 2 | A2 done |
| 419 |  | 15 | A2 done |
| 421 |  | 2 | A2 done |
| 422 | frenzy | 60 | A1 done |
| 423 | frenzy_run | 60 | A1 done |
| 424 |  | 100 | unhandled |
| 425 |  | 180 | A2 done |
| 426 |  | 248 | A2 done |
| 429 |  | 3 | A2 done |
| 430 |  | 3 | A2 done |
| 431 |  | 3 | A2 done |
| 432 |  | 28 | A2 done |
| 435 |  | 3 | A2 done |
| 436 |  | 3 | A2 done |
| 437 |  | 3 | A2 done |
| 438 |  | 3 | unhandled |
| 439 |  | 16 | A2 stubbed |
| 441 |  | 3 | unhandled |
| 442 |  | 8 | unhandled |
| 443 |  | 58 | A2 done |
| 444 |  | 144 | A2 done |

287 types: 53 A1 done, 145 A2 done, 37 A2 stubbed, 52 unhandled.
