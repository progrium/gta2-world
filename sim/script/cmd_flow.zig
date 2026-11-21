//! Flow control commands (script-flow-control.md): the IF combinator and
//! its "not", GOSUB/RETURN, EXEC blocks, wait and delay, starting and
//! stopping threads, trigger on/off, and the markers that only advance.
//! Owner: workstream A1. Type numbers: formats/scr.zig.

const vm = @import("vm.zig");
const Thread = vm.Thread;
const Step = vm.Step;
const Cmd = vm.Cmd;
const P = vm.P;
const k = vm.k;

pub fn Sys(comptime Self: type) type {
    return struct {
        const V = Self.script;

        pub fn exec(self: *Self, t: *Thread, cmd: Cmd) ?Step {
            const p = P{ .b = cmd.params };
            switch (cmd.kind) {
                // Markers: advance through the header's next (2.2: GOTO is
                // just a next field pointing elsewhere).
                k.level_start, k.label, k.endwhile, k.thread_decl, k.mission_begin, k.challenge_dead => return .advance,
                k.level_end_ => {
                    V.endThread(self, t);
                    return .ended;
                },
                k.exec => {
                    if (t.exec == 0) t.exec = 1;
                    return .advance;
                },
                k.endexec => {
                    if (t.exec > 0) t.exec -= 1;
                    return .advance;
                },
                k.not_ => {
                    t.cond = @intFromBool(t.cond == 0);
                    return .advance;
                },
                // (or-flag, target) 2.1: AND jumps when false, OR when true.
                k.if_ => {
                    const or_line = p.u(0) != 0;
                    const truth = t.cond != 0;
                    if (truth == or_line) {
                        t.cur = p.u(1);
                        return .jumped;
                    }
                    return .advance;
                },
                k.gosub => return V.gosub(self, t, p.u(0), lookupNext(self, cmd)),
                k.ret, k.mission_end => return V.doReturn(self, t),
                // 2.7: hold until the count runs out.
                // The tick it arrives counts as the first of its n.
                k.wait => {
                    if (t.wait_at != cmd.num) {
                        t.wait_at = cmd.num;
                        t.wait = p.s(0);
                    }
                    t.wait -= 1;
                    if (t.wait > 0) return .hold;
                    t.wait_at = 0;
                    return .advance;
                },
                // 2.7: always advance; true while counting. The combinator
                // after it jumps back here while true, so the count is kept
                // across that loop.
                k.delay => {
                    if (t.wait_at != cmd.num) {
                        t.wait_at = cmd.num;
                        t.wait = p.s(0);
                    }
                    t.wait -= 1;
                    if (t.wait > 0) {
                        t.cond = 1;
                        return .advance;
                    }
                    t.cond = 0;
                    t.wait_at = 0;
                    return .advance;
                },
                k.start_thread => {
                    _ = V.spawnThread(self, p.u(0), p.u(1), t.flags);
                    return .advance;
                },
                k.stop_thread => {
                    const slot = V.slotPtr(self, p.u(0)) orelse return .advance;
                    const id: u16 = @truncate(@as(u32, @bitCast(slot.*)));
                    if (V.threadById(self, id)) |other| {
                        if (other.entry == p.u(0)) other.stopped = 1;
                    }
                    return .advance;
                },
                k.trigger_on, k.trigger_off => {
                    if (V.triggerByDecl(self, p.u(0))) |tr| tr.enabled = @intFromBool(cmd.kind == k.trigger_on);
                    return .advance;
                },
                else => return null,
            }
        }

        fn lookupNext(self: *Self, cmd: Cmd) u16 {
            const f = V.lookup(self, cmd.num) orelse return vm.level_end;
            return f.next;
        }
    };
}
