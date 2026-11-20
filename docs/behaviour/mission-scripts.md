# Mission scripts (.scr): loading and execution model

- **System:** How the game loads a level's compiled mission script and its separate mission scripts, how declarations are applied at level start, how script threads run each tick (one command per tick, plus the run-to-the-end blocks), how threads are triggered by phones and cars, and what happens to a running mission when the player dies or is arrested.
- **Out of scope (separate reference notes to follow):** the meaning of each individual script command (several hundred). This note gives the machinery an implementer needs before writing any command.
- **Sources read:** the decompilation's script manager (file loading, string table, mission sub-script loading, the per-tick thread update), the level-start declaration pass, thread spawning, the phone and car trigger tables, and the mission-fail-on-death handling.
- **Date and author:** 2026-11-19, Claude (notes writer, reader side).

Tags: **[scr]** the compiled script file format, **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

Each level runs a main script that sets up the city (parked cars, phones, gangs, zones, cranes, pickups) and starts background routines. Answering a ringing phone, or getting into a particular car, starts a mission routine. Missions give instructions, spawn targets, wait for things to happen, and pay out or fail. Dying or being arrested during a mission fails it with a message.

## 2. Inputs: the compiled script file [scr]

The main script file (one per level, e.g. `data\<level>.scr`) contains, in order:

1. **Command offset table:** 6000 unsigned 16-bit entries. Entry `i` is the byte offset of command `i` within the command data; 0 means no command. Command numbers are the "line" numbers that commands use to jump to each other.
2. **Command data:** 65536 bytes of packed commands. Each command starts with a header of four signed 16-bit values: its own command number, its **type** (which command it is), the number of the next command, and a "return value" field. The type-specific parameters follow.
3. **String table size:** an unsigned 16-bit byte count.
4. **String table:** that many bytes of entries. Each entry has a 9-byte header, whose last byte is the text length, followed by the text. At load time every name is looked up as a map zone name, so scripts can refer to zones by name. Entries of string type 21 name **mission sub-scripts**.

**Mission sub-scripts** are separate files under `data\<level>\<name>SCR`. Each holds:

- the offset-table slot where its commands start (u16);
- its start command number (u16);
- its data length (u32);
- 3072 bytes of offset entries to copy into the main offset table at that slot;
- its command data, copied into the main command data at the slot's offset.

The game can either preload every mission at level start (up to a fixed size per mission) or read each one from disk when it starts. The behaviour is the same either way.

## 3. Rules

### 3.1 Level start

1. Load the main file and string table, then (optionally) all mission sub-scripts.
2. **Declaration pass:** go through every command from 1 to 5999. Each command of a *declaration* type is applied once, regardless of thread flow. This covers the player ped, cars, characters, objects (in their several forms), map zone settings, arrows, cranes, and the other setup commands. This is how the city is populated before anything runs.
3. Find the command of type **level start** (type 59). If there isn't one, it's a fatal error. Start the first thread at that command.

### 3.2 Threads

- A thread has a current command number, flags, a condition result (for IF-style commands), a gosub return stack, a phone timer, and a "stopped" flag.
- Threads are created by commands (and by the triggers in 3.4) and run in creation order every tick.
- **Each tick, each running thread** does exactly one of these:
  - **Normal command:** execute one command and advance to its next command. Most commands take one tick, so scripts naturally run at one line per tick.
  - **EXEC block:** if the current command is a "start exec", keep executing commands in the same tick until the matching "end exec".
  - **WHILE_EXEC block:** if the current command has its return-value field set to 1, keep executing commands in the same tick while each next command also has it set, or until an "end exec" or the end of the level.
- A thread whose next command becomes 65535 (0xFFFF) has reached **level end**.
- A thread marked stopped does nothing.

### 3.3 Mission fail on death or arrest

Each tick, before a thread runs its command:

- if the script has asked to be told about death or arrest,
- and a mission is flagged as in progress,
- and the local player is wasted or busted (other than being taken away by police during the arrest sequence),

then the thread's gosub stack is unwound by two levels and it returns from the mission routine. A random one of five "mission failed" messages is shown: one set for death, another for arrest.

### 3.4 Triggers

- **Phones:** a script can attach a thread start point to a phone object for a given ped. When that ped touches the phone, the thread starts there. Answered phones are remembered and saved.
- **Cars:** a script can attach a thread start point to a car for a given ped. When that ped enters that car, the thread starts.
- **Save points and other triggers** are objects that, when touched, start a thread or run a save.
- **Weapon hits:** every projectile hit and electro-gun hit on a ped or car is recorded per entity and weapon, so scripts can test "was this hit by X".

### 3.5 Counters and saves

Script counters, answered phones and map changes are saved and restored with the game (save-game note).

## 4. Order of events

- **Level load:** read files, declaration pass, start the level-start thread.
- **Every tick,** in the game update: run all threads (3.2), each preceded by the fail check (3.3). Then clear the "car model destroyed" notification flag.

## 5. Numbers

| Value | Meaning | Source |
|---|---|---|
| 6000 | command slots | [scr] |
| 65536 bytes | command data size | [scr] |
| 8 bytes | command header (4 × 16-bit) | [scr] |
| 9 bytes | string table entry header | [scr] |
| 3072 bytes | offset entries per mission sub-script | [scr] |
| 59 | "level start" command type | [scr] |
| 0xFFFF | "level end" command number | [scr] |
| 1 command per tick | default thread speed | [exe] |

## 6. Edge cases and quirks worth reproducing

- **Declarations ignore control flow.** A car declared inside an unreachable branch still appears at level start.
- **One line per tick** is part of mission timing. Waits, message timings and race checkpoints assume it. Use EXEC blocks only where the original does.
- **Mission fail unwinds exactly two levels** of gosub. Scripts are written to expect that.

## 7. Open questions

- A per-command reference: parameters, effects and tick behaviour for each command type. This is the largest remaining piece of work and should be split by command family (declarations, cars, characters, objects, player, flow control, messages, counters, missions).
- The exact list of declaration types run in the level-start pass.
- Save-game layout (separate note).
