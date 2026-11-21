//! Tests: the mission script VM (workstream A1), one or more per numbered
//! rule in mission-scripts.md, script-flow-control.md, script-counters.md,
//! script-messages.md and script-missions.md. Every script is written with
//! scrasm (formats/scr.zig) in the test; no game data.

const std = @import("std");
const formats = @import("formats");
const h_ = @import("harness.zig");
const simmod = h_.simmod;
const abi = h_.abi;
const fx = h_.fx;
const c = h_.c;
const testmap = h_.testmap;
const Frame = h_.Frame;
const EntityId = abi.EntityId;
const vm = simmod.sp_state.script;
const hudm = simmod.sp_state.hud;

/// A small single-player configuration (its name starts with "sp").
const cfg: abi.Config = .{ .name = "sp_test", .max_players = 1, .car_capacity = 16, .ped_capacity = 32, .projectile_capacity = 16, .pickup_capacity = 4, .map_object_capacity = 16 };
const S = simmod.Sim(cfg);
const V = S.script;
const H = S.hud;

const Run = struct {
    gpa: std.mem.Allocator,
    grid: *h_.map.Grid,
    sim: *S,
    asmd: formats.scr.Assembled,
    level: simmod.Level,
    frames: [1]Frame = .{Frame.neutral(0)},

    fn init(text: []const u8) !*Run {
        const gpa = std.testing.allocator;
        const r = try gpa.create(Run);
        errdefer gpa.destroy(r);
        var line: usize = 0;
        const asmd = formats.scr.assemble(gpa, text, &line) catch |e| {
            std.debug.print("scrasm error at line {d}: {s}\n", .{ line, @errorName(e) });
            return e;
        };
        r.* = .{ .gpa = gpa, .grid = try gpa.create(h_.map.Grid), .sim = try gpa.create(S), .asmd = asmd, .level = undefined };
        testmap.build(r.grid);
        r.level = r.asmd.level();
        r.sim.init(r.grid, .{ .seed = 11, .mode = .authoritative });
        r.sim.attachLevel(&r.level);
        return r;
    }
    fn deinit(r: *Run) void {
        r.asmd.deinit();
        r.gpa.destroy(r.sim);
        r.gpa.destroy(r.grid);
        r.gpa.destroy(r);
    }
    fn join(r: *Run) void {
        r.sim.step(&r.frames, &.{.{ .op = .join, .slot = 0, .arg = simmod.spawnHint(20, 20) }});
    }
    fn step(r: *Run, n: u32) void {
        for (0..n) |_| r.sim.step(&r.frames, &.{});
    }
    fn ctr(r: *Run, num: u16) i32 {
        return r.sim.state.sp.script.slot[num];
    }
    fn st(r: *Run) *vm.State {
        return &r.sim.state.sp.script;
    }
    fn hud(r: *Run) *hudm.State {
        return &r.sim.state.sp.hud[0];
    }
};

// ---------------------------------------------------------------------------
// mission-scripts.md

test "script 3-1: declarations apply once at start, even unreachable ones; the thread starts at level start" {
    var r = try Run.init(
        \\1 counter 5
        \\2 save_counter 7
        \\3 level_start
        \\4 set 1 6 -> end
        \\9 counter 42      # never reached by any thread
    );
    defer r.deinit();
    r.step(1); // declaration pass, then the level-start thread runs line 3
    try std.testing.expectEqual(@as(i32, 5), r.ctr(1));
    try std.testing.expectEqual(@as(i32, 7), r.ctr(2));
    try std.testing.expectEqual(@as(i32, 42), r.ctr(9));
    try std.testing.expectEqual(@as(u16, 1), r.st().threads);
    r.step(1); // line 4
    try std.testing.expectEqual(@as(i32, 6), r.ctr(1));
    r.step(1);
    try std.testing.expectEqual(@as(u16, 0), r.st().threads); // 0xFFFF ends it
}

test "script 3-1: no level-start command, no thread" {
    var r = try Run.init(
        \\1 counter 5
        \\2 set 1 6
    );
    defer r.deinit();
    r.step(3);
    try std.testing.expectEqual(@as(u16, 0), r.st().threads);
    try std.testing.expectEqual(@as(i32, 5), r.ctr(1));
}

test "script 3-2: one command a tick" {
    var r = try Run.init(
        \\1 counter 0
        \\2 level_start
        \\3 inc 1
        \\4 inc 1
        \\5 inc 1 -> end
    );
    defer r.deinit();
    r.step(1);
    try std.testing.expectEqual(@as(i32, 0), r.ctr(1));
    r.step(1);
    try std.testing.expectEqual(@as(i32, 1), r.ctr(1));
    r.step(1);
    try std.testing.expectEqual(@as(i32, 2), r.ctr(1));
    r.step(1);
    try std.testing.expectEqual(@as(i32, 3), r.ctr(1));
}

test "script 3-2 / flow 2-5: an EXEC block runs to its end in one tick" {
    var r = try Run.init(
        \\1 counter 0
        \\2 level_start
        \\3 exec
        \\4 inc 1
        \\5 exec          # a second start does not nest deeper
        \\6 inc 1
        \\7 endexec       # one end closes it
        \\8 inc 1 -> end
    );
    defer r.deinit();
    r.step(2); // tick 1 runs level_start; tick 2 runs 3..7
    try std.testing.expectEqual(@as(i32, 2), r.ctr(1));
    r.step(1);
    try std.testing.expectEqual(@as(i32, 3), r.ctr(1));
}

test "script 3-2 / flow 2-5: WHILE_EXEC lines run together, up to a line without the flag" {
    var r = try Run.init(
        \\1 counter 0
        \\2 level_start
        \\3 inc 1 !
        \\4 inc 1 !
        \\5 inc 1 !
        \\6 inc 1
        \\7 inc 1 -> end
    );
    defer r.deinit();
    r.step(2);
    try std.testing.expectEqual(@as(i32, 3), r.ctr(1));
    r.step(1);
    try std.testing.expectEqual(@as(i32, 4), r.ctr(1));
}

test "script 3-2: a WHILE_EXEC loop costs two ticks an iteration (the combinator line has no flag)" {
    // The shape the player's scripts compile WHILE_EXEC (NOT (c = 0)) to:
    // test, not, combinator (no flag), body (flagged), endwhile back to the test.
    var r = try Run.init(
        \\1 counter 4
        \\2 counter 0
        \\3 level_start
        \\10 eq 1 0 -> 11 !
        \\11 not -> 12 !
        \\12 if 0 20 -> 13
        \\13 dec 1 -> 14 !
        \\14 inc 2 -> 15 !
        \\15 endwhile 12 -> 10 !
        \\20 set 2 100 -> end
    );
    defer r.deinit();
    r.step(1);
    var ticks: u32 = 0;
    while (r.ctr(2) != 100 and ticks < 100) : (ticks += 1) r.step(1);
    try std.testing.expectEqual(@as(i32, 0), r.ctr(1));
    try std.testing.expectEqual(@as(u32, 11), ticks); // test, 4 iterations x 2, the exit, line 20
}

test "script 3-2: a stopped thread does nothing; level end ends a thread" {
    var r = try Run.init(
        \\1 counter 0
        \\2 counter 0
        \\3 level_start
        \\4 start_thread 10 9
        \\5 inc 2
        \\6 stop_thread 9
        \\7 inc 2 -> end
        \\9 thread_decl
        \\10 inc 1 -> 10
    );
    defer r.deinit();
    r.step(2); // level start, then start_thread
    try std.testing.expectEqual(@as(u16, 2), r.st().threads);
    r.step(10);
    const frozen = r.ctr(1);
    try std.testing.expect(frozen >= 1);
    r.step(5);
    try std.testing.expectEqual(frozen, r.ctr(1)); // stopped
    try std.testing.expectEqual(@as(u16, 1), r.st().threads); // the first ended; the stopped one is kept, inert
    try std.testing.expectEqual(@as(u8, 1), r.st().thread[0].stopped);
}

// ---------------------------------------------------------------------------
// script-flow-control.md

test "flow 2-1: AND-style combinator jumps when false, OR-style when true; not inverts" {
    var r = try Run.init(
        \\1 counter 3
        \\2 counter 0
        \\3 level_start
        \\4 eq 1 3                # true
        \\5 if 0 40               # AND: falls through
        \\6 inc 2                 # 2 = 1
        \\7 eq 1 9                # false
        \\8 not                   # true
        \\9 if 1 11               # OR: jumps
        \\10 set 2 99
        \\11 eq 1 9               # false
        \\12 if 0 14              # AND: jumps
        \\13 set 2 98
        \\14 inc 2 -> end         # 2 = 2
        \\40 set 2 97 -> end
    );
    defer r.deinit();
    r.step(30);
    try std.testing.expectEqual(@as(i32, 2), r.ctr(2));
}

test "flow 2-3: GOSUB returns to the next line and restores the caller's condition; RETURN with nothing pushed ends the thread" {
    var r = try Run.init(
        \\1 counter 0
        \\2 counter 0
        \\3 level_start
        \\4 eq 1 0                # true
        \\5 gosub 20
        \\6 if 0 8                # still true after the call: falls through
        \\7 set 2 1
        \\8 return                # nothing pushed: the thread ends
        \\9 set 2 50 -> end
        \\20 label
        \\21 eq 1 5               # false inside the routine
        \\22 return
    );
    defer r.deinit();
    r.step(20);
    try std.testing.expectEqual(@as(i32, 1), r.ctr(2));
    try std.testing.expectEqual(@as(u16, 0), r.st().threads);
}

test "flow 2-4: a started thread inherits flags and gets a fresh stack; stop finds it by its entry point" {
    var r = try Run.init(
        \\1 counter 0
        \\2 level_start
        \\3 start_thread 11 10 -> 4
        \\4 stop_thread 10 -> 4
        \\10 thread_decl
        \\11 inc 1 -> 11
    );
    defer r.deinit();
    r.step(2);
    const t = &r.st().thread[1];
    try std.testing.expectEqual(@as(u16, 10), t.entry);
    try std.testing.expectEqual(@as(u8, 0), t.sp);
    r.step(1);
    try std.testing.expectEqual(@as(u8, 1), r.st().thread[1].stopped);
}

test "flow 2-7: wait-here holds for its count; delay loops through the combinator" {
    var r = try Run.init(
        \\1 counter 0
        \\2 counter 0
        \\3 level_start
        \\4 wait 5
        \\5 set 1 1
        \\6 delay 4
        \\7 if 1 6               # OR: back to the delay while it counts
        \\8 set 2 1 -> end
    );
    defer r.deinit();
    r.step(2); // level start; wait arms
    var n: u32 = 0;
    while (r.ctr(1) == 0) : (n += 1) r.step(1);
    try std.testing.expectEqual(@as(u32, 5), n);
    n = 0;
    while (r.ctr(2) == 0 and n < 50) : (n += 1) r.step(1);
    try std.testing.expectEqual(@as(u32, 9), n); // four passes through delay and combinator, then line 8
}

test "flow 2-2: the header's next field is the GOTO" {
    var r = try Run.init(
        \\1 counter 0
        \\2 level_start -> 10
        \\3 set 1 5 -> end
        \\10 set 1 7 -> end
    );
    defer r.deinit();
    r.step(3);
    try std.testing.expectEqual(@as(i32, 7), r.ctr(1));
}

// ---------------------------------------------------------------------------
// script-counters.md

test "counters 2-2-2-5: set, inc, dec, arithmetic, comparisons, the sum/difference tests" {
    var r = try Run.init(
        \\1 counter 10
        \\2 counter 3
        \\3 counter 0
        \\4 counter 0
        \\5 level_start
        \\6 exec
        \\7 add_c 3 1 2           # 13
        \\8 sub 4 1 4             # 6
        \\9 mul_c 3 3 2           # 39
        \\10 div 4 4 4            # 1
        \\11 mod_c 1 1 2          # 10 % 3 = 1
        \\12 div 2 2 0            # by zero: unchanged (ours)
        \\13 inc 2
        \\14 dec 1                # 0
        \\15 endexec -> end
    );
    defer r.deinit();
    r.step(3);
    try std.testing.expectEqual(@as(i32, 39), r.ctr(3));
    try std.testing.expectEqual(@as(i32, 1), r.ctr(4));
    try std.testing.expectEqual(@as(i32, 0), r.ctr(1));
    try std.testing.expectEqual(@as(i32, 4), r.ctr(2));
}

test "counters 2-5: comparisons leave true or false; odd members leave the sum or difference" {
    var r = try Run.init(
        \\1 counter 5
        \\2 counter 5
        \\3 level_start
        \\4 lt 1 6
        \\5 le_c 1 2
        \\6 gt 1 5
        \\7 ge 1 5
        \\8 eq_c 1 2
        \\9 diff_c 1 2
        \\10 sum_c 1 2
        \\11 label -> 11
    );
    defer r.deinit();
    r.step(1);
    const t = &r.st().thread[0];
    const want = [_]i32{ 1, 1, 0, 1, 1, 0, 10 };
    for (want) |w| {
        r.step(1);
        try std.testing.expectEqual(w, t.cond);
    }
}

test "counters 5: a counter wraps on overflow" {
    var r = try Run.init(
        \\1 counter 0
        \\2 level_start
        \\3 inc 1 -> end
    );
    defer r.deinit();
    r.step(1);
    r.st().slot[1] = std.math.maxInt(i32);
    r.step(1);
    try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), r.ctr(1));
}

// ---------------------------------------------------------------------------
// script-messages.md

test "messages 2-2: banner for 90 ticks; a less urgent one does not replace it" {
    var r = try Run.init(
        \\2 level_start
        \\3 message 500 1 -> end
    );
    defer r.deinit();
    r.step(2);
    try std.testing.expectEqual(@as(u32, 500), r.hud().banner);
    try std.testing.expectEqual(@as(u8, 1), r.hud().banner_voice);
    try std.testing.expect(r.hud().banner_ticks >= 88);
    H.postBanner(r.sim, 0, 77, 90); // normal priority: refused
    try std.testing.expectEqual(@as(u32, 500), r.hud().banner);
    r.step(91);
    try std.testing.expectEqual(@as(u16, 0), r.hud().banner_ticks);
    H.postBanner(r.sim, 0, 77, 90);
    try std.testing.expectEqual(@as(u32, 77), r.hud().banner);
}

test "messages 2-3-2-5: brief queue by priority; now interrupts; clear; showing" {
    var r = try Run.init(
        \\1 counter 0
        \\2 level_start
        \\3 exec
        \\4 brief 100 0
        \\5 brief 101 0
        \\6 brief_soon 102 0
        \\7 endexec
        \\8 brief_showing
        \\9 brief_now 103 2
        \\10 clear_briefs
        \\11 brief_showing -> end
    );
    defer r.deinit();
    r.step(2);
    const h = r.hud();
    try std.testing.expectEqual(@as(u8, 3), h.brief_len);
    try std.testing.expectEqual(@as(u32, 100), h.briefs[0].text); // showing first
    try std.testing.expectEqual(@as(u32, 102), h.briefs[1].text); // soon ahead of normal
    try std.testing.expectEqual(@as(u32, 101), h.briefs[2].text);
    r.step(1);
    try std.testing.expectEqual(@as(i32, 1), r.st().thread[0].cond);
    r.step(1);
    try std.testing.expectEqual(@as(u32, 103), h.briefs[0].text);
    try std.testing.expectEqual(@as(u32, 100), h.briefs[1].text); // pushed back, not dropped
    try std.testing.expectEqual(@as(u8, 1), h.brief_showing);
    r.step(2);
    try std.testing.expectEqual(@as(u8, 0), h.brief_len);
}

test "messages 2-3: a brief stays up 3 ticks a character, then the next starts" {
    var r = try Run.init(
        \\2 level_start
        \\3 brief 5 0
        \\4 brief 6 0 -> end
    );
    defer r.deinit();
    var lens: [8]u16 = @splat(0);
    lens[5] = 10;
    lens[6] = 4;
    r.level.text_lengths = &lens;
    r.step(3);
    const h = r.hud();
    try std.testing.expectEqual(@as(u16, 10 * 3 + hudm.brief_linger), h.brief_total);
    r.step(10 * 3 + hudm.brief_linger);
    try std.testing.expectEqual(@as(u32, 6), h.briefs[0].text);
    try std.testing.expectEqual(@as(u16, 4 * 3 + hudm.brief_linger), h.brief_total);
}

test "messages 2-6-2-7: timers count down, add time past zero, share a slot with a counter, clear apart" {
    var r = try Run.init(
        \\1 counter 7
        \\2 display_decl
        \\3 display_decl
        \\4 level_start
        \\5 timer 2 1             # 30 ticks
        \\6 show_counter 3 1      # joins the timer's slot
        \\7 wait 40
        \\8 timer_add 2 2         # +60 to an expired timer restarts it
        \\9 clock_clear 2
        \\10 timer 2 1
        \\11 timer_clear 2 -> end # the whole slot, counter too
    );
    defer r.deinit();
    r.step(2);
    const h = r.hud();
    try std.testing.expect(h.display[0].flags & hudm.display_timer != 0);
    try std.testing.expectEqual(@as(u16, 2), h.display[0].owner);
    r.step(1);
    try std.testing.expect(h.display[0].flags & hudm.display_counter != 0);
    try std.testing.expectEqual(@as(i32, 7), h.display[0].counter);
    r.st().slot[1] = 3;
    r.step(1);
    try std.testing.expectEqual(@as(i32, 3), h.display[0].counter); // live value
    while (r.st().thread[0].cur != 8) r.step(1);
    try std.testing.expect(h.display[0].timer < 0);
    r.step(1);
    try std.testing.expect(h.display[0].timer > 40);
    r.step(1);
    try std.testing.expectEqual(hudm.display_counter, h.display[0].flags); // counter kept
    r.step(2);
    try std.testing.expectEqual(@as(u8, 0), h.display[0].flags);
    try std.testing.expectEqual(@as(u8, 0), h.display[1].flags);
}

test "messages 2-6: a timer with every slot in use fails silently" {
    var r = try Run.init(
        \\2 level_start
        \\3 exec
        \\4 timer 15 5
        \\5 timer 11 5
        \\6 timer 12 5
        \\7 timer 13 5
        \\8 timer 14 5
        \\9 timer_add 14 5
        \\10 endexec -> end
        \\11 display_decl
        \\12 display_decl
        \\13 display_decl
        \\14 display_decl
        \\15 display_decl
    );
    defer r.deinit();
    r.step(2);
    for (r.hud().display) |d| try std.testing.expect(d.owner != 14);
}

// ---------------------------------------------------------------------------
// script-missions.md and the fail unwind (mission-scripts.md 3.3)

const mission_text =
    \\.string 30 mission demo_m1.mis
    \\.string 31 mission demo_m2.mis
    \\.string 40 gang testgang
    \\.main
    \\1 counter 0          # in progress (general)
    \\2 counter 0          # passed
    \\3 counter 0          # failed
    \\4 counter 0          # on a job for this gang
    \\5 counter 0          # after the mission
    \\6 level_start
    \\7 mission 30
    \\8 set 5 1 -> end
    \\.mission demo_m1 100 101
    \\100 counter 9        # reset to 9 on every load
    \\101 mission_begin
    \\102 set 1 1
    \\103 gosub 110
    \\104 set 1 0
    \\105 mission_end
    \\110 label
    \\111 inc 100
    \\112 return
;

test "missions 2-1-2-2 / rules: 274 loads the sub-script and gosubs into it; mission end returns to the caller" {
    var r = try Run.init(mission_text);
    defer r.deinit();
    r.step(2);
    try std.testing.expectEqual(@as(u16, 1), r.st().mission);
    try std.testing.expectEqual(@as(i32, 9), r.ctr(100));
    try std.testing.expectEqual(@as(u8, 1), r.st().thread[0].sp);
    r.step(20);
    try std.testing.expectEqual(@as(i32, 10), r.ctr(100));
    try std.testing.expectEqual(@as(i32, 1), r.ctr(5));
    try std.testing.expectEqual(@as(i32, 0), r.ctr(1));
}

test "mission-scripts 3-3: death or arrest in a mission unwinds two levels and shows the fail texts" {
    var r = try Run.init(mission_text);
    defer r.deinit();
    const t = &r.st().thread[0];
    r.step(2);
    while (t.sp < 2) r.step(1); // in the mission body's subroutine: two frames deep
    try std.testing.expectEqual(@as(u8, 2), t.sp);
    r.st().notify_death_arrest = 1;
    r.st().mission_flag[0] = 1;
    V.missionFail(r.sim, t);
    try std.testing.expectEqual(@as(u8, 0), t.sp);
    try std.testing.expectEqual(@as(u16, 8), t.cur); // the line after the launch
    try std.testing.expectEqual(@as(i32, 0), r.ctr(1));
    try std.testing.expectEqual(@as(u8, 1), r.st().death_arrest);
    try std.testing.expectEqual(hudm.named_mission_failed, r.hud().banner);
    try std.testing.expectEqual(hudm.named_fail_brief, r.hud().briefs[0].text);
}

test "mission-scripts 3-3: with a gang flag set the fail brief is one of that gang's five" {
    var r = try Run.init(mission_text);
    defer r.deinit();
    r.step(2);
    while (r.st().thread[0].sp < 2) r.step(1);
    r.st().mission_flag[1] = 4;
    r.st().slot[4] = 1;
    r.st().fail_base[0] = 2000;
    V.missionFail(r.sim, &r.st().thread[0]);
    const b = r.hud().briefs[0].text;
    try std.testing.expect(b >= 2000 and b < 2010);
}

test "missions 2-1: the gang-phone gate refuses with a canned brief, or launches mission 1 or 2" {
    const gate_text =
        \\.string 30 mission demo_m1.mis
        \\.string 31 mission demo_m2.mis
        \\.string 40 gang testgang
        \\.main
        \\1 counter 0
        \\2 counter 0
        \\3 counter 0
        \\4 counter 0
        \\6 level_start
        \\7 gang_phone 1098 2 3 31 1 4 0 0 40 0 30 0 -> end
        \\.mission demo_m1 100 101
        \\101 mission_begin
        \\102 mission_end
        \\.mission demo_m2 100 101
        \\101 mission_begin
        \\102 mission_end
    ;
    // On a job for this gang: the "already on a job" line, nothing launched.
    {
        var r = try Run.init(gate_text);
        defer r.deinit();
        r.step(1);
        r.st().slot[4] = 1;
        r.step(1);
        try std.testing.expectEqual(@as(u16, 0), r.st().mission);
        try std.testing.expectEqual(@as(u32, 1098 - 5), r.hud().briefs[0].text);
    }
    // Passed before, respect enough (0 needed): mission 2.
    {
        var r = try Run.init(gate_text);
        defer r.deinit();
        r.step(1);
        r.st().slot[2] = 1;
        r.step(1);
        try std.testing.expectEqual(@as(u16, 2), r.st().mission);
    }
    // Fresh: mission 1.
    {
        var r = try Run.init(gate_text);
        defer r.deinit();
        r.step(2);
        try std.testing.expectEqual(@as(u16, 1), r.st().mission);
        try std.testing.expectEqual(@as(u8, 1), r.st().thread[0].sp);
    }
}

test "missions 2-2: 391 removes everything on the cleanup list" {
    var r = try Run.init(
        \\2 level_start
        \\3 mission_cleanup -> end
    );
    defer r.deinit();
    r.join();
    const car = r.sim.spawnCarAt(fx.fromInt(30), fx.fromInt(30), 0, 0).?;
    r.sim.state.world.applyPending();
    V.addCleanup(r.sim, car);
    try std.testing.expectEqual(@as(u16, 1), r.st().cleanup_len);
    r.step(2);
    r.sim.state.world.applyPending();
    try std.testing.expect(!r.sim.state.world.isAlive(car));
    try std.testing.expectEqual(@as(u16, 0), r.st().cleanup_len);
}

test "missions 2-3: a bonus challenge counts the player's kills, pays out at the target, and remembers its result" {
    var r = try Run.init(
        \\1 counter 0
        \\2 counter 0
        \\3 display_decl
        \\4 level_start
        \\5 challenge 0xFFFF B:1:254 3 51 1800 0xFFFF L:500 3 17
        \\6 challenge_progress 3 2
        \\7 challenge_passed 3
        \\8 if 0 6
        \\9 set 1 1 -> end
    );
    defer r.deinit();
    r.join();
    r.step(2);
    try std.testing.expectEqual(vm.result_running, r.ctr(3));
    const me = r.sim.pedOf(0).?;
    S.hooks.pedKilled(r.sim, EntityId.none, me, 1);
    S.hooks.pedKilled(r.sim, EntityId.none, EntityId.none, 1); // not the player's: ignored
    r.step(3);
    try std.testing.expectEqual(@as(i32, 1), r.ctr(2));
    S.hooks.pedKilled(r.sim, EntityId.none, me, 1);
    S.hooks.pedKilled(r.sim, EntityId.none, me, 1);
    try std.testing.expectEqual(vm.result_passed, r.ctr(3));
    r.step(6);
    try std.testing.expectEqual(@as(i32, 1), r.ctr(1));
}

test "missions 2-3: a challenge runs out of time and fails" {
    var r = try Run.init(
        \\3 display_decl
        \\4 level_start
        \\5 challenge 0xFFFF B:0:254 3 0xFFFF 10 0xFFFF L:0 3 0
        \\6 challenge_failed 3 -> end
    );
    defer r.deinit();
    r.step(2);
    r.step(12);
    try std.testing.expectEqual(vm.result_failed, r.ctr(3));
}

test "missions 2-4: a kill frenzy commits once, holds its thread until the challenge resolves, then pays" {
    var r = try Run.init(
        \\1 counter 0          # counter shown
        \\2 display_decl       # timer
        \\3 display_decl       # counter display
        \\4 display_decl       # challenge
        \\9 level_start
        \\10 frenzy 0 4310 0 1 19
        \\11 challenge 0xFFFF B:1:254 2 51 3600 0xFFFF L:0 4 17
        \\12 frenzy_run 4 2 120 0 3 1 2 4310 1 1 1000
        \\13 set 1 77 -> end
    );
    defer r.deinit();
    r.join();
    r.step(3);
    try std.testing.expectEqual(@as(u8, 1), r.st().frenzy_running);
    try std.testing.expectEqual(hudm.named_kill_frenzy, r.hud().banner);
    r.step(2);
    try std.testing.expectEqual(@as(u16, 12), r.st().thread[0].cur);
    try std.testing.expect(r.hud().display[0].flags != 0);
    const me = r.sim.pedOf(0).?;
    S.hooks.pedKilled(r.sim, EntityId.none, me, 1);
    r.step(1);
    try std.testing.expectEqual(@as(i32, 1), r.ctr(1)); // target minus progress
    S.hooks.pedKilled(r.sim, EntityId.none, me, 1);
    r.step(1);
    try std.testing.expectEqual(@as(u8, 0), r.st().frenzy_running);
    try std.testing.expectEqual(hudm.named_frenzy_passed, r.hud().banner);
    try std.testing.expectEqual(@as(u8, 0), r.hud().display[0].flags);
    r.step(1);
    try std.testing.expectEqual(@as(i32, 77), r.ctr(1));
}

// ---------------------------------------------------------------------------
// Triggers (mission-scripts.md 3.4)

test "triggers 3-4: an area trigger starts its thread on entering, once until left; off stops it" {
    var r = try Run.init(
        \\1 counter 0
        \\2 level_start -> end
        \\20 label
        \\21 inc 1 -> end
    );
    defer r.deinit();
    r.join();
    r.step(1);
    const me = r.sim.pedOf(0).?;
    const tr = r.sim.transformOf(me).?;
    _ = V.addTrigger(r.sim, .{ .kind = vm.trig_area_on_foot, .enabled = 1, .decl = 15, .entry = 20, .character = me, .x = tr.x, .y = tr.y, .w = fx.fromInt(2), .h = fx.fromInt(2) });
    r.step(3);
    try std.testing.expectEqual(@as(i32, 1), r.ctr(1));
    r.step(3);
    try std.testing.expectEqual(@as(i32, 1), r.ctr(1)); // still inside: no second start
    tr.x += fx.fromInt(5);
    r.step(1);
    tr.x -= fx.fromInt(5);
    r.step(3);
    try std.testing.expectEqual(@as(i32, 2), r.ctr(1));
    V.triggerByDecl(r.sim, 15).?.enabled = 0;
    tr.x += fx.fromInt(5);
    r.step(1);
    tr.x -= fx.fromInt(5);
    r.step(3);
    try std.testing.expectEqual(@as(i32, 2), r.ctr(1));
}

test "triggers 3-4: phone and car triggers start a thread from the hooks; 215/216 switch them" {
    var r = try Run.init(
        \\1 counter 0
        \\2 counter 0
        \\3 level_start
        \\4 trigger_off 50 -> end
        \\20 label
        \\21 inc 1 -> end
        \\30 label
        \\31 inc 2 -> end
    );
    defer r.deinit();
    r.join();
    const me = r.sim.pedOf(0).?;
    const car = r.sim.spawnCarAt(fx.fromInt(30), fx.fromInt(30), 0, 0).?;
    const phone: EntityId = .{ .raw = 0x0400_0001 };
    _ = V.addTrigger(r.sim, .{ .kind = vm.trig_phone, .enabled = 1, .decl = 50, .entry = 20, .character = me, .target = phone });
    _ = V.addTrigger(r.sim, .{ .kind = vm.trig_car, .enabled = 1, .decl = 51, .entry = 30, .character = me, .target = car });
    S.hooks.phoneTouched(r.sim, phone, me);
    S.hooks.carEntered(r.sim, car, me);
    r.step(3);
    try std.testing.expectEqual(@as(i32, 1), r.ctr(1));
    try std.testing.expectEqual(@as(i32, 1), r.ctr(2));
    // trigger_off ran: the phone no longer starts anything.
    r.step(3);
    S.hooks.phoneTouched(r.sim, phone, me);
    r.step(3);
    try std.testing.expectEqual(@as(i32, 1), r.ctr(1));
}

test "triggers 3-4: weapon hits are recorded per entity with a script tag" {
    var r = try Run.init(
        \\2 level_start -> end
    );
    defer r.deinit();
    r.join();
    const me = r.sim.pedOf(0).?;
    S.hooks.entityHit(r.sim, me, 3, EntityId.none);
    try std.testing.expect(V.hitBy(r.sim, me, 3));
    try std.testing.expect(!V.hitBy(r.sim, me, 4));
    V.clearHit(r.sim, me, 3);
    try std.testing.expect(!V.hitBy(r.sim, me, 3));
}

test "script: two sims running the same script stay identical (saved state only)" {
    var a = try Run.init(mission_text);
    defer a.deinit();
    var b = try Run.init(mission_text);
    defer b.deinit();
    a.join();
    b.join();
    for (0..40) |_| {
        a.step(1);
        b.step(1);
        try std.testing.expectEqual(a.sim.hash(), b.sim.hash());
    }
    // save/load mid-script and keep going
    const buf = try std.testing.allocator.alloc(u8, S.state_size);
    defer std.testing.allocator.free(buf);
    _ = a.sim.save(buf);
    try b.sim.load(buf);
    a.step(5);
    b.step(5);
    try std.testing.expectEqual(a.sim.hash(), b.sim.hash());
}
