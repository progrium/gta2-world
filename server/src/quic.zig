//! QUIC + a minimal HTTP/3 + WebTransport server on ngtcp2, carried
//! forward from spike S4 with the echo replaced by the I3 channels.
//!
//! A WebTransport session is an extended CONNECT to `/s/<session>`. The
//! first client-opened bidirectional stream on it is the I3 reliable stream
//! (uvarint-length-prefixed messages); HTTP datagrams on it are I3
//! datagrams. Everything is handed to the `net.Hub` as whole I3 messages.
//!
//! nghttp3's connection layer cannot advertise the WebTransport SETTINGS or
//! hand WebTransport streams back to the application, so this file implements
//! the small slice of HTTP/3 that WebTransport needs (control stream,
//! SETTINGS, HEADERS for extended CONNECT) and uses nghttp3 only for QPACK
//! decoding of the request headers. ngtcp2 does all of QUIC, including
//! DATAGRAM frames (RFC 9221).
const std = @import("std");
const c = @import("c");
const util = @import("util.zig");
const net = @import("net.zig");
const log = std.log.scoped(.quic);
const Allocator = std.mem.Allocator;

pub const SCID_LEN = 18;
const MAX_DGRAM_QUEUE = 1024;

// HTTP/3 and WebTransport wire constants.
const H3_FRAME_DATA = 0x00;
const H3_FRAME_HEADERS = 0x01;
const H3_FRAME_SETTINGS = 0x04;
const H3_STREAM_CONTROL = 0x00;
const H3_STREAM_QPACK_ENC = 0x02;
const H3_STREAM_QPACK_DEC = 0x03;
const WT_STREAM_BIDI_SIGNAL = 0x41;
const WT_STREAM_UNI = 0x54;
const H3_NO_ERROR = 0x100;

/// SETTINGS we send. Browsers have shipped different WebTransport drafts, so
/// we advertise every identifier in use; unknown ones are ignored by peers.
const server_settings = [_][2]u64{
    .{ 0x08, 1 }, // SETTINGS_ENABLE_CONNECT_PROTOCOL (RFC 9220)
    .{ 0x33, 1 }, // SETTINGS_H3_DATAGRAM (RFC 9297)
    .{ 0xffd277, 1 }, // H3_DATAGRAM, draft-ietf-masque-h3-datagram-05 (older Chrome)
    .{ 0x2b603742, 1 }, // SETTINGS_ENABLE_WEBTRANSPORT (draft-02)
    .{ 0xc671706a, 16 }, // SETTINGS_WEBTRANSPORT_MAX_SESSIONS (draft-05..07)
    .{ 0x14e9cd29, 16 }, // SETTINGS_WT_MAX_SESSIONS (draft-08+)
};

pub const Stats = struct {
    conns_total: u64 = 0,
    sessions_total: u64 = 0,
    dgrams_rx: u64 = 0,
    dgrams_tx: u64 = 0,
    dgrams_dropped: u64 = 0,
    stream_bytes_rx: u64 = 0,
    stream_bytes_tx: u64 = 0,
    wt_streams_total: u64 = 0,
};

const CidKey = struct {
    len: u8,
    data: [c.NGTCP2_MAX_CIDLEN]u8,

    fn from(ptr: [*c]const u8, len: usize) CidKey {
        var k = CidKey{ .len = @intCast(len), .data = @splat(0) };
        @memcpy(k.data[0..len], ptr[0..len]);
        return k;
    }
    fn fromCid(cid: *const c.ngtcp2_cid) CidKey {
        return from(&cid.data, cid.datalen);
    }
};

pub const Server = struct {
    gpa: Allocator,
    fd: c_int,
    local: c.struct_sockaddr_storage = undefined,
    local_len: c.socklen_t = 0,
    cred: c.gnutls_certificate_credentials_t = null,
    priority: c.gnutls_priority_t = null,
    static_secret: [32]u8 = undefined,
    conns: std.AutoHashMapUnmanaged(CidKey, *Conn) = .empty,
    list: std.ArrayList(*Conn) = .empty,
    stats: Stats = .{},
    verbose: bool = false,
    /// Test knob: drop this fraction (0..1) of UDP packets in each direction.
    loss: f64 = 0,
    prng: std.Random.DefaultPrng = .init(0x5345),
    sendbuf: [65536]u8 = undefined,
    hub: net.Hub,

    pub fn init(gpa: Allocator, hub: net.Hub, port: u16, cert: [:0]const u8, key: [:0]const u8, verbose: bool) !*Server {
        const self = try gpa.create(Server);
        self.* = .{ .gpa = gpa, .fd = -1, .verbose = verbose, .hub = hub };
        util.randomBytes(&self.static_secret);

        self.cred = try loadCred(cert, key);
        const prio = "%DISABLE_TLS13_COMPAT_MODE:NORMAL:-VERS-ALL:+VERS-TLS1.3:" ++
            "-CIPHER-ALL:+AES-128-GCM:+AES-256-GCM:+CHACHA20-POLY1305:+AES-128-CCM:" ++
            "-GROUP-ALL:+GROUP-X25519:+GROUP-SECP256R1:+GROUP-SECP384R1:+GROUP-SECP521R1";
        if (c.gnutls_priority_init(&self.priority, prio, null) != 0) return error.Tls;

        self.fd = try util.bindAny(c.SOCK_DGRAM, port);
        var bufsz: c_int = 4 * 1024 * 1024;
        _ = c.setsockopt(self.fd, c.SOL_SOCKET, c.SO_RCVBUF, &bufsz, @sizeOf(c_int));
        _ = c.setsockopt(self.fd, c.SOL_SOCKET, c.SO_SNDBUF, &bufsz, @sizeOf(c_int));
        self.local_len = @sizeOf(c.struct_sockaddr_storage);
        _ = c.getsockname(self.fd, @ptrCast(&self.local), &self.local_len);
        return self;
    }

    /// Drain the UDP socket.
    pub fn onReadable(self: *Server) void {
        var buf: [65536]u8 = undefined;
        var n_read: usize = 0;
        while (n_read < 4096) : (n_read += 1) {
            var remote: c.struct_sockaddr_storage = undefined;
            var rlen: c.socklen_t = @sizeOf(c.struct_sockaddr_storage);
            const n = c.recvfrom(self.fd, &buf, buf.len, 0, @ptrCast(&remote), &rlen);
            if (n < 0) return; // EAGAIN or error
            if (self.dropForTest()) continue;
            self.onPacket(buf[0..@intCast(n)], &remote, rlen);
        }
    }

    fn onPacket(self: *Server, pkt: []const u8, remote: *c.struct_sockaddr_storage, rlen: c.socklen_t) void {
        var vc: c.ngtcp2_version_cid = .{};
        const rv = c.ngtcp2_pkt_decode_version_cid(&vc, pkt.ptr, pkt.len, SCID_LEN);
        if (rv == c.NGTCP2_ERR_VERSION_NEGOTIATION) {
            self.sendVersionNegotiation(&vc, remote, rlen);
            return;
        }
        if (rv != 0) return;

        if (self.conns.get(CidKey.from(vc.dcid, vc.dcidlen))) |conn| {
            if (conn.dead) return;
            conn.onPacket(pkt, remote, rlen);
            return;
        }
        if (pkt[0] & 0x80 == 0) return; // short header for unknown connection: drop
        var hd: c.ngtcp2_pkt_hd = undefined;
        if (c.ngtcp2_accept(&hd, pkt.ptr, pkt.len) != 0) return;
        const conn = Conn.create(self, &hd, remote, rlen) catch |e| {
            log.err("accept failed: {}", .{e});
            return;
        };
        self.stats.conns_total += 1;
        conn.onPacket(pkt, remote, rlen);
    }

    fn sendVersionNegotiation(self: *Server, vc: *const c.ngtcp2_version_cid, remote: *c.struct_sockaddr_storage, rlen: c.socklen_t) void {
        const sv = [_]u32{c.NGTCP2_PROTO_VER_V1};
        var b: [1]u8 = undefined;
        util.randomBytes(&b);
        const n = c.ngtcp2_pkt_write_version_negotiation(&self.sendbuf, self.sendbuf.len, b[0], vc.scid, vc.scidlen, vc.dcid, vc.dcidlen, &sv, sv.len);
        if (n > 0) _ = c.sendto(self.fd, &self.sendbuf, @intCast(n), 0, @ptrCast(remote), rlen);
    }

    /// Run timers for every connection; returns the next deadline (monotonic ns).
    pub fn onTimers(self: *Server) u64 {
        const t = util.now();
        var next: u64 = std.math.maxInt(u64);
        for (self.list.items) |conn| {
            if (conn.dead) continue;
            const exp = c.ngtcp2_conn_get_expiry2(conn.conn);
            if (exp <= t) {
                const rv = c.ngtcp2_conn_handle_expiry(conn.conn, t);
                if (rv != 0) {
                    conn.fail(rv);
                    continue;
                }
                conn.write();
            }
            if (!conn.dead) next = @min(next, c.ngtcp2_conn_get_expiry2(conn.conn));
        }
        self.sweep();
        return next;
    }

    fn sweep(self: *Server) void {
        var i: usize = 0;
        while (i < self.list.items.len) {
            const conn = self.list.items[i];
            if (!conn.dead) {
                i += 1;
                continue;
            }
            _ = self.list.swapRemove(i);
            var keys: std.ArrayList(CidKey) = .empty;
            defer keys.deinit(self.gpa);
            var it = self.conns.iterator();
            while (it.next()) |e| if (e.value_ptr.* == conn) keys.append(self.gpa, e.key_ptr.*) catch {};
            for (keys.items) |k| _ = self.conns.remove(k);
            conn.destroy();
        }
    }

    fn dropForTest(self: *Server) bool {
        return self.loss > 0 and self.prng.random().float(f64) < self.loss;
    }

    pub fn liveConns(self: *Server) usize {
        return self.list.items.len;
    }

    /// Re-read the certificate (after a Let's Encrypt renewal). New
    /// connections use it; live ones keep the old credentials, which are
    /// deliberately never freed.
    pub fn reloadCert(self: *Server, cert: [:0]const u8, key: [:0]const u8) !void {
        self.cred = try loadCred(cert, key);
    }

    /// Close sessions the hub asked to close, then write everything the
    /// sessions queued since the last call.
    pub fn flushAll(self: *Server) void {
        for (self.list.items) |conn| {
            if (conn.dead) continue;
            for (conn.wt.items) |ws| if (ws.close_requested and !ws.ended) {
                if (conn.streams.get(ws.stream_id)) |st| st.fin_pending = true;
                if (conn.streams.get(ws.session_id)) |st| st.fin_pending = true;
                conn.endSession(ws);
                conn.pending_write = true;
            };
            if (conn.pending_write) {
                conn.pending_write = false;
                conn.write();
            }
        }
    }
};

fn loadCred(cert: [:0]const u8, key: [:0]const u8) !c.gnutls_certificate_credentials_t {
    var cred: c.gnutls_certificate_credentials_t = null;
    if (c.gnutls_certificate_allocate_credentials(&cred) != 0) return error.Tls;
    const rv = c.gnutls_certificate_set_x509_key_file(cred, cert.ptr, key.ptr, c.GNUTLS_X509_FMT_PEM);
    if (rv != 0) {
        log.err("loading {s}/{s}: {s}", .{ cert, key, c.gnutls_strerror(rv) });
        return error.Tls;
    }
    return cred;
}

/// One WebTransport session (an extended CONNECT stream) and its I3 link.
const WtSession = struct {
    conn: *Conn,
    /// The CONNECT stream id; datagrams carry session_id / 4.
    session_id: i64,
    /// The I3 reliable stream: the first bidi stream the client opens.
    stream_id: i64 = -1,
    peer: net.PeerId = 0,
    rbuf: std.ArrayList(u8) = .empty,
    close_requested: bool = false,
    /// The hub has been told this link is closed.
    ended: bool = false,

    const vt: net.Link.VTable = .{ .sendDatagram = sendDatagram, .sendStream = sendStream, .close = close, .maxDatagram = maxDatagram };

    fn link(ws: *WtSession) net.Link {
        return .{ .ptr = ws, .vt = &vt };
    }
    fn from(p: *anyopaque) *WtSession {
        return @ptrCast(@alignCast(p));
    }
    fn sendDatagram(p: *anyopaque, body: []const u8) void {
        const ws = from(p);
        const conn = ws.conn;
        if (ws.ended or ws.close_requested or conn.dead) return;
        if (conn.dgrams.items.len >= MAX_DGRAM_QUEUE) {
            conn.server.stats.dgrams_dropped += 1;
            return;
        }
        var hdr: std.ArrayList(u8) = .empty;
        defer hdr.deinit(conn.gpa);
        util.putVarint(conn.gpa, &hdr, @intCast(@divTrunc(ws.session_id, 4))) catch return;
        const d = conn.gpa.alloc(u8, hdr.items.len + body.len) catch return;
        @memcpy(d[0..hdr.items.len], hdr.items);
        @memcpy(d[hdr.items.len..], body);
        conn.dgrams.append(conn.gpa, d) catch {
            conn.gpa.free(d);
            return;
        };
        conn.pending_write = true;
    }
    fn sendStream(p: *anyopaque, body: []const u8) void {
        const ws = from(p);
        const conn = ws.conn;
        if (ws.ended or ws.close_requested or conn.dead or ws.stream_id < 0) return;
        const st = conn.streams.get(ws.stream_id) orelse return;
        // I3 stream framing: unsigned LEB128 length, then the body.
        var lenbuf: [10]u8 = undefined;
        var n: usize = 0;
        var v: u64 = body.len;
        while (true) {
            const b: u8 = @truncate(v & 0x7f);
            v >>= 7;
            if (v == 0) {
                lenbuf[n] = b;
                n += 1;
                break;
            }
            lenbuf[n] = b | 0x80;
            n += 1;
        }
        st.queue(conn.gpa, lenbuf[0..n]) catch return;
        st.queue(conn.gpa, body) catch return;
        conn.pending_write = true;
    }
    fn close(p: *anyopaque) void {
        const ws = from(p);
        ws.close_requested = true;
        ws.conn.pending_write = true;
    }
    fn maxDatagram(p: *anyopaque) usize {
        const ws = from(p);
        if (ws.conn.dead) return 0;
        // Room for the short header, AEAD tag, frame header and the
        // quarter stream id.
        return c.ngtcp2_conn_get_path_max_tx_udp_payload_size(ws.conn.conn) -| 64;
    }

    /// Feeds bytes from the I3 stream; hands each whole message to the hub.
    fn onData(ws: *WtSession, data: []const u8) !void {
        const conn = ws.conn;
        try ws.rbuf.appendSlice(conn.gpa, data);
        var used: usize = 0;
        while (!ws.ended and !ws.close_requested) {
            const rest = ws.rbuf.items[used..];
            // uvarint length
            var len: u64 = 0;
            var shift: u6 = 0;
            var i: usize = 0;
            const complete = while (i < rest.len and i < 10) : (i += 1) {
                len |= @as(u64, rest[i] & 0x7f) << shift;
                if (rest[i] & 0x80 == 0) break true;
                shift +|= 7;
            } else false;
            if (!complete) {
                if (rest.len >= 10) return error.BadFrame;
                break;
            }
            if (len > 1 << 20) return error.BadFrame;
            const hl = i + 1;
            if (rest.len < hl + len) break;
            conn.server.hub.stream(ws.peer, rest[hl..][0..@intCast(len)]);
            used += hl + @as(usize, @intCast(len));
        }
        std.mem.copyForwards(u8, ws.rbuf.items, ws.rbuf.items[used..]);
        ws.rbuf.shrinkRetainingCapacity(ws.rbuf.items.len - used);
    }
};

const Kind = enum {
    /// Client bidi stream whose first varint we have not seen yet.
    pending_bidi,
    /// Client uni stream whose type we have not seen yet.
    pending_uni,
    /// HTTP/3 request stream before or after the response.
    h3_request,
    /// A request stream that became a WebTransport session.
    wt_session,
    /// WebTransport bidirectional stream carrying I3 (the first one per session).
    wt_bidi,
    /// Client WebTransport uni stream: not used by I3, ignored.
    wt_uni_in,
    /// Server-initiated stream (control).
    local,
    /// Peer control / QPACK streams and anything we do not care about.
    ignore,
};

const Stream = struct {
    id: i64,
    kind: Kind,
    rbuf: std.ArrayList(u8) = .empty,
    session_id: u64 = 0,
    echo_to: i64 = -1,

    // Outbound data must stay alive until acknowledged, so it is held in
    // chunks that are freed once fully acked.
    chunks: std.ArrayList([]u8) = .empty,
    chunks_base: u64 = 0, // stream offset of chunks[0][0]
    queued: u64 = 0, // total bytes ever queued
    sent: u64 = 0, // bytes handed to ngtcp2
    acked: u64 = 0,
    fin_pending: bool = false,
    fin_sent: bool = false,
    blocked_gen: u64 = 0,

    fn queue(s: *Stream, gpa: Allocator, data: []const u8) !void {
        if (data.len == 0) return;
        try s.chunks.append(gpa, try gpa.dupe(u8, data));
        s.queued += data.len;
    }

    fn wantsWrite(s: *const Stream) bool {
        return s.sent < s.queued or (s.fin_pending and !s.fin_sent);
    }

    /// Fill `vecs` with unsent data. Returns count and whether it covers all of it.
    fn unsent(s: *Stream, vecs: []c.ngtcp2_vec) struct { n: usize, all: bool } {
        var off = s.chunks_base;
        var n: usize = 0;
        for (s.chunks.items, 0..) |ch, i| {
            const end = off + ch.len;
            if (end > s.sent) {
                if (n == vecs.len) return .{ .n = n, .all = false };
                const skip: usize = @intCast(if (s.sent > off) s.sent - off else 0);
                vecs[n] = .{ .base = ch.ptr + skip, .len = ch.len - skip };
                n += 1;
            }
            off = end;
            _ = i;
        }
        return .{ .n = n, .all = true };
    }

    fn ack(s: *Stream, gpa: Allocator, upto: u64) void {
        if (upto > s.acked) s.acked = upto;
        var drop: usize = 0;
        for (s.chunks.items) |ch| {
            if (s.chunks_base + ch.len > s.acked) break;
            s.chunks_base += ch.len;
            gpa.free(ch);
            drop += 1;
        }
        if (drop > 0) {
            std.mem.copyForwards([]u8, s.chunks.items[0..], s.chunks.items[drop..]);
            s.chunks.shrinkRetainingCapacity(s.chunks.items.len - drop);
        }
    }

    fn deinit(s: *Stream, gpa: Allocator) void {
        for (s.chunks.items) |ch| gpa.free(ch);
        s.chunks.deinit(gpa);
        s.rbuf.deinit(gpa);
    }
};

const Conn = struct {
    server: *Server,
    gpa: Allocator,
    conn: ?*c.ngtcp2_conn = null,
    tls: c.gnutls_session_t = null,
    conn_ref: c.ngtcp2_crypto_conn_ref = .{},
    remote: c.struct_sockaddr_storage = undefined,
    remote_len: c.socklen_t = 0,
    streams: std.AutoHashMapUnmanaged(i64, *Stream) = .empty,
    dgrams: std.ArrayList([]u8) = .empty,
    qpack: ?*c.nghttp3_qpack_decoder = null,
    control_opened: bool = false,
    write_gen: u64 = 0,
    dead: bool = false,
    sessions: u32 = 0,
    label: [32]u8 = undefined,
    label_len: usize = 0,
    wt: std.ArrayList(*WtSession) = .empty,
    pending_write: bool = false,

    const callbacks = c.ngtcp2_callbacks{
        .recv_client_initial = c.ngtcp2_crypto_recv_client_initial_cb,
        .recv_crypto_data = c.ngtcp2_crypto_recv_crypto_data_cb,
        .handshake_completed = cbHandshakeCompleted,
        .encrypt = c.ngtcp2_crypto_encrypt_cb,
        .decrypt = c.ngtcp2_crypto_decrypt_cb,
        .hp_mask = c.ngtcp2_crypto_hp_mask_cb,
        .recv_stream_data = cbRecvStreamData,
        .acked_stream_data_offset = cbAckedStreamDataOffset,
        .rand = cbRand,
        .remove_connection_id = cbRemoveConnectionId,
        .update_key = c.ngtcp2_crypto_update_key_cb,
        .stream_reset = cbStreamReset,
        .delete_crypto_aead_ctx = c.ngtcp2_crypto_delete_crypto_aead_ctx_cb,
        .delete_crypto_cipher_ctx = c.ngtcp2_crypto_delete_crypto_cipher_ctx_cb,
        .recv_datagram = cbRecvDatagram,
        .version_negotiation = c.ngtcp2_crypto_version_negotiation_cb,
        .get_new_connection_id2 = cbGetNewConnectionId,
        .get_path_challenge_data2 = c.ngtcp2_crypto_get_path_challenge_data2_cb,
        .stream_close2 = cbStreamClose,
    };

    fn create(server: *Server, hd: *const c.ngtcp2_pkt_hd, remote: *const c.struct_sockaddr_storage, rlen: c.socklen_t) !*Conn {
        const gpa = server.gpa;
        const self = try gpa.create(Conn);
        errdefer gpa.destroy(self);
        self.* = .{ .server = server, .gpa = gpa };
        self.remote = remote.*;
        self.remote_len = rlen;
        self.setLabel();

        var scid: c.ngtcp2_cid = .{ .datalen = SCID_LEN };
        util.randomBytes(scid.data[0..SCID_LEN]);

        var settings: c.ngtcp2_settings = undefined;
        c.ngtcp2_settings_default(&settings);
        settings.initial_ts = util.now();
        if (server.verbose) settings.log_printf = logPrintf;

        var params: c.ngtcp2_transport_params = undefined;
        c.ngtcp2_transport_params_default(&params);
        params.initial_max_stream_data_bidi_local = 1 << 20;
        params.initial_max_stream_data_bidi_remote = 1 << 20;
        params.initial_max_stream_data_uni = 1 << 20;
        params.initial_max_data = 4 << 20;
        params.initial_max_streams_bidi = 100;
        params.initial_max_streams_uni = 100;
        params.max_idle_timeout = 30 * c.NGTCP2_SECONDS;
        params.max_datagram_frame_size = 65535;
        params.active_connection_id_limit = 7;
        params.original_dcid = hd.dcid;
        params.original_dcid_present = 1;
        params.stateless_reset_token_present = 1;
        if (c.ngtcp2_crypto_generate_stateless_reset_token(&params.stateless_reset_token, &server.static_secret, server.static_secret.len, &scid) != 0)
            return error.Quic;

        var path: c.ngtcp2_path = .{
            .local = .{ .addr = @ptrCast(&server.local), .addrlen = server.local_len },
            .remote = .{ .addr = @ptrCast(&self.remote), .addrlen = self.remote_len },
        };
        var rv = c.ngtcp2_conn_server_new(&self.conn, &hd.scid, &scid, &path, hd.version, &callbacks, &settings, &params, null, self);
        if (rv != 0) {
            log.err("ngtcp2_conn_server_new: {s}", .{c.ngtcp2_strerror(rv)});
            return error.Quic;
        }
        errdefer c.ngtcp2_conn_del(self.conn);

        // TLS 1.3 via GnuTLS, glued to QUIC by ngtcp2_crypto_gnutls.
        rv = c.gnutls_init(&self.tls, c.GNUTLS_SERVER | c.GNUTLS_NO_AUTO_SEND_TICKET | c.GNUTLS_NO_END_OF_EARLY_DATA);
        if (rv != 0) return error.Tls;
        errdefer c.gnutls_deinit(self.tls);
        if (c.gnutls_priority_set(self.tls, server.priority) != 0) return error.Tls;
        if (c.ngtcp2_crypto_gnutls_configure_server_session(self.tls) != 0) return error.Tls;
        if (c.gnutls_credentials_set(self.tls, c.GNUTLS_CRD_CERTIFICATE, server.cred) != 0) return error.Tls;
        const alpn = c.gnutls_datum_t{ .data = @constCast("h3".ptr), .size = 2 };
        _ = c.gnutls_alpn_set_protocols(self.tls, &alpn, 1, c.GNUTLS_ALPN_MANDATORY | c.GNUTLS_ALPN_SERVER_PRECEDENCE);
        self.conn_ref = .{ .get_conn = getConn, .user_data = self };
        c.gnutls_session_set_ptr(self.tls, &self.conn_ref);
        c.ngtcp2_conn_set_tls_native_handle(self.conn, self.tls);

        if (c.nghttp3_qpack_decoder_new(&self.qpack, 0, 0, c.nghttp3_mem_default()) != 0) return error.Qpack;

        try server.conns.put(gpa, CidKey.fromCid(&scid), self);
        try server.conns.put(gpa, CidKey.fromCid(&hd.dcid), self);
        try server.list.append(gpa, self);
        log.info("{s}: new connection", .{self.name()});
        return self;
    }

    fn setLabel(self: *Conn) void {
        var host: [64]u8 = undefined;
        var port: u16 = 0;
        var h: []const u8 = "?";
        if (self.remote.ss_family == c.AF_INET6) {
            const a: *const c.struct_sockaddr_in6 = @ptrCast(@alignCast(&self.remote));
            if (c.inet_ntop(c.AF_INET6, &a.sin6_addr, &host, host.len) != null) h = std.mem.sliceTo(&host, 0);
            port = c.ntohs(a.sin6_port);
        } else if (self.remote.ss_family == c.AF_INET) {
            const a: *const c.struct_sockaddr_in = @ptrCast(@alignCast(&self.remote));
            if (c.inet_ntop(c.AF_INET, &a.sin_addr, &host, host.len) != null) h = std.mem.sliceTo(&host, 0);
            port = c.ntohs(a.sin_port);
        }
        if (std.mem.startsWith(u8, h, "::ffff:")) h = h[7..];
        const s = std.fmt.bufPrint(&self.label, "{s}:{d}", .{ h[0..@min(h.len, 24)], port }) catch "?";
        self.label_len = s.len;
    }

    fn name(self: *const Conn) []const u8 {
        return self.label[0..self.label_len];
    }

    fn findSession(self: *Conn, session_id: i64) ?*WtSession {
        for (self.wt.items) |ws| if (ws.session_id == session_id) return ws;
        return null;
    }

    fn endSession(self: *Conn, ws: *WtSession) void {
        _ = self;
        if (ws.ended) return;
        ws.ended = true;
        ws.conn.server.hub.closed(ws.peer);
    }

    fn destroy(self: *Conn) void {
        log.info("{s}: closed ({d} sessions)", .{ self.name(), self.sessions });
        for (self.wt.items) |ws| {
            self.endSession(ws);
            ws.rbuf.deinit(self.gpa);
            self.gpa.destroy(ws);
        }
        self.wt.deinit(self.gpa);
        var it = self.streams.valueIterator();
        while (it.next()) |s| {
            s.*.deinit(self.gpa);
            self.gpa.destroy(s.*);
        }
        self.streams.deinit(self.gpa);
        for (self.dgrams.items) |d| self.gpa.free(d);
        self.dgrams.deinit(self.gpa);
        if (self.qpack) |q| c.nghttp3_qpack_decoder_del(q);
        c.ngtcp2_conn_del(self.conn);
        c.gnutls_deinit(self.tls);
        self.gpa.destroy(self);
    }

    fn onPacket(self: *Conn, pkt: []const u8, remote: *c.struct_sockaddr_storage, rlen: c.socklen_t) void {
        var path: c.ngtcp2_path = .{
            .local = .{ .addr = @ptrCast(&self.server.local), .addrlen = self.server.local_len },
            .remote = .{ .addr = @ptrCast(remote), .addrlen = rlen },
        };
        var pi: c.ngtcp2_pkt_info = .{};
        const rv = c.ngtcp2_conn_read_pkt(self.conn, &path, &pi, pkt.ptr, pkt.len, util.now());
        if (rv != 0) {
            self.fail(rv);
            return;
        }
        self.write();
    }

    /// Tear the connection down after a library error, sending
    /// CONNECTION_CLOSE where that is appropriate.
    fn fail(self: *Conn, rv: c_int) void {
        if (self.dead) return;
        self.dead = true;
        switch (rv) {
            c.NGTCP2_ERR_DRAINING, c.NGTCP2_ERR_DROP_CONN, c.NGTCP2_ERR_IDLE_CLOSE => {
                log.info("{s}: {s}", .{ self.name(), c.ngtcp2_strerror(rv) });
                return;
            },
            else => {},
        }
        log.info("{s}: closing: {s}", .{ self.name(), c.ngtcp2_strerror(rv) });
        var ccerr: c.ngtcp2_ccerr = undefined;
        c.ngtcp2_ccerr_default(&ccerr);
        if (rv == c.NGTCP2_ERR_CRYPTO)
            c.ngtcp2_ccerr_set_tls_alert(&ccerr, c.ngtcp2_conn_get_tls_alert(self.conn), null, 0)
        else
            c.ngtcp2_ccerr_set_liberr(&ccerr, rv, null, 0);
        var ps: c.ngtcp2_path_storage = undefined;
        c.ngtcp2_path_storage_zero(&ps);
        var pi: c.ngtcp2_pkt_info = .{};
        const buf = &self.server.sendbuf;
        const n = c.ngtcp2_conn_write_connection_close(self.conn, &ps.path, &pi, buf, buf.len, &ccerr, util.now());
        if (n > 0) self.sendto(&ps.path, buf[0..@intCast(n)]);
    }

    fn sendto(self: *Conn, path: *const c.ngtcp2_path, data: []const u8) void {
        if (self.server.dropForTest()) return;
        _ = c.sendto(self.server.fd, data.ptr, data.len, 0, path.remote.addr, path.remote.addrlen);
    }

    /// Write as many packets as congestion control and pacing allow:
    /// queued datagrams first, then any stream with unsent data.
    fn write(self: *Conn) void {
        if (self.dead) return;
        var ps: c.ngtcp2_path_storage = undefined;
        c.ngtcp2_path_storage_zero(&ps);
        var pi: c.ngtcp2_pkt_info = .{};
        const buf = &self.server.sendbuf;
        const destlen = @min(buf.len, c.ngtcp2_conn_get_path_max_tx_udp_payload_size(self.conn));
        const ts = util.now();
        self.write_gen += 1;
        const gen = self.write_gen;
        var vecs: [16]c.ngtcp2_vec = undefined;

        while (true) {
            var n: c.ngtcp2_ssize = 0;
            if (self.dgrams.items.len > 0) {
                const d = self.dgrams.items[0];
                var accepted: c_int = 0;
                const v = c.ngtcp2_vec{ .base = d.ptr, .len = d.len };
                n = c.ngtcp2_conn_writev_datagram(self.conn, &ps.path, &pi, buf, destlen, &accepted, c.NGTCP2_WRITE_DATAGRAM_FLAG_MORE, 0, &v, 1, ts);
                if (accepted != 0 or (n < 0 and n != c.NGTCP2_ERR_WRITE_MORE)) {
                    if (accepted != 0) self.server.stats.dgrams_tx += 1 else self.server.stats.dgrams_dropped += 1;
                    self.gpa.free(d);
                    _ = self.dgrams.orderedRemove(0);
                }
                if (n == c.NGTCP2_ERR_WRITE_MORE) continue;
                if (n == c.NGTCP2_ERR_INVALID_ARGUMENT) continue; // too large for a packet: dropped above
                if (n < 0) return self.fail(@intCast(n));
            } else if (self.pickStream(gen)) |s| {
                const u = s.unsent(&vecs);
                var flags: u32 = c.NGTCP2_WRITE_STREAM_FLAG_MORE;
                if (s.fin_pending and u.all) flags |= c.NGTCP2_WRITE_STREAM_FLAG_FIN;
                var pdatalen: c.ngtcp2_ssize = -1;
                n = c.ngtcp2_conn_writev_stream(self.conn, &ps.path, &pi, buf, destlen, &pdatalen, flags, s.id, &vecs, u.n, ts);
                if (pdatalen >= 0) {
                    s.sent += @intCast(pdatalen);
                    if (flags & c.NGTCP2_WRITE_STREAM_FLAG_FIN != 0 and s.sent == s.queued) s.fin_sent = true;
                    if (s.kind == .wt_bidi) self.server.stats.stream_bytes_tx += @intCast(pdatalen);
                }
                switch (n) {
                    c.NGTCP2_ERR_WRITE_MORE => continue,
                    c.NGTCP2_ERR_STREAM_DATA_BLOCKED, c.NGTCP2_ERR_STREAM_SHUT_WR, c.NGTCP2_ERR_STREAM_NOT_FOUND => {
                        s.blocked_gen = gen;
                        if (n != c.NGTCP2_ERR_STREAM_DATA_BLOCKED) {
                            // Stream is gone for writing; discard what we hold.
                            s.sent = s.queued;
                            s.fin_sent = true;
                        }
                        continue;
                    },
                    else => if (n < 0) return self.fail(@intCast(n)),
                }
            } else {
                n = c.ngtcp2_conn_writev_stream(self.conn, &ps.path, &pi, buf, destlen, null, 0, -1, null, 0, ts);
                if (n < 0) return self.fail(@intCast(n));
            }
            if (n == 0) break;
            self.sendto(&ps.path, buf[0..@intCast(n)]);
        }
        c.ngtcp2_conn_update_pkt_tx_time(self.conn, ts);
    }

    fn pickStream(self: *Conn, gen: u64) ?*Stream {
        var it = self.streams.valueIterator();
        while (it.next()) |s| {
            if (s.*.blocked_gen != gen and s.*.wantsWrite()) return s.*;
        }
        return null;
    }

    fn getStream(self: *Conn, id: i64) !*Stream {
        if (self.streams.get(id)) |s| return s;
        const s = try self.gpa.create(Stream);
        const client_initiated = id & 1 == 0;
        const bidi = id & 2 == 0;
        s.* = .{
            .id = id,
            .kind = if (!client_initiated) .local else if (bidi) .pending_bidi else .pending_uni,
        };
        try self.streams.put(self.gpa, id, s);
        return s;
    }

    fn openUni(self: *Conn) ?*Stream {
        var id: i64 = -1;
        if (c.ngtcp2_conn_open_uni_stream(self.conn, &id, null) != 0) return null;
        return self.getStream(id) catch null;
    }

    fn openControlStream(self: *Conn) !void {
        const s = self.openUni() orelse return error.StreamIdBlocked;
        var b: std.ArrayList(u8) = .empty;
        defer b.deinit(self.gpa);
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.gpa);
        for (server_settings) |kv| {
            try util.putVarint(self.gpa, &payload, kv[0]);
            try util.putVarint(self.gpa, &payload, kv[1]);
        }
        try util.putVarint(self.gpa, &b, H3_STREAM_CONTROL);
        try util.putVarint(self.gpa, &b, H3_FRAME_SETTINGS);
        try util.putVarint(self.gpa, &b, payload.items.len);
        try b.appendSlice(self.gpa, payload.items);
        try s.queue(self.gpa, b.items);
        self.control_opened = true;
    }

    fn onStreamData(self: *Conn, id: i64, data: []const u8, fin: bool) !void {
        const s = try self.getStream(id);
        switch (s.kind) {
            .wt_bidi => {
                self.server.stats.stream_bytes_rx += data.len;
                try self.onI3Data(s, data, fin);
                return;
            },
            .wt_uni_in => return,
            .ignore, .local => return,
            else => {},
        }
        try s.rbuf.appendSlice(self.gpa, data);
        try self.parse(s, fin);
    }

    fn parse(self: *Conn, s: *Stream, fin: bool) !void {
        const gpa = self.gpa;
        switch (s.kind) {
            .pending_bidi => {
                const t = util.readVarint(s.rbuf.items) orelse return;
                if (t.value == WT_STREAM_BIDI_SIGNAL) {
                    const sid = util.readVarint(s.rbuf.items[t.len..]) orelse return;
                    s.session_id = sid.value;
                    const ws = self.findSession(@intCast(sid.value));
                    if (ws == null or ws.?.stream_id >= 0) {
                        // Unknown session, or a second stream: I3 uses one.
                        s.kind = .ignore;
                        s.rbuf.clearAndFree(gpa);
                        _ = c.ngtcp2_conn_shutdown_stream(self.conn, 0, s.id, 0x0103);
                        return;
                    }
                    s.kind = .wt_bidi;
                    ws.?.stream_id = s.id;
                    self.server.stats.wt_streams_total += 1;
                    const rest = try gpa.dupe(u8, s.rbuf.items[t.len + sid.len ..]);
                    defer gpa.free(rest);
                    s.rbuf.clearAndFree(gpa);
                    self.server.stats.stream_bytes_rx += rest.len;
                    try self.onI3Data(s, rest, fin);
                } else {
                    s.kind = .h3_request;
                    try self.parse(s, fin);
                }
            },
            .pending_uni => {
                const t = util.readVarint(s.rbuf.items) orelse return;
                switch (t.value) {
                    WT_STREAM_UNI => {
                        s.kind = .wt_uni_in;
                        s.rbuf.clearAndFree(gpa);
                    },
                    H3_STREAM_CONTROL, H3_STREAM_QPACK_ENC, H3_STREAM_QPACK_DEC => {
                        // We advertise a zero-size QPACK table and need nothing
                        // from the peer's SETTINGS for an echo server.
                        s.kind = .ignore;
                        s.rbuf.clearAndFree(gpa);
                    },
                    else => {
                        s.kind = .ignore;
                        s.rbuf.clearAndFree(gpa);
                        _ = c.ngtcp2_conn_shutdown_stream_read(self.conn, 0, s.id, 0x0103); // H3_STREAM_CREATION_ERROR
                    },
                }
            },
            .h3_request, .wt_session => {
                while (true) {
                    const buf = s.rbuf.items;
                    const t = util.readVarint(buf) orelse break;
                    const l = util.readVarint(buf[t.len..]) orelse break;
                    const hlen = t.len + l.len;
                    if (buf.len < hlen + l.value) break;
                    const payload = buf[hlen..][0..@intCast(l.value)];
                    if (t.value == H3_FRAME_HEADERS and s.kind == .h3_request) try self.onHeaders(s, payload);
                    // DATA frames on a session stream carry capsules (e.g.
                    // CLOSE_WEBTRANSPORT_SESSION); unknown frames are skipped.
                    const consumed = hlen + payload.len;
                    std.mem.copyForwards(u8, s.rbuf.items, s.rbuf.items[consumed..]);
                    s.rbuf.shrinkRetainingCapacity(s.rbuf.items.len - consumed);
                }
                if (fin) {
                    if (s.kind == .wt_session) {
                        log.info("{s}: wt session {d} closed by client", .{ self.name(), s.id });
                        if (self.findSession(s.id)) |ws| self.endSession(ws);
                    }
                    s.fin_pending = true;
                }
            },
            else => {},
        }
    }

    fn onI3Data(self: *Conn, s: *Stream, data: []const u8, fin: bool) !void {
        const ws = self.findSession(@intCast(s.session_id)) orelse return;
        if (ws.stream_id != s.id or ws.ended) return;
        ws.onData(data) catch {
            ws.close_requested = true;
            self.pending_write = true;
        };
        if (fin) {
            s.fin_pending = true;
            self.endSession(ws);
        }
    }

    fn onHeaders(self: *Conn, s: *Stream, block: []const u8) !void {
        var method: [16]u8 = undefined;
        var method_len: usize = 0;
        var protocol: [32]u8 = undefined;
        var protocol_len: usize = 0;
        var path: [128]u8 = undefined;
        var path_len: usize = 0;

        var sctx: ?*c.nghttp3_qpack_stream_context = null;
        if (c.nghttp3_qpack_stream_context_new(&sctx, s.id, c.nghttp3_mem_default()) != 0) return error.Qpack;
        defer c.nghttp3_qpack_stream_context_del(sctx);
        var p = block;
        while (true) {
            var nv: c.nghttp3_qpack_nv = .{};
            var flags: u8 = 0;
            const n = c.nghttp3_qpack_decoder_read_request(self.qpack, sctx, &nv, &flags, p.ptr, p.len, 1);
            if (n < 0) {
                log.warn("{s}: QPACK decode error {d}", .{ self.name(), n });
                return self.respond(s, 400, true);
            }
            p = p[@intCast(n)..];
            if (flags & c.NGHTTP3_QPACK_DECODE_FLAG_EMIT != 0) {
                const k = c.nghttp3_rcbuf_get_buf(nv.name);
                const v = c.nghttp3_rcbuf_get_buf(nv.value);
                const key = k.base[0..k.len];
                const val = v.base[0..v.len];
                if (std.mem.eql(u8, key, ":method")) method_len = copyTrunc(&method, val);
                if (std.mem.eql(u8, key, ":protocol")) protocol_len = copyTrunc(&protocol, val);
                if (std.mem.eql(u8, key, ":path")) path_len = copyTrunc(&path, val);
                c.nghttp3_rcbuf_decref(nv.name);
                c.nghttp3_rcbuf_decref(nv.value);
            }
            if (flags & c.NGHTTP3_QPACK_DECODE_FLAG_FINAL != 0) break;
            if (n == 0 and flags == 0) break;
        }
        const m = method[0..method_len];
        const proto = protocol[0..protocol_len];
        log.info("{s}: request {s} {s} protocol={s}", .{ self.name(), m, path[0..path_len], proto });
        if (std.mem.eql(u8, m, "CONNECT") and std.mem.eql(u8, proto, "webtransport")) {
            const sess_name = util.sessionFromPath(path[0..path_len], "") orelse return self.respond(s, 404, true);
            const ws = try self.gpa.create(WtSession);
            ws.* = .{ .conn = self, .session_id = s.id };
            try self.wt.append(self.gpa, ws);
            s.kind = .wt_session;
            self.sessions += 1;
            self.server.stats.sessions_total += 1;
            try self.respond(s, 200, false);
            ws.peer = self.server.hub.opened(ws.link(), sess_name, .webtransport);
            return;
        }
        return self.respond(s, 404, true);
    }

    /// Send a HEADERS frame. QPACK: static-table index for :status, plus one
    /// literal header that draft-02 era browsers look for.
    fn respond(self: *Conn, s: *Stream, status: u16, fin: bool) !void {
        const gpa = self.gpa;
        var block: std.ArrayList(u8) = .empty;
        defer block.deinit(gpa);
        try block.appendSlice(gpa, &.{ 0, 0 }); // Required Insert Count, Delta Base
        const idx: u64 = switch (status) {
            200 => 25,
            404 => 27,
            else => 67, // 400
        };
        try util.putPrefixInt(gpa, &block, 0xc0, 6, idx); // indexed field line, static
        if (status == 200) {
            const hname = "sec-webtransport-http3-draft";
            const hval = "draft02";
            try util.putPrefixInt(gpa, &block, 0x20, 3, hname.len); // literal with literal name
            try block.appendSlice(gpa, hname);
            try util.putPrefixInt(gpa, &block, 0x00, 7, hval.len);
            try block.appendSlice(gpa, hval);
        }
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(gpa);
        try util.putVarint(gpa, &frame, H3_FRAME_HEADERS);
        try util.putVarint(gpa, &frame, block.items.len);
        try frame.appendSlice(gpa, block.items);
        try s.queue(gpa, frame.items);
        if (fin) s.fin_pending = true;
    }

    // ---- ngtcp2 callbacks -------------------------------------------------

    fn fromUd(ud: ?*anyopaque) *Conn {
        return @ptrCast(@alignCast(ud.?));
    }

    fn getConn(ref: [*c]c.ngtcp2_crypto_conn_ref) callconv(.c) ?*c.ngtcp2_conn {
        return fromUd(ref.*.user_data).conn;
    }

    fn logPrintf(_: ?*anyopaque, fmt: [*c]const u8, ...) callconv(.c) void {
        _ = fmt;
    }

    fn cbHandshakeCompleted(_: ?*c.ngtcp2_conn, ud: ?*anyopaque) callconv(.c) c_int {
        const self = fromUd(ud);
        log.info("{s}: handshake completed", .{self.name()});
        self.openControlStream() catch return c.NGTCP2_ERR_CALLBACK_FAILURE;
        return 0;
    }

    fn cbRecvStreamData(conn: ?*c.ngtcp2_conn, flags: u32, id: i64, _: u64, data: [*c]const u8, len: usize, ud: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const self = fromUd(ud);
        const fin = flags & c.NGTCP2_STREAM_DATA_FLAG_FIN != 0;
        const slice: []const u8 = if (len == 0) &.{} else data[0..len];
        self.onStreamData(id, slice, fin) catch return c.NGTCP2_ERR_CALLBACK_FAILURE;
        _ = c.ngtcp2_conn_extend_max_stream_offset(conn, id, len);
        c.ngtcp2_conn_extend_max_offset(conn, len);
        return 0;
    }

    fn cbAckedStreamDataOffset(_: ?*c.ngtcp2_conn, id: i64, offset: u64, len: u64, ud: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const self = fromUd(ud);
        if (self.streams.get(id)) |s| s.ack(self.gpa, offset + len);
        return 0;
    }

    fn cbStreamClose(conn: ?*c.ngtcp2_conn, _: u32, id: i64, _: u64, _: u64, ud: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const self = fromUd(ud);
        for (self.wt.items) |ws| if (ws.stream_id == id or ws.session_id == id) self.endSession(ws);
        if (self.streams.fetchRemove(id)) |kv| {
            kv.value.deinit(self.gpa);
            self.gpa.destroy(kv.value);
        }
        if (id & 1 == 0) { // client-initiated: give the credit back
            if (id & 2 == 0) c.ngtcp2_conn_extend_max_streams_bidi(conn, 1) else c.ngtcp2_conn_extend_max_streams_uni(conn, 1);
        }
        return 0;
    }

    fn cbStreamReset(_: ?*c.ngtcp2_conn, _: i64, _: u64, _: u64, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        return 0;
    }

    fn cbRecvDatagram(_: ?*c.ngtcp2_conn, _: u32, data: [*c]const u8, len: usize, ud: ?*anyopaque) callconv(.c) c_int {
        const self = fromUd(ud);
        self.server.stats.dgrams_rx += 1;
        const d = data[0..len];
        // HTTP Datagram: quarter stream ID of the session, then payload.
        const q = util.readVarint(d) orelse return 0;
        const ws = self.findSession(@intCast(q.value * 4)) orelse return 0;
        if (ws.ended or ws.close_requested) return 0;
        self.server.hub.datagram(ws.peer, d[q.len..]);
        return 0;
    }

    fn cbRand(dest: [*c]u8, len: usize, _: [*c]const c.ngtcp2_rand_ctx) callconv(.c) void {
        util.randomBytes(dest[0..len]);
    }

    fn cbGetNewConnectionId(_: ?*c.ngtcp2_conn, cid: [*c]c.ngtcp2_cid, token: [*c]c.ngtcp2_stateless_reset_token, cidlen: usize, ud: ?*anyopaque) callconv(.c) c_int {
        const self = fromUd(ud);
        cid.*.datalen = cidlen;
        util.randomBytes(cid.*.data[0..cidlen]);
        if (c.ngtcp2_crypto_generate_stateless_reset_token(&token.*.data, &self.server.static_secret, self.server.static_secret.len, cid) != 0)
            return c.NGTCP2_ERR_CALLBACK_FAILURE;
        self.server.conns.put(self.gpa, CidKey.fromCid(cid), self) catch return c.NGTCP2_ERR_CALLBACK_FAILURE;
        return 0;
    }

    fn cbRemoveConnectionId(_: ?*c.ngtcp2_conn, cid: [*c]const c.ngtcp2_cid, ud: ?*anyopaque) callconv(.c) c_int {
        const self = fromUd(ud);
        _ = self.server.conns.remove(CidKey.fromCid(cid));
        return 0;
    }
};

fn copyTrunc(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}
