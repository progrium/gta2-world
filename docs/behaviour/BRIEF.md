# Brief for the notes writer

You are the **reader** in a clean-room split. You read the gta2_re decompilation (github.com/CriminalRETeam/gta2_re) and write behaviour notes. A separate implementer, who never sees gta2_re, writes a new engine in Zig from your notes alone. Your notes are the only thing that crosses between the two sides, so they must carry facts about behaviour and nothing of the decompiled code's expression.

## What to produce

One Markdown file per system in `docs/behaviour/`, for example `car-handling.md`, `ped-movement.md`, `collision.md`, `weapons.md`. Start each file with:

- **System:** what it covers.
- **Sources read:** which areas of gta2_re you read (a short description, not file paths or function names), plus any public docs or footage.
- **Date and author.**

Then describe the behaviour under these headings, skipping any that don't apply:

1. **What the player sees.** The behaviour in plain language, as someone who knows the game would describe it.
2. **Inputs.** Which controls and which game-data fields affect it. Name data fields by what they mean and by their position in the published file format (for example "the 5th numeric field of a `.gci` car record, which sets grip"), since the format is something the implementer may know.
3. **Rules.** How the state changes each tick, in your own words. Write maths as ordinary formulas with descriptive names (`speed falls by drag × speed each tick`), not as transcribed code.
4. **Order of events.** Where ordering matters (for example "collisions are resolved before handbrake is applied"), list the steps.
5. **Numbers.** Values that are game facts: tick rate, units, ranges, thresholds. Say where each one comes from: the player's data files (preferred, since the implementer reads those at runtime), observed behaviour, or a value fixed in the executable.
6. **Edge cases and quirks.** Known oddities worth reproducing, and how to observe them in the real game.
7. **Open questions.** Anything you couldn't work out.

## What must not appear

- No code or pseudocode that follows the decompiled code line by line, in any language.
- No function, variable, class or file names from gta2_re, and no addresses or offsets in the executable.
- No struct layouts, field orders or memory layouts of the game's internal state. (Layouts of the published data **files**, such as `.gmp`, `.sty`, `.scr` and `.gci`, are fine, because those are interoperability facts.)
- No copied comments, and no long run of steps that mirrors the code's control flow when the behaviour can be described more simply.
- No long tables of constants copied from the executable. If a value only exists in the exe, note the single value and what it means, and flag it.

A quick test: if someone could rebuild the decompiled function's structure from your note, rewrite the note at a higher level.

## Process

- Write each notes file on its own branch and commit it with "notes:" at the start of the message.
- Jeff reviews each file before an implementer uses it. Expect edits that lift a note to a higher level.
- Do not take part in implementation, and do not review implementation PRs against gta2_re.
- If the implementer has a question, answer it by updating the notes file, not by sending code or excerpts.
