# Memo: using the gta2_re decompilation as a reference

Nov 19, 2026. Not legal advice. This is a research summary to help decide how the project works; get a lawyer's view before any public release.

## Recommendation

Keep using gta2_re, but only through a written spec, never by reading it while writing our code. One person or agent reads the decompilation and writes plain-English behaviour notes (what happens, in what order, which file fields matter). A different person or agent writes the Zig sim from those notes and the published DMA format docs, and never opens gta2_re. Treat the throwaway S5 handling code as tainted: rebuild car handling in workstream A from notes, not by porting S5.

This costs little (one notes file per system, a short review step) and moves the project from "Take-Two's code, re-typed" to "independent code that interoperates with the game's data files", which is the position the precedents favour. It does not remove the larger risk, which is Take-Two objecting to a GTA2 game in the browser at all.

## What "no licence" means for gta2_re

- With no licence file, the code is all-rights-reserved by default. GitHub's terms let anyone view and fork a public repo on GitHub, and nothing more: no right to copy, modify or redistribute it ([choosealicense.com](https://choosealicense.com/no-permission/), [GitHub docs](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository)).
- Reading it to learn how the game behaves is not copying. Copyright protects expression, not ideas, behaviour or facts. Taking code, its structure or its comments into our repo would be copying.
- A licence from the gta2_re authors would not fix much anyway. gta2_re is a *matching* decompilation of GTA2 v10.5, built to reproduce the original binary as exactly as possible ([project hub](https://valps.github.io/gta2-re-hub/getting_started/)). Its code is very likely a derivative of Rockstar's code, so the rights that matter belong to Take-Two, and the volunteers could not grant them. The practical risk is Take-Two, not CriminalRETeam.

So the licence gap is a reason not to copy from gta2_re, and it is no reason to avoid learning from it, provided what we learn reaches our code only as facts.

## Precedents

| Project | How it was built | What happened | Lesson |
| --- | --- | --- | --- |
| re3 / reVC (GTA III, Vice City) | Decompiled C++ that reproduces the original code; players supply game data | DMCA takedown Feb 2021; counter-notice put it back; Take-Two sued Sept 2021; defendants argued fair use and interoperability; settled April 2023 on undisclosed terms ([TorrentFreak](https://torrentfreak.com/gta-modders-to-court-our-game-fixes-enhancements-are-fair-use-211116/), [GamesRadar](https://www.gamesradar.com/gta-owner-settles-lawsuit-against-creators-of-vice-city-reverse-engineering-project-before-case-reaches-court)) | Take-Two acts against decompiled GTA code even when no data is shipped. "Players supply their own copy" did not prevent the suit. This is the closest precedent to gta2_re itself. |
| Vice City in the browser (DOS.Zone, Dec 2025) | Browser build, reportedly reVC; users uploaded their own game files | Removed after a takedown email from a brand-protection firm acting for Take-Two, citing artwork, logos and branding ([GamesRadar](https://www.gamesradar.com/games/grand-theft-auto/gta-vice-city-was-briefly-playable-in-your-web-browser-until-rockstar-owner-take-two-reportedly-struck-it-down), [GamingBible](https://www.gamingbible.com/news/free-gta-vice-city-browser-removed-281240-20251224)) | Take-Two watches browser ports specifically, and goes after names and branding as well as code. Builds have since reappeared on other sites ([Tom's Hardware](https://www.tomshardware.com/video-games/gta-vice-city-and-gta-iii-return-to-web-browsers-after-a-dmca-takedown-open-source-reverse-engineering-brings-the-classics-to-the-web-with-over-100-fps-performance)). |
| OpenRCT2 (RollerCoaster Tycoon 2) | Began in 2014 as a disassembly-guided reimplementation that hooked into the original exe, then replaced function by function; GPLv3; needs the original data | Running for over a decade with no takedown ([repo](https://github.com/openrct2/OpenRCT2), [forum thread on legality](https://forums.openrct2.org/topic/5646-how-is-openrct2-legal)) | Decompilation-derived engines can survive, but it depends on a tolerant rights holder. Atari is not Take-Two. |
| OpenMW (Morrowind) | Reimplemented from observed behaviour and file formats, not from disassembled code; GPLv3; needs the original data | Long-running and tolerated by Bethesda | The cleanest model, and the one this project's design already resembles. |

Two legal principles stand behind the clean-room route. US courts have held that copying a program in order to learn its unprotected interfaces can be fair use when the result is independent (Sega v. Accolade, 1992; Sony v. Connectix, 2000). In the EU, functionality, programming languages and data file formats are not protected by software copyright (SAS Institute v. World Programming, CJEU 2012), and the Software Directive permits decompilation for interoperability within limits. Neither principle protects code that is a translation of the original. (Case citations are from background knowledge, not re-checked for this memo.)

## Where the project stands now

- The design already avoids the worst exposure: a fresh engine in Zig, no original data shipped, players and operators supply their own files.
- S5 reads handling constants from the player's own `nyc.gci` at runtime and falls back to invented placeholders. That part is fine: the numbers come from the user's copy, not from us.
- S5 used gta2_re as a behavioural reference before this check. Its source is not in the repo (only `site/s5/handling.wasm`). If its physics code follows gta2_re's functions closely, it is the part most at risk of being called a translation. It is spike code and is already planned to be thrown away, so the fix is to make sure it stays thrown away.
- The tester site uses the names "GTA2" and the original file names in prose. Descriptive use is normal, but a public build should not use Rockstar or GTA logos, artwork or a GTA-style title. That is what the DOS.Zone notice cited.

## Clean-room options, cheapest first

1. **Rules only.** Contributors may read gta2_re but must not paste, port or transliterate from it, and must cite only behaviour in commit messages. Cheap and weak: it relies on discipline and leaves no record.
2. **Notes split (recommended).** A reader writes behaviour notes in `docs/behaviour/` (for example "car turning: grip falls off with speed by the `.gci` field X; handbrake does Y"). Notes hold facts, formulas in our own words and file-field meanings, never code, function names or structure. Implementers work only from notes, the DMA format docs, footage and the player's own files. Each sim PR states which notes it used. With agents this is easy to enforce: the implementing agent simply never gets gta2_re in its context.
3. **Black-box only, as OpenMW does.** No one reads gta2_re; behaviour comes from footage, playing the game and measuring, and the data files. Safest, but S5 shows handling is the hard part, and this adds tuning time the plan already budgets as a fallback.

Option 2 keeps the benefit of the decompilation for handling and file layouts at little cost. Option 3 is the step up if a lawyer advises it before public release.

## Decisions for Jeff

- Adopt option 2 and mark the design doc's "Reference for behaviour" row as resolved, with S5 handling code to be rewritten from notes.
- The open question on public release matters more than this one. Private play among owners carries much lower practical risk than a public site, given the DOS.Zone precedent. Whichever is chosen, get legal advice before a public link goes out, as the design doc already says.
