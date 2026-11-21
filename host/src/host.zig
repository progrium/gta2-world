//! host.wasm: one game session of the native server, run inside a browser
//! Web Worker so a player's tab can host a game for others.
//!
//! This is server/src's `Manager` (the `net.Hub`), `Session`, snapshot
//! policy and replay recorder, unchanged, hosting the same comptime `Sim`
//! as gta2-server. The Worker (client/shell/src/host/worker.ts) plays the
//! transports: it reports what each peer sent (`opened`, `stream`,
//! `datagram`, `closed`), drives the 30 Hz timer (`tick`), and drains what
//! the session sent back (`outPtr`/`outLen`/`outClear`).
//!
//! No clocks, threads, sockets or files: every entry point takes the
//! current time (ns, the Worker's monotonic clock) as an argument and sets
//! util.embedded.now_ns from it before calling into the manager. The one
//! imported function besides logging is a stopwatch used only for the
//! step/encode timing metrics.
//!
//! Out-queue records, little-endian, back to back:
//!   u32 peer (the page's id), u8 kind (0 stream, 1 datagram, 2 close),
//!   u32 length, then length bytes (a whole I3 message; 0 for close).

const std = @import("std");
const ifc = @import("interfaces");
const server = @import("server");
const net = server.net;
const util = server.util;
const maps = server.maps;
const replay = server.replay;
const manager = server.manager;
const abi = ifc.abi;
const wire = ifc.wire;
const formats = @import("formats");
const sim = @import("sim");

pub const Sim = @import("sim_impl").Sim;
const Mgr = manager.Manager(Sim);
const S = Mgr.S;

comptime {
    abi.checkSim(Sim);
}

// ---------------------------------------------------------------------------
// Imports from the Worker

extern "env" fn hostLog(level: u32, ptr: [*]const u8, len: usize) void;
/// High-resolution monotonic ns (performance.now), for metrics only.
extern "env" fn hostStopwatch() f64;

fn stopwatch() u64 {
    return nsFrom(hostStopwatch());
}

pub const std_options: std.Options = .{ .log_level = .info, .logFn = logFn };

fn logFn(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[" ++ @tagName(scope) ++ "] " ++ fmt, args) catch return;
    hostLog(@intFromEnum(level), line.ptr, line.len);
}

pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(msg: []const u8, _: ?usize) noreturn {
    hostLog(0, msg.ptr, msg.len);
    @trap();
}

// ---------------------------------------------------------------------------
// State

const gpa = std.heap.wasm_allocator;

/// One connection, named by the page's peer id. The `Link` handed to the
/// manager points here.
const Peer = struct {
    page: u32,
    id: net.PeerId = 0,
    transport: net.TransportKind,
    closing: bool = false,
    // stats window
    prev_tx: u64 = 0,
    prev_rx: u64 = 0,
};

var registry: maps.Registry = .init(gpa);
var mgr: ?*Mgr = null;
var sess: ?*S = null;
var cap: u32 = 0;
var stopped = false;
var peers: std.AutoHashMapUnmanaged(u32, *Peer) = .empty;
var out: std.ArrayList(u8) = .empty;
var text: std.ArrayList(u8) = .empty;
var replay_bytes: []u8 = &.{};
/// The map's main script (`loadScript`), attached as the level so the sim
/// finds the car shops; nothing else of it runs online.
var level_script: ?formats.scr.Parsed = null;
var host_level: sim.level.Level = .{};

// stats window
var samples_step: std.ArrayList(u32) = .empty;
var samples_encode: std.ArrayList(u32) = .empty;
var prev_step_sum: u64 = 0;
var prev_snap_sum: u64 = 0;
var prev_late: u64 = 0;
var prev_skipped: u64 = 0;
var stats_t0: u64 = 0;
var step_max: u64 = 0;

fn nsFrom(t: f64) u64 {
    return if (t <= 0) 0 else @intFromFloat(t);
}

fn setNow(t: f64) void {
    // Never let the clock run backwards (the manager subtracts freely).
    const n = nsFrom(t);
    if (n > util.embedded.now_ns) util.embedded.now_ns = n;
}

// ---------------------------------------------------------------------------
// Link: queue for the Worker

const link_vt: net.Link.VTable = .{
    .sendDatagram = linkDatagram,
    .sendStream = linkStream,
    .close = linkClose,
    .maxDatagram = linkMaxDatagram,
};

fn peerOf(p: *anyopaque) *Peer {
    return @ptrCast(@alignCast(p));
}

fn push(page: u32, kind: u8, body: []const u8) void {
    var hdr: [9]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], page, .little);
    hdr[4] = kind;
    std.mem.writeInt(u32, hdr[5..9], @intCast(body.len), .little);
    out.appendSlice(gpa, &hdr) catch return;
    out.appendSlice(gpa, body) catch {
        out.shrinkRetainingCapacity(out.items.len - hdr.len);
    };
}

fn linkStream(p: *anyopaque, b: []const u8) void {
    const pr = peerOf(p);
    if (!pr.closing) push(pr.page, 0, b);
}
fn linkDatagram(p: *anyopaque, b: []const u8) void {
    const pr = peerOf(p);
    if (!pr.closing) push(pr.page, 1, b);
}
fn linkClose(p: *anyopaque) void {
    const pr = peerOf(p);
    if (pr.closing) return;
    pr.closing = true;
    push(pr.page, 2, &.{});
}
fn linkMaxDatagram(_: *anyopaque) usize {
    // I3 payload limit; WebRTC data channels and the loopback carry it whole.
    return wire.max_datagram;
}

// ---------------------------------------------------------------------------
// Exports: memory and text

export fn alloc(n: usize) ?[*]u8 {
    const s = gpa.alloc(u8, n) catch return null;
    return s.ptr;
}

export fn free(p: [*]u8, n: usize) void {
    gpa.free(p[0..n]);
}

/// The last JSON result or error message.
export fn textPtr() [*]const u8 {
    return text.items.ptr;
}
export fn textLen() usize {
    return text.items.len;
}

fn setText(comptime fmt: []const u8, args: anytype) void {
    text.clearRetainingCapacity();
    text.print(gpa, fmt, args) catch {};
}

fn fail(what: []const u8, e: anyerror) i32 {
    setText("{s}: {s}", .{ what, @errorName(e) });
    return -1;
}

export fn outPtr() [*]const u8 {
    return out.items.ptr;
}
export fn outLen() usize {
    return out.items.len;
}
export fn outClear() void {
    out.clearRetainingCapacity();
}

// ---------------------------------------------------------------------------
// Exports: the session

/// Loads the sim on `map` (a .gmp's bytes) and starts the 30 Hz timer at
/// `now`. `entropy` is 32 bytes from the Worker's CSPRNG (resume tokens).
/// On success `text` holds {"mapHash","layoutHash","maxPlayers"}.
export fn start(map_ptr: [*]const u8, map_len: usize, name_ptr: [*]const u8, name_len: usize, max_players: u32, seed_lo: u32, seed_hi: u32, record: bool, now: f64, wall_seconds: f64, entropy: *const [32]u8) i32 {
    if (mgr != null) return fail("start", error.AlreadyStarted);
    util.embedded.stopwatch = stopwatch;
    util.embedded.rng = std.Random.DefaultCsprng.init(entropy.*);
    util.embedded.wall_seconds = @intFromFloat(wall_seconds);
    setNow(now);
    const name = name_ptr[0..name_len];
    const seed = @as(u64, seed_hi) << 32 | seed_lo;

    const m = registry.addBytes("host", map_ptr[0..map_len]) catch |e| return fail("map", e);
    const mg = Mgr.init(gpa, &registry, .{
        .create_on_join = false,
        // The host's own session never idles out; the page stops it.
        .idle_close_ns = std.math.maxInt(u64),
        .max_sessions = 1,
        .seed = seed,
    }) catch |e| return fail("manager", e);
    const s = mg.createSession(name, m) catch |e| return fail("session", e);
    if (record) {
        s.replay = replay.Writer.createMem(gpa, .{
            .layout_hash = Sim.layout_hash,
            .map_hash = m.hash,
            .seed = seed,
            .max_players = S.max_players,
            .config_name = Sim.config.name,
            .session = s.name,
            .started = util.wallSeconds(),
        }) catch |e| return fail("replay", e);
    }
    if (level_script) |p| {
        host_level = .{ .script = p.script };
        s.sim.attachLevel(&host_level);
    }
    const shop_count = s.sim.shop_count;
    mgr = mg;
    sess = s;
    cap = if (max_players == 0) S.max_players else @min(max_players, S.max_players);
    stats_t0 = util.embedded.now_ns;

    var hx: [64]u8 = undefined;
    setText("{{\"mapHash\":\"{s}\",\"layoutHash\":\"{x:0>16}\",\"maxPlayers\":{d},\"simMaxPlayers\":{d},\"config\":\"{s}\",\"shops\":{d}}}", .{ util.hex(&hx, &m.hash), Sim.layout_hash, cap, S.max_players, Sim.config.name, shop_count });
    return 0;
}

/// Installs the car models for the game: the style's car info (a .sty's
/// bytes) plus a .gci's handling text (`gci_len` 0 for none), built the same
/// way as the offline game's loadCarInfo (client/wasm). Every player's client
/// installs the same list from the same two files, so prediction and the
/// host agree. Call before `start`; without it the sim uses its one default
/// model. On success `text` holds {"cars": N, "hash": carModelsHash hex}.
export fn loadCars(sty_ptr: [*]const u8, sty_len: usize, gci_ptr: [*]const u8, gci_len: usize) i32 {
    if (mgr != null) return fail("cars", error.AlreadyStarted);
    var style = formats.sty.parse(gpa, sty_ptr[0..sty_len]) catch |e| return fail("style", e);
    defer style.deinit();
    const recs = if (gci_len == 0) &[_]formats.gci.Record{} else formats.gci.parse(gpa, gci_ptr[0..gci_len]) catch |e| return fail("gci", e);
    defer if (gci_len != 0) gpa.free(recs);
    const specs = formats.cars.build(gpa, &style, recs, copyFields(formats.cars.Spec, sim.tuning.default_spec)) catch |e| return fail("cars", e);
    defer gpa.free(specs);
    var models: [sim.tuning.max_car_models]sim.tuning.CarModel = undefined;
    const count = @min(specs.len, models.len);
    for (specs[0..count], models[0..count]) |sp, *m| m.* = sim.tuning.deriveModel(copyFields(sim.tuning.CarSpec, sp));
    sim.tuning.setCarModels(models[0..count]);
    setText("{{\"cars\":{d},\"hash\":\"{x:0>16}\"}}", .{ count, sim.tuning.carModelsHash() });
    return 0;
}

/// Gives the game the map's main script (a .scr's bytes), for its car
/// shops: the sim reads their places from the declarations. Online the
/// script does not run. Call before `start`; without it there are no shops.
export fn loadScript(ptr: [*]const u8, len: usize) i32 {
    if (mgr != null) return fail("script", error.AlreadyStarted);
    if (level_script) |*p| p.deinit();
    level_script = formats.scr.parseMain(gpa, ptr[0..len]) catch |e| return fail("script", e);
    return 0;
}

fn copyFields(comptime To: type, from: anytype) To {
    var r: To = undefined;
    inline for (@typeInfo(To).@"struct".field_names) |name| @field(r, name) = @field(from, name);
    return r;
}

/// The synthetic test city (server/src/maps.zig synthCity) as .gmp bytes in
/// the out-queue's place: read with outPtr/outLen, then outClear. For the
/// soak and demos; needs no game data.
export fn synthMap() i32 {
    const bytes = maps.synthCity(gpa) catch |e| return fail("synth", e);
    defer gpa.free(bytes);
    out.clearRetainingCapacity();
    out.appendSlice(gpa, bytes) catch |e| return fail("synth", e);
    return 0;
}

/// Mirrors Hub.opened. `peer` is the page's id. 0 ok, -1 refused.
export fn opened(peer: u32, transport: u32, now: f64) i32 {
    const mg = mgr orelse return -1;
    if (stopped) return -1;
    setNow(now);
    if (peers.contains(peer)) return fail("opened", error.DuplicatePeer);
    const pr = gpa.create(Peer) catch |e| return fail("opened", e);
    pr.* = .{ .page = peer, .transport = std.enums.fromInt(net.TransportKind, @as(u8, @truncate(transport))) orelse .webrtc };
    peers.put(gpa, peer, pr) catch |e| {
        gpa.destroy(pr);
        return fail("opened", e);
    };
    pr.id = mg.hub().opened(.{ .ptr = pr, .vt = &link_vt }, sess.?.name, pr.transport);
    return 0;
}

/// Mirrors Hub.stream: one reliable I3 message from `peer`.
export fn stream(peer: u32, ptr: [*]const u8, len: usize, now: f64) void {
    const mg = mgr orelse return;
    const pr = peers.get(peer) orelse return;
    setNow(now);
    const body = ptr[0..len];
    if (len > 0 and body[0] == @intFromEnum(wire.Msg.hello) and overCap(mg, pr, body)) {
        // The page asked for fewer players than the sim has slots; the
        // session itself only knows the sim's limit.
        var buf: [128]u8 = undefined;
        var w: wire.Writer = .{ .buf = &buf };
        (wire.Reject{ .code = .session_full, .message = "This session is full." }).encode(&w) catch {};
        linkStream(pr, w.written());
        linkClose(pr);
        return;
    }
    mg.hub().stream(pr.id, body);
}

fn overCap(mg: *Mgr, pr: *Peer, body: []const u8) bool {
    const p = mg.peers.getPtr(pr.id) orelse return false;
    if (p.session != null or p.rejected) return false;
    var names: [wire.max_local_players][]const u8 = undefined;
    var r: wire.Reader = .{ .buf = body };
    const hello = wire.Hello.decode(&r, &names) catch return false;
    const zero: [16]u8 = @splat(0);
    if (!std.mem.eql(u8, &hello.resume_token, &zero)) return false;
    return sess.?.playerCount() + hello.names.len > cap;
}

/// Mirrors Hub.datagram.
export fn datagram(peer: u32, ptr: [*]const u8, len: usize, now: f64) void {
    const mg = mgr orelse return;
    const pr = peers.get(peer) orelse return;
    setNow(now);
    mg.hub().datagram(pr.id, ptr[0..len]);
}

/// Host debug aid: adds `amount` points (negative takes them away) to
/// `slot`'s score between ticks, e.g. to pay a spray shop in a police
/// room. The new score reaches every player in the next snapshot. A game
/// being recorded will not replay the same afterwards.
export fn addPoints(slot: u32, amount: i32) i32 {
    const s = sess orelse return -1;
    if (slot >= Sim.config.max_players) return -1;
    const row = &s.sim.state.players[slot];
    row.score +|= amount;
    return 0;
}

/// Mirrors Hub.closed. Forgets the peer.
export fn closed(peer: u32, now: f64) void {
    const mg = mgr orelse return;
    const kv = peers.fetchRemove(peer) orelse return;
    setNow(now);
    mg.hub().closed(kv.value.id);
    gpa.destroy(kv.value);
}

/// Steps every 30 Hz tick due at `now`, like gta2-server's timer: up to
/// five late ticks are caught up in a burst, beyond that it skips ahead.
/// Returns how many ran.
export fn tick(now: f64) u32 {
    const mg = mgr orelse return 0;
    if (stopped) return 0;
    setNow(now);
    const s = sess.?;
    const ran = mg.advance(util.embedded.now_ns);
    if (ran > 0) {
        // Per-tick samples; a catch-up burst shares its average.
        const step = (s.step_ns_sum - prev_step_sum) / ran;
        const enc = (s.snapshot_ns_sum - prev_snap_sum) / ran;
        prev_step_sum = s.step_ns_sum;
        prev_snap_sum = s.snapshot_ns_sum;
        step_max = @max(step_max, s.step_ns_last);
        for (0..ran) |_| {
            samples_step.append(gpa, @intCast(@min(step, std.math.maxInt(u32)))) catch {};
            samples_encode.append(gpa, @intCast(@min(enc, std.math.maxInt(u32)))) catch {};
        }
    }
    return ran;
}

/// Monotonic ns at which the next tick is due.
export fn nextDeadline() f64 {
    const mg = mgr orelse return 0;
    return @floatFromInt(mg.nextDeadline());
}

fn percentile(xs: []u32, p: u32) u64 {
    if (xs.len == 0) return 0;
    std.mem.sort(u32, xs, {}, std.sort.asc(u32));
    const i = @min(xs.len - 1, (xs.len * p) / 100);
    return xs[i];
}

/// Stats since the last call, as JSON in `text`; returns its length.
/// Field names follow protocol.ts FromHost "stats" (times in us, rates in
/// bytes per second), plus a few extras for the soak.
export fn stats(now: f64) usize {
    const mg = mgr orelse return 0;
    setNow(now);
    const s = sess.?;
    const t = util.embedded.now_ns;
    const window_ns = @max(1, t - stats_t0);
    stats_t0 = t;
    const late = mg.late_ticks - prev_late;
    const skipped = mg.skipped_ticks - prev_skipped;
    prev_late = mg.late_ticks;
    prev_skipped = mg.skipped_ticks;
    const ticks = samples_step.items.len;
    const step50 = percentile(samples_step.items, 50);
    const step99 = percentile(samples_step.items, 99);
    const enc50 = percentile(samples_encode.items, 50);
    const enc99 = percentile(samples_encode.items, 99);
    samples_step.clearRetainingCapacity();
    samples_encode.clearRetainingCapacity();
    const smax = step_max;
    step_max = 0;

    text.clearRetainingCapacity();
    const w = &text;
    w.print(gpa, "{{\"tick\":{d},\"stepUsP50\":{d:.1},\"stepUsP99\":{d:.1},\"stepUsMax\":{d:.1},\"encodeUsP50\":{d:.1},\"encodeUsP99\":{d:.1},\"behindTicks\":{d},\"lateTicks\":{d},\"skippedTicks\":{d},\"ticks\":{d},\"players\":{d},\"replayBytes\":{d},\"peers\":[", .{
        s.sim.tick(), us(step50), us(step99), us(smax), us(enc50), us(enc99), late + skipped, late, skipped, ticks, s.playerCount(),
        if (s.replay) |r| r.captured().len else 0,
    }) catch return 0;
    var first = true;
    for (s.clients.items) |cl| {
        const pr = pageOf(cl.peer) orelse continue;
        const tx = (cl.bytes_tx -| pr.prev_tx) * std.time.ns_per_s / window_ns;
        const rx = (cl.bytes_rx -| pr.prev_rx) * std.time.ns_per_s / window_ns;
        pr.prev_tx = cl.bytes_tx;
        pr.prev_rx = cl.bytes_rx;
        const st = cl.rep.stats;
        w.print(gpa, "{s}{{\"peer\":{d},\"slots\":[", .{ if (first) "" else ",", pr.page }) catch return 0;
        first = false;
        for (cl.slots.items, 0..) |sl, i| w.print(gpa, "{s}{d}", .{ if (i == 0) "" else ",", sl }) catch return 0;
        w.print(gpa, "],\"rttMs\":{d:.1},\"txBps\":{d},\"rxBps\":{d},\"snapshots\":{d},\"lost\":{d}}}", .{ @as(f64, @floatFromInt(st.last_rtt_ns)) / 1e6, tx, rx, st.snapshots, st.lost }) catch return 0;
    }
    w.appendSlice(gpa, "]}") catch return 0;
    return text.items.len;
}

fn us(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}

fn pageOf(id: net.PeerId) ?*Peer {
    var it = peers.valueIterator();
    while (it.next()) |p| if (p.*.id == id) return p.*;
    return null;
}

/// Ends the session: bye(shutting_down) and close to every client (in the
/// out-queue), timer stopped. Returns the replay's length (0 if not
/// recording); read it with replayPtr.
export fn stop(now: f64) usize {
    const mg = mgr orelse return 0;
    if (stopped) return replay_bytes.len;
    setNow(now);
    stopped = true;
    mg.beginShutdown();
    const s = sess.?;
    if (s.replay) |r| {
        replay_bytes = gpa.dupe(u8, r.captured()) catch &.{};
    }
    return replay_bytes.len;
}

export fn replayPtr() [*]const u8 {
    return replay_bytes.ptr;
}

/// Ticks the sim has stepped.
export fn simTick() u32 {
    const s = sess orelse return 0;
    return s.sim.tick();
}
