//! The seam between the VM (A1) and the world command families (A2:
//! cmd_decl, cmd_cars, cmd_chars, cmd_objects, cmd_player). Owner: A2.
//! A1's stub: every command is unhandled until A2's version replaces this
//! file (same names and signatures).
//!
//! A2's file replaces this one on merge (keep theirs).
//! `ctx` is the VM's `Ctx` (script/vm.zig): declaring(), handle(num),
//! setHandle(num, id), cond(), setCond(b), counter(num), addCleanup(id),
//! string(key), deathArrestFlag(), notifyDeathArrest(), setMissionFlag(which,
//! counter), setFailBase(gang, base), registerGang(index, key), player().

/// One script command as the VM hands it over.
pub const Cmd = struct {
    num: u16,
    kind: u16,
    /// The header's return-value field (1 on a WHILE_EXEC line).
    ret: i16,
    /// The bytes after the 8-byte header (may run past the command; read
    /// only the type's own layout).
    params: []const u8,
};

pub const Outcome = enum(u8) {
    /// Done; the VM advances to the next command.
    done,
    /// Known but its system has not landed: advances, counted "stubbed".
    stubbed,
    /// Not a type this family knows: advances, counted "unhandled".
    unhandled,
    /// Keep the thread on this command (try again next tick).
    hold,
};

pub fn exec(comptime Self: type, self: *Self, ctx: anytype, cmd: Cmd) Outcome {
    _ = .{ self, ctx, cmd };
    return .unhandled;
}

/// For the coverage report.
pub fn coverage(kind: u16) Outcome {
    _ = kind;
    return .unhandled;
}
