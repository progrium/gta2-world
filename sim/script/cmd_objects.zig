//! Runtime object commands (script-objects.md): creating and removing
//! objects, generators, object queries, doors and phones. Owner:
//! workstream A2. A thin layer over B's `objects` API.
//!
//! Layouts (from the player's .scr files; offsets into the parameters):
//!   15-20, 47-52  variable @0 (unused in declarations), position @4,
//!            model @16, rotation @18, value i32 @20 (the longer forms)
//!   140, 444, 177-180, 227-229, 245, 160, 356  entity @0
//!   268, 269 generator @0, count i16 @2 (-1 = no limit)
//!   362      object @0, model @4;  265  door @0, car or character @2
//! Guessed (no level uses them): 351/352 generator @0, count @2, model @4;
//! 354 car @0, generator @2; 168 phone @0, character @2, timeout @4.

const std = @import("std");
const prelude = @import("../prelude.zig");
const abi = prelude.abi;
const c = prelude.c;
const T = prelude.T;
const EntityId = prelude.EntityId;
const ids = @import("../ids.zig");
const W = @import("world.zig");
const Cmd = W.Cmd;
const Outcome = W.Outcome;

pub const done = [_]u16{ 15, 16, 17, 18, 19, 20, 47, 48, 49, 50, 51, 52, 140, 444, 362, 177, 178, 179, 180, 265, 168, 227, 228, 229, 245, 268, 269, 351, 352, 354 };
/// Waiting on the camera's view test (H) for 160 and 356.
pub const stubbed = [_]u16{ 160, 356 };

/// Object models treated as pickups (4): a generator of one spawns one at
/// a time, and a mission does not clean one up.
pub fn isPickupModel(model: u16) bool {
    return (model >= 64 and model <= 108) or (model >= 200 and model <= 244);
}

/// Object models the levels use as phones: every declared object a phone
/// trigger (213) or 229/245 names has one of these, and no other declared
/// object does (from Jeff's level scripts; script-objects.md 2.6 only says
/// "one of the game's phone models").
pub fn isPhoneModel(model: u16) bool {
    return switch (model) {
        163, 176, 178, 180 => true,
        else => false,
    };
}

/// Which creation forms apply their value byte (2.1's scrambled routing).
/// Ours: the six runtime numbers are matched to the four shapes by size
/// (47 carries a value, 49 is plain, 52 has a ground height); the note's
/// "3D with a value" (47) and "2D named" (52) ignore the value.
pub fn appliesValue(kind: u16, has_value: bool) bool {
    if (!has_value) return false;
    return switch (kind) {
        47, 52 => false,
        else => true,
    };
}

pub fn Sys(comptime Self: type) type {
    return struct {
        const H = W.Helpers(Self);

        /// The object creation forms (declarations 15-20, runtime 47-52).
        pub fn create(self: *Self, ctx: anytype, cmd: Cmd, handle: u16, valued: bool, runtime: bool) ?EntityId {
            const p = W.params(cmd);
            const model = p.u16_(16);
            const pos = H.place(self, p.pos(4), T.ped_step);
            const kind: ids.ObjectKind = if (isPickupModel(model)) .pickup else if (isPhoneModel(model)) .phone else .none;
            // B classifies by model (phones, decorations); models above
            // 255 exist in the levels and wait on B widening `model`.
            const id = Self.objects.spawnObject(self, kind, @truncate(model), pos.x, pos.y, pos.z, W.heading(p.u16_(18))) orelse return null;
            const has_value = p.b.len >= 24;
            if ((valued and has_value) or (runtime and appliesValue(cmd.kind, has_value))) {
                Self.objects.setObjectValue(self, id, @truncate(p.u32_(20)));
            }
            var flags: u16 = c.ScriptTag.flag_keep;
            if (runtime and !ctx.declaring() and !isPickupModel(model)) {
                flags |= c.ScriptTag.flag_mission;
                ctx.addCleanup(id);
            }
            H.tag(self, id, handle, flags);
            ctx.setHandle(handle, id);
            return id;
        }

        pub fn exec(self: *Self, ctx: anytype, cmd: Cmd) Outcome {
            const p = W.params(cmd);
            const w = &self.state.world;
            const id = ctx.handle(p.u16_(0));
            switch (cmd.kind) {
                47, 48, 49, 50, 51, 52 => _ = create(self, ctx, cmd, p.u16_(0), false, true),
                // 2.2 Removing.
                140 => {
                    if (H.isObject(id)) {
                        Self.objects.removeObject(self, id);
                    } else if (H.isCar(id) or H.isPed(id)) {
                        if (H.isPed(id)) {
                            const car = H.carOf(self, id);
                            if (w.get(car, c.Vehicle)) |v| {
                                if (prelude.eql(v.driver, id)) self.releaseCar(car);
                            }
                        }
                        self.kill(id);
                    }
                },
                444 => if (H.isObject(id) and w.isAlive(id)) {
                    if (w.get(id, c.ScriptTag)) |t| t.flags |= c.ScriptTag.flag_mission;
                    ctx.addCleanup(id);
                },
                // 2.3 Generators: on; the count and pattern wait on B.
                // -1 is "no limit", the same value as B's unlimited.
                268, 269 => Self.objects.startGenerator(self, id, p.u16_(2), null),
                351, 352 => Self.objects.startGenerator(self, id, p.u16_(2), @truncate(p.u16_(4))),
                354 => {
                    const v = w.get(id, c.Vehicle) orelse return .done;
                    Self.objects.decidePowerUp(self, ctx.handle(p.u16_(2)), v.model);
                },
                // 2.4 Queries.
                362 => {
                    const have = Self.objects.objectModel(self, id) orelse return cond(ctx, false);
                    const m = p.u16_(4);
                    ctx.setCond(have == m);
                },
                160, 356 => {
                    ctx.setCond(false);
                    return .stubbed;
                },
                // 2.5 Doors. B's door applies 178's "only if already
                // closing" rule; manual mode and retargeting wait on B.
                177 => Self.objects.setDoor(self, id, .open),
                178 => Self.objects.setDoor(self, id, .closed),
                179 => Self.objects.setDoor(self, id, .auto),
                180 => Self.objects.setDoor(self, id, .manual),
                265 => Self.objects.setDoorTarget(self, id, ctx.handle(p.u16_(2))),
                // 2.6 Phones.
                168 => {
                    Self.objects.ringPhoneFor(self, id, ctx.handle(p.u16_(2)), p.u16_(4));
                    ctx.setCond(false);
                },
                227 => ctx.setCond(Self.objects.consumeAnswer(self, id)),
                228 => ctx.setCond(Self.objects.phoneTimedOut(self, id)),
                229 => Self.objects.ringPhone(self, id, false),
                245 => Self.objects.killPhone(self, id),
                else => return .unhandled,
            }
            return .done;
        }

        fn cond(ctx: anytype, b: bool) Outcome {
            ctx.setCond(b);
            return .done;
        }
    };
}
