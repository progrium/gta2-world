//! Counter commands (script-counters.md): set, increment, decrement,
//! arithmetic and comparisons. Declarations are applied by the VM's
//! declaration pass and mission loads. Owner: workstream A1.
//!
//! Literals in commands are 16-bit (script-counters.md 5); counters are
//! 32-bit and wrap. Division or remainder by zero crashed the original;
//! here it leaves the counter unchanged (ours).

const vm = @import("vm.zig");
const Thread = vm.Thread;
const Step = vm.Step;
const Cmd = vm.Cmd;
const P = vm.P;
const k = vm.k;

const Op = enum { add, sub, mul, div, mod };
const Cmp = enum { lt, le, gt, ge, eq };

fn arith(op: Op, a: i32, b: i32) ?i32 {
    return switch (op) {
        .add => a +% b,
        .sub => a -% b,
        .mul => a *% b,
        .div => if (b == 0) null else if (a == -2147483648 and b == -1) a else @divTrunc(a, b),
        .mod => if (b == 0) null else if (b == -1) 0 else @rem(a, b),
    };
}

fn compare(op: Cmp, a: i32, b: i32) bool {
    return switch (op) {
        .lt => a < b,
        .le => a <= b,
        .gt => a > b,
        .ge => a >= b,
        .eq => a == b,
    };
}

pub fn Sys(comptime Self: type) type {
    return struct {
        const V = Self.script;

        fn val(self: *Self, num: u16) i32 {
            return if (V.slotPtr(self, num)) |q| q.* else 0;
        }

        pub fn exec(self: *Self, t: *Thread, cmd: Cmd) ?Step {
            const p = P{ .b = cmd.params };
            switch (cmd.kind) {
                // Declarations met at run time do nothing (2.1).
                k.counter, k.counter_bare, k.save_counter, k.save_counter_bare, k.counter_v, k.copy => return .advance,
                k.set => {
                    if (V.slotPtr(self, p.u(0))) |q| q.* = p.s(1);
                    return .advance;
                },
                k.inc, k.dec => {
                    if (V.slotPtr(self, p.u(0))) |q| q.* = if (cmd.kind == k.inc) q.* +% 1 else q.* -% 1;
                    return .advance;
                },
                // (dest, a, b): counter op counter (108-112), counter op
                // literal (79-83).
                108...112, 79...83 => {
                    const op: Op = @enumFromInt(if (cmd.kind >= 108) cmd.kind - 108 else cmd.kind - 79);
                    const b: i32 = if (cmd.kind >= 108) val(self, p.u(2)) else p.s(2);
                    if (arith(op, val(self, p.u(1)), b)) |r| {
                        if (V.slotPtr(self, p.u(0))) |q| q.* = r;
                    }
                    return .advance;
                },
                // Comparisons: even = counter vs literal, odd = counter vs
                // counter (86-95).
                86...95 => {
                    const op: Cmp = @enumFromInt((cmd.kind - 86) / 2);
                    const b: i32 = if ((cmd.kind - 86) % 2 == 1) val(self, p.u(1)) else p.s(1);
                    t.cond = @intFromBool(compare(op, val(self, p.u(0)), b));
                    return .advance;
                },
                // The two odd members leave the sum or difference (5).
                84, 85 => {
                    const a = val(self, p.u(0));
                    const b = val(self, p.u(1));
                    t.cond = if (cmd.kind == 84) a +% b else a -% b;
                    return .advance;
                },
                else => return null,
            }
        }
    };
}
