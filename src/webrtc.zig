const std = @import("std");
const c = @cImport({
    @cDefine("RTC_STATIC", {});
    @cInclude("rtc/rtc.h");
});

const log = std.log.scoped(.webrtc);

pub const State = enum(u8) {
    new,
    connecting,
    connected,
    disconnected,
    failed,
    closed,
};

pub const WebRtc = struct {
    pc: c_int, // peer connection ID
    track: c_int, // AV1 track ID
    ws: c_int, // signaling WebSocket ID
    state: std.atomic.Value(State),
    force_keyframe: std.atomic.Value(bool),
    allocator: std.mem.Allocator,

    /// Create peer connection, add AV1 track with packetizer, open signaling WebSocket.
    pub fn init(allocator: std.mem.Allocator, signaling_url: []const u8, room_id: []const u8) !WebRtc {
        // Configure logging
        c.rtcInitLogger(c.RTC_LOG_WARNING, null);

        // Create peer connection with STUN
        const stun_server: [*c]const u8 = "stun:stun.cloudflare.com:3478";
        var stun_servers = [_][*c]const u8{stun_server};
        var config = std.mem.zeroes(c.rtcConfiguration);
        config.iceServers = &stun_servers;
        config.iceServersCount = 1;

        const pc = c.rtcCreatePeerConnection(&config);
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
        track_init.msid = "barecast";
        track_init.trackId = "video";

        const track = c.rtcAddTrackEx(pc, &track_init);
        if (track < 0) return error.AddTrackFailed;
        errdefer _ = c.rtcDeleteTrack(track);

        // Set AV1 packetizer
        var pkt_init = std.mem.zeroes(c.rtcPacketizerInit);
        pkt_init.ssrc = 1;
        pkt_init.cname = "barecast";
        pkt_init.payloadType = 96;
        pkt_init.clockRate = 90000;
        pkt_init.maxFragmentSize = 1200;
        pkt_init.obuPacketization = c.RTC_OBU_PACKETIZED_TEMPORAL_UNIT;

        if (c.rtcSetAV1Packetizer(track, &pkt_init) < 0) return error.PacketizerFailed;

        // Chain RTCP handlers for PLI/NACK/SR
        if (c.rtcChainRtcpSrReporter(track) < 0) return error.RtcpChainFailed;
        if (c.rtcChainRtcpNackResponder(track, 512) < 0) return error.RtcpChainFailed;

        // Build signaling WebSocket URL: {signaling_url}/room/{room_id}/ws?role=sharer
        var url_buf: [512]u8 = undefined;
        const ws_url = std.fmt.bufPrint(&url_buf, "{s}/room/{s}/ws?role=sharer", .{ signaling_url, room_id }) catch return error.UrlTooLong;

        // Null-terminate for C
        var url_z: [513]u8 = undefined;
        @memcpy(url_z[0..ws_url.len], ws_url);
        url_z[ws_url.len] = 0;

        const ws = c.rtcCreateWebSocket(&url_z);
        if (ws < 0) return error.WebSocketFailed;

        return WebRtc{
            .pc = pc,
            .track = track,
            .ws = ws,
            .state = std.atomic.Value(State).init(.new),
            .force_keyframe = std.atomic.Value(bool).init(false),
            .allocator = allocator,
        };
    }

    /// Register callbacks with user pointers to `self`. MUST be called after init,
    /// once the struct is at its final memory location (Zig copies on return from init,
    /// so pointers taken inside init() would dangle).
    pub fn start(self: *WebRtc) void {
        c.rtcSetUserPointer(self.pc, @ptrCast(self));
        _ = c.rtcSetLocalDescriptionCallback(self.pc, localDescriptionCallback);
        _ = c.rtcSetLocalCandidateCallback(self.pc, localCandidateCallback);
        _ = c.rtcSetStateChangeCallback(self.pc, stateChangeCallback);
        _ = c.rtcChainPliHandler(self.track, pliCallback);

        c.rtcSetUserPointer(self.ws, @ptrCast(self));
        _ = c.rtcSetMessageCallback(self.ws, wsMessageCallback);
        _ = c.rtcSetOpenCallback(self.ws, wsOpenCallback);
    }

    /// Send one encoded AV1 frame over the WebRTC track.
    /// Called from the main thread within the NVENC bitstream lock window.
    pub fn sendFrame(self: *WebRtc, data: []const u8, timestamp_ms: u64) !void {
        if (self.state.load(.acquire) != .connected) return;

        // Set RTP timestamp (90kHz clock)
        const rtp_ts: u32 = @intCast(timestamp_ms * 90);
        _ = c.rtcSetTrackRtpTimestamp(self.track, rtp_ts);

        const result = c.rtcSendMessage(self.track, @ptrCast(data.ptr), @intCast(data.len));
        if (result < 0) {
            log.warn("sendMessage failed: {d}", .{result});
        }
    }

    /// Check and clear the force-keyframe flag (set by PLI callback).
    pub fn shouldForceKeyframe(self: *WebRtc) bool {
        return self.force_keyframe.swap(false, .acquire);
    }

    /// Block until the peer connection reaches connected or fails.
    /// Accepts an optional exit flag (e.g. from signal handler) to allow clean shutdown.
    pub fn waitForConnection(self: *WebRtc, timeout_ms: u64, exit_flag: ?*std.atomic.Value(bool)) !void {
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (std.time.milliTimestamp() < deadline) {
            if (exit_flag) |flag| {
                if (flag.load(.acquire)) return error.ConnectionFailed;
            }
            const s = self.state.load(.acquire);
            switch (s) {
                .connected => return,
                .failed, .closed => return error.ConnectionFailed,
                else => std.Thread.sleep(50 * std.time.ns_per_ms),
            }
        }
        return error.ConnectionTimeout;
    }

    pub fn deinit(self: *WebRtc) void {
        if (self.ws >= 0) _ = c.rtcDeleteWebSocket(self.ws);
        _ = c.rtcDeleteTrack(self.track);
        _ = c.rtcDeletePeerConnection(self.pc);
        c.rtcCleanup();
    }

    // ── Callbacks (fire on libdatachannel internal threads) ──────────────

    fn localDescriptionCallback(_: c_int, sdp: [*c]const u8, desc_type: [*c]const u8, ptr: ?*anyopaque) callconv(.c) void {
        const self = ptrToSelf(ptr) orelse return;
        const sdp_slice = std.mem.span(sdp);
        const type_slice = std.mem.span(desc_type);

        // Format: {"type":"offer","sdp":"..."}
        var buf: [8192]u8 = undefined;
        const msg = jsonOfferOrAnswer(&buf, type_slice, sdp_slice) catch return;
        buf[msg.len] = 0; // null-terminate for C
        _ = c.rtcSendMessage(self.ws, &buf, -1); // negative size = text message
    }

    fn localCandidateCallback(_: c_int, cand: [*c]const u8, mid: [*c]const u8, ptr: ?*anyopaque) callconv(.c) void {
        const self = ptrToSelf(ptr) orelse return;
        const cand_slice = std.mem.span(cand);
        const mid_slice = std.mem.span(mid);

        var buf: [2048]u8 = undefined;
        const msg = jsonIce(&buf, cand_slice, mid_slice) catch return;
        buf[msg.len] = 0;
        _ = c.rtcSendMessage(self.ws, &buf, -1);
    }

    fn stateChangeCallback(_: c_int, raw_state: c.rtcState, ptr: ?*anyopaque) callconv(.c) void {
        const self = ptrToSelf(ptr) orelse return;
        const state: State = switch (raw_state) {
            c.RTC_NEW => .new,
            c.RTC_CONNECTING => .connecting,
            c.RTC_CONNECTED => .connected,
            c.RTC_DISCONNECTED => .disconnected,
            c.RTC_FAILED => .failed,
            c.RTC_CLOSED => .closed,
            else => .failed,
        };
        log.info("state: {s}", .{@tagName(state)});
        self.state.store(state, .release);
    }

    fn pliCallback(_: c_int, ptr: ?*anyopaque) callconv(.c) void {
        const self = ptrToSelf(ptr) orelse return;
        self.force_keyframe.store(true, .release);
    }

    fn wsOpenCallback(_: c_int, ptr: ?*anyopaque) callconv(.c) void {
        _ = ptr;
        log.info("signaling WebSocket connected", .{});
    }

    fn wsMessageCallback(_: c_int, raw_msg: [*c]const u8, size: c_int, ptr: ?*anyopaque) callconv(.c) void {
        const self = ptrToSelf(ptr) orelse return;
        // libdatachannel C API: text messages have negative size (-len-1), binary have positive.
        // We only handle text (JSON signaling messages).
        if (size >= 0) return; // binary message, ignore
        const len: usize = @intCast(-(size + 1));
        const msg: []const u8 = raw_msg[0..len];

        // Parse message type
        const msg_type = jsonExtract(msg, "type") orelse return;

        if (std.mem.eql(u8, msg_type, "answer")) {
            const sdp_escaped = jsonExtract(msg, "sdp") orelse return;
            var sdp_z: [8192]u8 = undefined;
            const sdp_len = jsonUnescape(sdp_escaped, &sdp_z) orelse return;
            sdp_z[sdp_len] = 0;
            const result = c.rtcSetRemoteDescription(self.pc, &sdp_z, "answer");
            if (result < 0) log.warn("setRemoteDescription failed: {d}", .{result});
        } else if (std.mem.eql(u8, msg_type, "ice")) {
            const cand_escaped = jsonExtract(msg, "candidate") orelse return;
            const mid = jsonExtract(msg, "mid") orelse "0";
            var cand_z: [2048]u8 = undefined;
            const cand_len = jsonUnescape(cand_escaped, &cand_z) orelse return;
            cand_z[cand_len] = 0;
            var mid_z: [64]u8 = undefined;
            if (mid.len >= mid_z.len) return;
            @memcpy(mid_z[0..mid.len], mid);
            mid_z[mid.len] = 0;
            _ = c.rtcAddRemoteCandidate(self.pc, &cand_z, &mid_z);
        } else if (std.mem.eql(u8, msg_type, "peer-joined")) {
            // Viewer connected — trigger offer generation
            log.info("peer joined, generating offer", .{});
            _ = c.rtcSetLocalDescription(self.pc, "offer");
        } else if (std.mem.eql(u8, msg_type, "peer-disconnected")) {
            log.info("peer disconnected", .{});
            self.state.store(.disconnected, .release);
        }
    }

    fn ptrToSelf(ptr: ?*anyopaque) ?*WebRtc {
        return @alignCast(@ptrCast(ptr));
    }

    // ── Minimal JSON helpers (fixed-format, no allocations) ─────────────

    /// Build {"type":"<type>","sdp":"<sdp>"} with escaped sdp
    fn jsonOfferOrAnswer(buf: []u8, msg_type: []const u8, sdp: []const u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.writeAll("{\"type\":\"");
        try w.writeAll(msg_type);
        try w.writeAll("\",\"sdp\":\"");
        try writeJsonEscaped(w, sdp);
        try w.writeAll("\"}");
        return fbs.getWritten();
    }

    /// Build {"type":"ice","candidate":"<cand>","mid":"<mid>"}
    fn jsonIce(buf: []u8, candidate: []const u8, mid: []const u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.writeAll("{\"type\":\"ice\",\"candidate\":\"");
        try writeJsonEscaped(w, candidate);
        try w.writeAll("\",\"mid\":\"");
        try writeJsonEscaped(w, mid);
        try w.writeAll("\"}");
        return fbs.getWritten();
    }

    /// Unescape a JSON string value: \n → LF, \r → CR, \\ → \, \" → ", \t → TAB.
    /// Returns the unescaped length, or null if the output buffer is too small.
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

    /// Extract a JSON string value for a given key. Minimal scanner for
    /// fixed-format messages like {"type":"answer","sdp":"v=0\r\n..."}.
    fn jsonExtract(json: []const u8, key: []const u8) ?[]const u8 {
        // Search for "key":"
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
                // Find closing unescaped "
                var j = val_start;
                while (j < json.len) : (j += 1) {
                    if (json[j] == '\\') {
                        j += 1; // skip escaped char
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
};

// ============================================================================
// Tests
// ============================================================================

test "jsonExtract basic" {
    const json = "{\"type\":\"answer\",\"sdp\":\"v=0\\r\\n\"}";
    try std.testing.expectEqualSlices(u8, "answer", WebRtc.jsonExtract(json, "type").?);
    try std.testing.expectEqualSlices(u8, "v=0\\r\\n", WebRtc.jsonExtract(json, "sdp").?);
    try std.testing.expect(WebRtc.jsonExtract(json, "missing") == null);
}

test "jsonExtract ice message" {
    const json = "{\"type\":\"ice\",\"candidate\":\"candidate:1 1 UDP 2130706431 192.168.1.1 1234 typ host\",\"mid\":\"0\"}";
    try std.testing.expectEqualSlices(u8, "ice", WebRtc.jsonExtract(json, "type").?);
    try std.testing.expectEqualSlices(u8, "0", WebRtc.jsonExtract(json, "mid").?);
}

test "jsonOfferOrAnswer roundtrip" {
    var buf: [8192]u8 = undefined;
    const msg = try WebRtc.jsonOfferOrAnswer(&buf, "offer", "v=0\r\ntest");
    try std.testing.expectEqualSlices(u8, "offer", WebRtc.jsonExtract(msg, "type").?);
    // SDP will have \r\n escaped
    const sdp = WebRtc.jsonExtract(msg, "sdp").?;
    try std.testing.expect(std.mem.indexOf(u8, sdp, "v=0") != null);
}

test "jsonIce roundtrip" {
    var buf: [2048]u8 = undefined;
    const msg = try WebRtc.jsonIce(&buf, "candidate:1 1 UDP 2130706431", "0");
    try std.testing.expectEqualSlices(u8, "ice", WebRtc.jsonExtract(msg, "type").?);
    try std.testing.expectEqualSlices(u8, "0", WebRtc.jsonExtract(msg, "mid").?);
}
