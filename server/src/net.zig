//! The seam between transports and sessions.
//!
//! Both transports (WebTransport in quic.zig, WebSocket in tcp.zig) carry the
//! same two I3 channels. A transport turns its connection into a `Link` and
//! reports what arrives to the `Hub`; the hub (the session manager) never
//! sees QUIC or WebSocket framing.
//!
//! Peers are named by a numeric id, not a pointer, so either side can drop a
//! connection without leaving the other holding a dangling reference.

const std = @import("std");

pub const PeerId = u64;

pub const TransportKind = enum(u8) { webtransport = 0, websocket = 1, webrtc = 2 };

/// What a session can do to a connection. Bodies are whole I3 messages
/// (starting with the type byte); the transport adds its own framing.
pub const Link = struct {
    ptr: *anyopaque,
    vt: *const VTable,

    pub const VTable = struct {
        /// Unreliable. May be dropped by the transport.
        sendDatagram: *const fn (*anyopaque, []const u8) void,
        /// Reliable, ordered.
        sendStream: *const fn (*anyopaque, []const u8) void,
        /// Flush what is queued, then close. The transport will still call
        /// `Hub.closed` afterwards; the hub must ignore an unknown id.
        close: *const fn (*anyopaque) void,
        /// Largest I3 datagram payload this link can carry right now.
        maxDatagram: *const fn (*anyopaque) usize,
    };

    pub fn sendDatagram(l: Link, b: []const u8) void {
        l.vt.sendDatagram(l.ptr, b);
    }
    pub fn sendStream(l: Link, b: []const u8) void {
        l.vt.sendStream(l.ptr, b);
    }
    pub fn close(l: Link) void {
        l.vt.close(l.ptr);
    }
    pub fn maxDatagram(l: Link) usize {
        return l.vt.maxDatagram(l.ptr);
    }
};

/// What a transport reports. Implemented by `manager.Manager`.
pub const Hub = struct {
    ptr: *anyopaque,
    vt: *const VTable,

    pub const VTable = struct {
        /// A connection for `/s/<session>` is open. Returns its peer id.
        /// The session itself is resolved when `hello` arrives.
        opened: *const fn (*anyopaque, Link, []const u8, TransportKind) PeerId,
        stream: *const fn (*anyopaque, PeerId, []const u8) void,
        datagram: *const fn (*anyopaque, PeerId, []const u8) void,
        closed: *const fn (*anyopaque, PeerId) void,
    };

    pub fn opened(h: Hub, l: Link, session: []const u8, t: TransportKind) PeerId {
        return h.vt.opened(h.ptr, l, session, t);
    }
    pub fn stream(h: Hub, p: PeerId, b: []const u8) void {
        h.vt.stream(h.ptr, p, b);
    }
    pub fn datagram(h: Hub, p: PeerId, b: []const u8) void {
        h.vt.datagram(h.ptr, p, b);
    }
    pub fn closed(h: Hub, p: PeerId) void {
        h.vt.closed(h.ptr, p);
    }
};
