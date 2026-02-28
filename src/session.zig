const std = @import("std");
const c = @cImport({
    @cDefine("RTC_STATIC", {});
    @cInclude("rtc/rtc.h");
});

const log = std.log.scoped(.session);

pub const MAX_PEERS: usize = 8;
pub const PEER_ID_LEN: usize = 16;

// ── Peer ─────────────────────────────────────────────────────────────────

pub const PeerState = enum(u8) {
    empty,
    connecting,
    connected,
    closing,
};

/// A single viewer's WebRTC peer connection.
/// Lives in a fixed-size array inside BroadcastSession. MUST be at a stable
/// memory address before start() is called (two-phase init).
pub const Peer = struct {
    pc: c_int,
    track: c_int,
    peer_id: [PEER_ID_LEN]u8,
    state: std.atomic.Value(PeerState),
    force_keyframe: std.atomic.Value(bool),
    session: *BroadcastSession,

    /// Initialize this peer slot in-place. Creates PC + AV1 track handles.
    /// Does NOT register callbacks — call start() after this returns.
    pub fn initInPlace(
        self: *Peer,
        session: *BroadcastSession,
        peer_id: [PEER_ID_LEN]u8,
    ) !void {
        const pc = c.rtcCreatePeerConnection(&session.pc_config);
        if (pc < 0) return error.PeerConnectionFailed;
        errdefer _ = c.rtcDeletePeerConnection(pc);

        // Add sendonly AV1 track
        var track_init = std.mem.zeroes(c.rtcTrackInit);
        track_init.direction = c.RTC_DIRECTION_SENDONLY;
        track_init.codec = c.RTC_CODEC_AV1;
        track_init.payloadType = 96;
        track_init.ssrc = 1;
        track_init.mid = "0";
        track_init.name = "video";
        track_init.msid = "zerocast";
        track_init.trackId = "video";

        const track = c.rtcAddTrackEx(pc, &track_init);
        if (track < 0) return error.AddTrackFailed;
        errdefer _ = c.rtcDeleteTrack(track);

        // AV1 packetizer
        var pkt_init = std.mem.zeroes(c.rtcPacketizerInit);
        pkt_init.ssrc = 1;
        pkt_init.cname = "zerocast";
        pkt_init.payloadType = 96;
        pkt_init.clockRate = 90000;
        pkt_init.maxFragmentSize = 1200;
        pkt_init.obuPacketization = c.RTC_OBU_PACKETIZED_TEMPORAL_UNIT;

        if (c.rtcSetAV1Packetizer(track, &pkt_init) < 0) return error.PacketizerFailed;

        // RTCP chain
        if (c.rtcChainRtcpSrReporter(track) < 0) return error.RtcpChainFailed;
        if (c.rtcChainRtcpNackResponder(track, 512) < 0) return error.RtcpChainFailed;

        self.* = .{
            .pc = pc,
            .track = track,
            .peer_id = peer_id,
            .state = std.atomic.Value(PeerState).init(.connecting),
            .force_keyframe = std.atomic.Value(bool).init(false),
            .session = session,
        };
    }

    /// Register callbacks. MUST be called after initInPlace, once the Peer is
    /// at its final memory location.
    pub fn start(self: *Peer) void {
        c.rtcSetUserPointer(self.pc, @ptrCast(self));
        _ = c.rtcSetLocalDescriptionCallback(self.pc, localDescriptionCallback);
        _ = c.rtcSetLocalCandidateCallback(self.pc, localCandidateCallback);
        _ = c.rtcSetStateChangeCallback(self.pc, stateChangeCallback);
        _ = c.rtcChainPliHandler(self.track, pliCallback);
    }

    /// Close PC + track handles. Does NOT call rtcCleanup().
    pub fn deinit(self: *Peer) void {
        _ = c.rtcDeleteTrack(self.track);
        _ = c.rtcDeletePeerConnection(self.pc);
        self.pc = -1;
        self.track = -1;
    }

    /// Send one encoded frame on this peer's track.
    pub fn sendFrame(self: *Peer, data: []const u8, rtp_ts: u32) void {
        _ = c.rtcSetTrackRtpTimestamp(self.track, rtp_ts);
        const result = c.rtcSendMessage(self.track, @ptrCast(data.ptr), @intCast(data.len));
        if (result < 0) {
            log.warn("sendMessage to {s} failed: {d}", .{ self.peer_id, result });
        }
    }

    // ── Callbacks (fire on libdatachannel internal threads) ──────────

    fn stateChangeCallback(_: c_int, raw_state: c.rtcState, ptr: ?*anyopaque) callconv(.c) void {
        const self = ptrToPeer(ptr) orelse return;

        // If slot is already closing or empty (freed by viewer-left), skip.
        const current = self.state.load(.acquire);
        if (current == .empty or current == .closing) return;

        const state: PeerState = switch (raw_state) {
            c.RTC_CONNECTING => .connecting,
            c.RTC_CONNECTED => .connected,
            c.RTC_DISCONNECTED, c.RTC_FAILED, c.RTC_CLOSED => .closing,
            else => return,
        };
        log.info("peer {s}: {s}", .{ self.peer_id, @tagName(state) });
        self.state.store(state, .release);

        // Auto-cleanup on terminal states.
        // Capture peer_id by value — the slot may be reused by allocPeer
        // after freePeerById releases the mutex.
        if (state == .closing) {
            const peer_id = self.peer_id;
            self.session.freePeerById(&peer_id);
        }
    }

    fn pliCallback(_: c_int, ptr: ?*anyopaque) callconv(.c) void {
        const self = ptrToPeer(ptr) orelse return;
        self.force_keyframe.store(true, .release);
    }

    fn localDescriptionCallback(_: c_int, sdp: [*c]const u8, desc_type: [*c]const u8, ptr: ?*anyopaque) callconv(.c) void {
        const self = ptrToPeer(ptr) orelse return;
        const sdp_slice = std.mem.span(sdp);
        const type_slice = std.mem.span(desc_type);

        // Format: {"type":"<type>","to":"<peer_id>","sdp":"<sdp>"}
        var buf: [9216]u8 = undefined;
        const msg = jsonRoutedSdp(&buf, type_slice, &self.peer_id, sdp_slice) catch return;
        buf[msg.len] = 0;
        _ = c.rtcSendMessage(self.session.ws, &buf, -1);
    }

    fn localCandidateCallback(_: c_int, cand: [*c]const u8, mid: [*c]const u8, ptr: ?*anyopaque) callconv(.c) void {
        const self = ptrToPeer(ptr) orelse return;
        const cand_slice = std.mem.span(cand);
        const mid_slice = std.mem.span(mid);

        // Format: {"type":"ice","to":"<peer_id>","candidate":"<cand>","mid":"<mid>"}
        var buf: [2048]u8 = undefined;
        const msg = jsonRoutedIce(&buf, &self.peer_id, cand_slice, mid_slice) catch return;
        buf[msg.len] = 0;
        _ = c.rtcSendMessage(self.session.ws, &buf, -1);
    }

    fn ptrToPeer(ptr: ?*anyopaque) ?*Peer {
        return @alignCast(@ptrCast(ptr));
    }
};

// ── BroadcastSession ─────────────────────────────────────────────────────

pub const BroadcastSession = struct {
    ws: c_int,
    peers: [MAX_PEERS]Peer,
    peers_mutex: std.Thread.Mutex,
    pc_config: c.rtcConfiguration,
    ice_servers: [2][*c]const u8,
    turn_uri: [256]u8,

    /// Create signaling WebSocket and initialize empty peer array.
    pub fn init(signaling_url: []const u8, room_id: []const u8) !BroadcastSession {
        c.rtcInitLogger(c.RTC_LOG_WARNING, null);

        // Build WS URL
        var url_buf: [512]u8 = undefined;
        const ws_url = std.fmt.bufPrint(&url_buf, "{s}/room/{s}/ws?role=sharer", .{
            signaling_url, room_id,
        }) catch return error.UrlTooLong;

        var url_z: [513]u8 = undefined;
        @memcpy(url_z[0..ws_url.len], ws_url);
        url_z[ws_url.len] = 0;

        const ws = c.rtcCreateWebSocket(&url_z);
        if (ws < 0) return error.WebSocketFailed;

        var session: BroadcastSession = undefined;
        session.ws = ws;
        session.peers_mutex = .{};
        session.ice_servers = .{ "stun:stun.cloudflare.com:3478", undefined };
        session.turn_uri = std.mem.zeroes([256]u8);
        session.pc_config = std.mem.zeroes(c.rtcConfiguration);
        session.pc_config.iceServers = &session.ice_servers;
        session.pc_config.iceServersCount = 1;

        // Initialize all peer slots as empty
        for (&session.peers) |*peer| {
            peer.state = std.atomic.Value(PeerState).init(.empty);
            peer.pc = -1;
            peer.track = -1;
        }

        return session;
    }

    /// Register signaling WebSocket callbacks. MUST be called after init,
    /// once the session is at its final memory location.
    pub fn start(self: *BroadcastSession) void {
        // Fix up pc_config pointer — it was copied during init return
        self.pc_config.iceServers = &self.ice_servers;

        c.rtcSetUserPointer(self.ws, @ptrCast(self));
        _ = c.rtcSetMessageCallback(self.ws, wsMessageCallback);
        _ = c.rtcSetOpenCallback(self.ws, wsOpenCallback);
    }

    /// Send one encoded AV1 frame to all connected peers.
    /// Called from the main thread within the NVENC bitstream lock window.
    /// Holds peers_mutex to prevent deinit from invalidating track handles
    /// mid-send. The critical section is short — rtcSendMessage just enqueues.
    pub fn sendFrame(self: *BroadcastSession, data: []const u8, pts_ms: u64) void {
        const rtp_ts: u32 = @truncate(pts_ms * 90);
        self.peers_mutex.lock();
        defer self.peers_mutex.unlock();
        for (&self.peers) |*peer| {
            if (peer.state.load(.acquire) == .connected) {
                peer.sendFrame(data, rtp_ts);
            }
        }
    }

    /// Check and clear force-keyframe flags across all connected peers.
    pub fn shouldForceKeyframe(self: *BroadcastSession) bool {
        var need_key = false;
        for (&self.peers) |*peer| {
            if (peer.state.load(.acquire) == .connected) {
                if (peer.force_keyframe.swap(false, .acq_rel)) {
                    need_key = true;
                }
            }
        }
        return need_key;
    }

    /// Allocate a peer slot. Creates PC + track handles outside the mutex,
    /// then assigns into an empty slot under the mutex. Returns the peer
    /// for start() + offer generation.
    fn allocPeer(self: *BroadcastSession, peer_id: [PEER_ID_LEN]u8) ?*Peer {
        // Create handles outside the lock — rtcCreatePeerConnection may block
        var new_peer: Peer = undefined;
        new_peer.initInPlace(self, peer_id) catch |err| {
            log.warn("allocPeer failed: {}", .{err});
            return null;
        };

        // Find an empty slot under the lock and install
        self.peers_mutex.lock();
        defer self.peers_mutex.unlock();

        for (&self.peers) |*slot| {
            if (slot.state.load(.acquire) == .empty) {
                slot.* = new_peer;
                return slot;
            }
        }

        // No slot available — clean up the handles we just created
        log.warn("peer slots full ({d}), rejecting {s}", .{ MAX_PEERS, peer_id });
        new_peer.deinit();
        return null;
    }

    /// Free a peer slot by ID. Safe to call from any thread.
    /// Closes handles OUTSIDE the mutex to prevent deadlock — rtcDeletePeerConnection
    /// blocks until callbacks complete, and those callbacks may try to acquire peers_mutex.
    pub fn freePeerById(self: *BroadcastSession, peer_id: []const u8) void {
        var pc: c_int = -1;
        var track: c_int = -1;
        var freed: ?*Peer = null;

        {
            self.peers_mutex.lock();
            defer self.peers_mutex.unlock();

            for (&self.peers) |*peer| {
                const s = peer.state.load(.acquire);
                if (s == .empty or s == .closing) continue;
                if (std.mem.eql(u8, &peer.peer_id, peer_id[0..PEER_ID_LEN])) {
                    log.info("freeing peer {s}", .{peer.peer_id});
                    // Mark as closing so sendFrame/allocPeer/stateChangeCallback skip it
                    peer.state.store(.closing, .release);
                    pc = peer.pc;
                    track = peer.track;
                    peer.pc = -1;
                    peer.track = -1;
                    freed = peer;
                    break;
                }
            }
        }

        // Close handles outside the mutex — rtcDeletePeerConnection blocks
        // until all scheduled callbacks for this PC complete
        if (track >= 0) _ = c.rtcDeleteTrack(track);
        if (pc >= 0) _ = c.rtcDeletePeerConnection(pc);

        // Now safe to mark as empty — all callbacks for this PC have quiesced
        if (freed) |peer| peer.state.store(.empty, .release);
    }

    /// Find a peer by ID. Caller MUST hold peers_mutex.
    fn findPeerLocked(self: *BroadcastSession, peer_id: []const u8) ?*Peer {
        if (peer_id.len < PEER_ID_LEN) return null;
        for (&self.peers) |*peer| {
            const s = peer.state.load(.acquire);
            if (s == .empty) continue;
            if (std.mem.eql(u8, &peer.peer_id, peer_id[0..PEER_ID_LEN])) {
                return peer;
            }
        }
        return null;
    }

    pub fn deinit(self: *BroadcastSession) void {
        // Close signaling WebSocket first — blocks until wsMessageCallback exits,
        // preventing new allocPeer/freePeer calls.
        if (self.ws >= 0) _ = c.rtcDeleteWebSocket(self.ws);

        // Collect handles under mutex, mark slots closing
        var pcs: [MAX_PEERS]c_int = .{-1} ** MAX_PEERS;
        var tracks: [MAX_PEERS]c_int = .{-1} ** MAX_PEERS;
        {
            self.peers_mutex.lock();
            defer self.peers_mutex.unlock();
            for (&self.peers, 0..) |*peer, i| {
                if (peer.state.load(.acquire) != .empty) {
                    peer.state.store(.closing, .release);
                    pcs[i] = peer.pc;
                    tracks[i] = peer.track;
                    peer.pc = -1;
                    peer.track = -1;
                }
            }
        }

        // Close handles outside mutex — rtcDeletePeerConnection blocks until
        // callbacks complete, and callbacks may try to acquire peers_mutex
        for (0..MAX_PEERS) |i| {
            if (tracks[i] >= 0) _ = c.rtcDeleteTrack(tracks[i]);
            if (pcs[i] >= 0) _ = c.rtcDeletePeerConnection(pcs[i]);
        }

        for (&self.peers) |*peer| {
            peer.state.store(.empty, .release);
        }

        c.rtcCleanup();
    }

    // ── Signaling WebSocket callbacks ────────────────────────────────

    fn wsOpenCallback(_: c_int, _: ?*anyopaque) callconv(.c) void {
        log.info("signaling WebSocket connected", .{});
    }

    fn wsMessageCallback(_: c_int, raw_msg: [*c]const u8, size: c_int, ptr: ?*anyopaque) callconv(.c) void {
        const self: *BroadcastSession = @alignCast(@ptrCast(ptr orelse return));

        // Text messages have negative size in libdatachannel C API
        if (size >= 0) return;
        const len: usize = @intCast(-(size + 1));
        const msg: []const u8 = raw_msg[0..len];

        const msg_type = jsonExtract(msg, "type") orelse return;

        if (std.mem.eql(u8, msg_type, "turn-credentials")) {
            const username = jsonExtract(msg, "username") orelse return;
            const credential = jsonExtract(msg, "credential") orelse return;

            // Format: turn:username:credential@turn.cloudflare.com:3478
            const uri = std.fmt.bufPrintZ(&self.turn_uri, "turn:{s}:{s}@turn.cloudflare.com:3478", .{
                username, credential,
            }) catch return;
            self.ice_servers[1] = uri.ptr;
            self.pc_config.iceServersCount = 2;
            log.info("TURN credentials configured", .{});
            return;
        }

        if (std.mem.eql(u8, msg_type, "viewer-joined")) {
            const peer_id_str = jsonExtract(msg, "peer_id") orelse return;
            if (peer_id_str.len < PEER_ID_LEN) return;
            var peer_id: [PEER_ID_LEN]u8 = undefined;
            @memcpy(&peer_id, peer_id_str[0..PEER_ID_LEN]);

            log.info("viewer joined: {s}", .{peer_id});

            const peer = self.allocPeer(peer_id);
            if (peer) |p| {
                p.start();
                _ = c.rtcSetLocalDescription(p.pc, "offer");
            }
        } else if (std.mem.eql(u8, msg_type, "viewer-left")) {
            const peer_id_str = jsonExtract(msg, "peer_id") orelse return;
            log.info("viewer left: {s}", .{peer_id_str});
            self.freePeerById(peer_id_str);
        } else if (std.mem.eql(u8, msg_type, "answer")) {
            const peer_id_str = jsonExtract(msg, "from") orelse return;
            const sdp_escaped = jsonExtract(msg, "sdp") orelse return;

            var sdp_z: [8192]u8 = undefined;
            const sdp_len = jsonUnescape(sdp_escaped, &sdp_z) orelse return;
            sdp_z[sdp_len] = 0;

            self.peers_mutex.lock();
            defer self.peers_mutex.unlock();

            if (self.findPeerLocked(peer_id_str)) |peer| {
                const result = c.rtcSetRemoteDescription(peer.pc, &sdp_z, "answer");
                if (result < 0) log.warn("setRemoteDescription failed: {d}", .{result});
            }
        } else if (std.mem.eql(u8, msg_type, "ice")) {
            const peer_id_str = jsonExtract(msg, "from") orelse return;
            const cand_escaped = jsonExtract(msg, "candidate") orelse return;
            const mid = jsonExtract(msg, "mid") orelse "0";

            var cand_z: [2048]u8 = undefined;
            const cand_len = jsonUnescape(cand_escaped, &cand_z) orelse return;
            cand_z[cand_len] = 0;

            var mid_z: [64]u8 = undefined;
            if (mid.len >= mid_z.len) return;
            @memcpy(mid_z[0..mid.len], mid);
            mid_z[mid.len] = 0;

            self.peers_mutex.lock();
            defer self.peers_mutex.unlock();

            if (self.findPeerLocked(peer_id_str)) |peer| {
                _ = c.rtcAddRemoteCandidate(peer.pc, &cand_z, &mid_z);
            }
        }
    }
};

// ── JSON helpers (fixed-format, stack buffers, no allocations) ────────────

/// Build {"type":"<type>","to":"<peer_id>","sdp":"<sdp>"}
fn jsonRoutedSdp(buf: []u8, msg_type: []const u8, peer_id: []const u8, sdp: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"type\":\"");
    try w.writeAll(msg_type);
    try w.writeAll("\",\"to\":\"");
    try w.writeAll(peer_id);
    try w.writeAll("\",\"sdp\":\"");
    try writeJsonEscaped(w, sdp);
    try w.writeAll("\"}");
    return fbs.getWritten();
}

/// Build {"type":"ice","to":"<peer_id>","candidate":"<cand>","mid":"<mid>"}
fn jsonRoutedIce(buf: []u8, peer_id: []const u8, candidate: []const u8, mid: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"type\":\"ice\",\"to\":\"");
    try w.writeAll(peer_id);
    try w.writeAll("\",\"candidate\":\"");
    try writeJsonEscaped(w, candidate);
    try w.writeAll("\",\"mid\":\"");
    try writeJsonEscaped(w, mid);
    try w.writeAll("\"}");
    return fbs.getWritten();
}

/// Extract a JSON string value for a given key. Minimal scanner for
/// fixed-format messages like {"type":"answer","from":"abc","sdp":"v=0\r\n..."}.
pub fn jsonExtract(json: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + key.len + 4 < json.len) : (i += 1) {
        if (json[i] == '"' and
            i + 1 + key.len + 3 <= json.len and
            std.mem.eql(u8, json[i + 1 .. i + 1 + key.len], key) and
            json[i + 1 + key.len] == '"' and
            json[i + 1 + key.len + 1] == ':' and
            json[i + 1 + key.len + 2] == '"')
        {
            const val_start = i + 1 + key.len + 3;
            var j = val_start;
            while (j < json.len) : (j += 1) {
                if (json[j] == '\\') {
                    j += 1;
                    continue;
                }
                if (json[j] == '"') {
                    return json[val_start..j];
                }
            }
        }
    }
    return null;
}

/// Unescape a JSON string value: \n → LF, \r → CR, \\ → \, \" → ", \t → TAB.
fn jsonUnescape(src: []const u8, dst: []u8) ?usize {
    var di: usize = 0;
    var si: usize = 0;
    while (si < src.len) : (si += 1) {
        if (di >= dst.len) return null;
        if (src[si] == '\\' and si + 1 < src.len) {
            si += 1;
            dst[di] = switch (src[si]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                else => src[si],
            };
        } else {
            dst[di] = src[si];
        }
        di += 1;
    }
    return di;
}

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(ch),
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────────

test "jsonExtract basic" {
    const json = "{\"type\":\"answer\",\"sdp\":\"v=0\\r\\n\"}";
    try std.testing.expectEqualSlices(u8, "answer", jsonExtract(json, "type").?);
    try std.testing.expectEqualSlices(u8, "v=0\\r\\n", jsonExtract(json, "sdp").?);
    try std.testing.expect(jsonExtract(json, "missing") == null);
}

test "jsonExtract with from field" {
    const json = "{\"type\":\"answer\",\"from\":\"a3f9c12d4e5b6708\",\"sdp\":\"v=0\\r\\n\"}";
    try std.testing.expectEqualSlices(u8, "answer", jsonExtract(json, "type").?);
    try std.testing.expectEqualSlices(u8, "a3f9c12d4e5b6708", jsonExtract(json, "from").?);
    try std.testing.expectEqualSlices(u8, "v=0\\r\\n", jsonExtract(json, "sdp").?);
}

test "jsonExtract viewer-joined" {
    const json = "{\"type\":\"viewer-joined\",\"peer_id\":\"a3f9c12d4e5b6708\"}";
    try std.testing.expectEqualSlices(u8, "viewer-joined", jsonExtract(json, "type").?);
    try std.testing.expectEqualSlices(u8, "a3f9c12d4e5b6708", jsonExtract(json, "peer_id").?);
}

test "jsonRoutedSdp roundtrip" {
    var buf: [9216]u8 = undefined;
    const msg = try jsonRoutedSdp(&buf, "offer", "a3f9c12d4e5b6708", "v=0\r\ntest");
    try std.testing.expectEqualSlices(u8, "offer", jsonExtract(msg, "type").?);
    try std.testing.expectEqualSlices(u8, "a3f9c12d4e5b6708", jsonExtract(msg, "to").?);
    const sdp = jsonExtract(msg, "sdp").?;
    try std.testing.expect(std.mem.indexOf(u8, sdp, "v=0") != null);
}

test "jsonRoutedIce roundtrip" {
    var buf: [2048]u8 = undefined;
    const msg = try jsonRoutedIce(&buf, "a3f9c12d4e5b6708", "candidate:1 1 UDP 2130706431", "0");
    try std.testing.expectEqualSlices(u8, "ice", jsonExtract(msg, "type").?);
    try std.testing.expectEqualSlices(u8, "a3f9c12d4e5b6708", jsonExtract(msg, "to").?);
    try std.testing.expectEqualSlices(u8, "0", jsonExtract(msg, "mid").?);
}
