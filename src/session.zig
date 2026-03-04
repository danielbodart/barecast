const std = @import("std");
const c = @cImport({
    @cDefine("RTC_STATIC", {});
    @cInclude("rtc/rtc.h");
});
const input_protocol = @import("input_protocol");
const ViewerRegistry = @import("viewer_state").ViewerRegistry;

const log = std.log.scoped(.session);

pub const MAX_PEERS: usize = 8;
pub const PEER_ID_LEN: usize = 16;

pub const SessionMode = enum {
    screen, // AV1 track + unreliable "input" data channel
    terminal, // No track + reliable "terminal" data channel
};

/// Callback for terminal data channel messages (viewer input).
pub const TerminalDataCallback = struct {
    ptr: *anyopaque,
    onData: *const fn (*anyopaque, []const u8) void,
    onResize: *const fn (*anyopaque, u16, u16) void,
};

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
    dc: c_int,
    peer_id: [PEER_ID_LEN]u8,
    state: std.atomic.Value(PeerState),
    force_keyframe: std.atomic.Value(bool),
    session: *BroadcastSession,

    /// Initialize this peer slot in-place. Creates only the PC handle.
    /// Track and data channel are created in start() after callbacks are registered,
    /// because they trigger auto-negotiation which needs the localDescriptionCallback.
    pub fn initInPlace(
        self: *Peer,
        session: *BroadcastSession,
        peer_id: [PEER_ID_LEN]u8,
    ) !void {
        const pc = c.rtcCreatePeerConnection(&session.pc_config);
        if (pc < 0) return error.PeerConnectionFailed;

        self.* = .{
            .pc = pc,
            .track = -1,
            .dc = -1,
            .peer_id = peer_id,
            .state = std.atomic.Value(PeerState).init(.connecting),
            .force_keyframe = std.atomic.Value(bool).init(false),
            .session = session,
        };
    }

    /// Register callbacks, add track/data channel, and generate offer.
    /// MUST be called after initInPlace, once Peer is at its final memory location.
    pub fn start(self: *Peer) void {
        c.rtcSetUserPointer(self.pc, @ptrCast(self));
        _ = c.rtcSetLocalDescriptionCallback(self.pc, localDescriptionCallback);
        _ = c.rtcSetLocalCandidateCallback(self.pc, localCandidateCallback);
        _ = c.rtcSetStateChangeCallback(self.pc, stateChangeCallback);

        if (self.session.mode == .screen) {
            self.startScreen();
        } else {
            self.startTerminal();
        }

        // Generate offer explicitly — auto-negotiation is disabled
        _ = c.rtcSetLocalDescription(self.pc, "offer");
    }

    fn startScreen(self: *Peer) void {
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

        const track = c.rtcAddTrackEx(self.pc, &track_init);
        if (track >= 0) {
            self.track = track;

            // AV1 packetizer
            var pkt_init = std.mem.zeroes(c.rtcPacketizerInit);
            pkt_init.ssrc = 1;
            pkt_init.cname = "zerocast";
            pkt_init.payloadType = 96;
            pkt_init.clockRate = 90000;
            pkt_init.maxFragmentSize = 1200;
            pkt_init.obuPacketization = c.RTC_OBU_PACKETIZED_TEMPORAL_UNIT;
            pkt_init.absCaptureTimeId = 3; // extmap ID for abs-capture-time
            _ = c.rtcSetAV1Packetizer(track, &pkt_init);

            // RTCP chain
            _ = c.rtcChainRtcpSrReporter(track);
            _ = c.rtcChainRtcpNackResponder(track, 512);
            _ = c.rtcChainPliHandler(track, pliCallback);
        } else {
            log.warn("track creation failed: {d}", .{track});
        }

        // Data channel for input/draw (unreliable + unordered)
        var dc_init = std.mem.zeroes(c.rtcDataChannelInit);
        dc_init.reliability.unordered = true;
        dc_init.reliability.unreliable = true;
        dc_init.reliability.maxRetransmits = 0;

        const dc = c.rtcCreateDataChannelEx(self.pc, "input", &dc_init);
        if (dc >= 0) {
            self.dc = dc;
            c.rtcSetUserPointer(dc, @ptrCast(self));
            _ = c.rtcSetOpenCallback(dc, dcOpenCallback);
            _ = c.rtcSetMessageCallback(dc, dcMessageCallback);
        } else {
            log.warn("data channel creation failed: {d}", .{dc});
        }
    }

    fn startTerminal(self: *Peer) void {
        // Reliable, ordered data channel for terminal I/O
        var dc_init = std.mem.zeroes(c.rtcDataChannelInit);
        // Default: reliable + ordered (all zeros)

        const dc = c.rtcCreateDataChannelEx(self.pc, "terminal", &dc_init);
        if (dc >= 0) {
            self.dc = dc;
            c.rtcSetUserPointer(dc, @ptrCast(self));
            _ = c.rtcSetOpenCallback(dc, termDcOpenCallback);
            _ = c.rtcSetMessageCallback(dc, termDcMessageCallback);
        } else {
            log.warn("terminal data channel creation failed: {d}", .{dc});
        }
    }

    /// Close PC + track + DC handles. Does NOT call rtcCleanup().
    pub fn deinit(self: *Peer) void {
        if (self.dc >= 0) _ = c.rtcDeleteDataChannel(self.dc);
        _ = c.rtcDeleteTrack(self.track);
        _ = c.rtcDeletePeerConnection(self.pc);
        self.pc = -1;
        self.track = -1;
        self.dc = -1;
    }

    /// Send one encoded frame on this peer's track.
    pub fn sendFrame(self: *Peer, data: []const u8, rtp_ts: u32, capture_ntp: u64) void {
        _ = c.rtcSetTrackRtpTimestamp(self.track, rtp_ts);
        _ = c.rtcSetTrackAbsCaptureTime(self.track, capture_ntp);
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

    /// Data channel opened — send color assignment to viewer.
    fn dcOpenCallback(_: c_int, ptr: ?*anyopaque) callconv(.c) void {
        const self = ptrToPeer(ptr) orelse return;
        const session = self.session;

        // Register this viewer and get assigned color
        if (session.viewer_registry) |reg| {
            if (reg.addViewer(self.peer_id)) |color_index| {
                log.info("viewer {s}: assigned color {d}", .{ self.peer_id, color_index });
                const msg = input_protocol.encodeColorAssign(color_index);
                _ = c.rtcSendMessage(self.dc, @ptrCast(&msg), @intCast(msg.len));
            }
        }
    }

    /// Data channel message — decode and dispatch input/draw events.
    fn dcMessageCallback(_: c_int, raw_msg: [*c]const u8, size: c_int, ptr: ?*anyopaque) callconv(.c) void {
        const self = ptrToPeer(ptr) orelse return;

        // Binary messages have positive size in libdatachannel C API
        if (size <= 0) return;
        const len: usize = @intCast(size);
        const data: []const u8 = @as([*]const u8, @ptrCast(raw_msg))[0..len];

        const msg = input_protocol.decode(data) catch return;

        const session = self.session;
        const reg = session.viewer_registry orelse return;
        const peer_id = &self.peer_id;

        switch (msg) {
            .mouse_move => |m| {
                // Only update the overlay cursor — don't move the host's
                // system pointer. The system pointer is positioned just
                // before mouse_down/mouse_up so it lands at the click target.
                reg.updateCursor(peer_id, m.x, m.y);
            },
            .mouse_down => |m| {
                reg.updateCursor(peer_id, m.x, m.y);
                if (session.input_handler) |handler| {
                    handler.moveMouse(m.x, m.y);
                    handler.injectMouseButton(@intFromEnum(m.button), 1);
                }
            },
            .mouse_up => |m| {
                reg.updateCursor(peer_id, m.x, m.y);
                if (session.input_handler) |handler| {
                    handler.moveMouse(m.x, m.y);
                    handler.injectMouseButton(@intFromEnum(m.button), 0);
                }
            },
            .scroll => |s| {
                if (session.input_handler) |handler| {
                    handler.moveMouse(s.x, s.y);
                    handler.injectScroll(s.delta);
                }
            },
            .key_down => |k| {
                if (session.input_handler) |handler| handler.injectKeyCode(k.code, 1);
            },
            .key_up => |k| {
                if (session.input_handler) |handler| handler.injectKeyCode(k.code, 0);
            },
            .draw_start => |d| reg.drawStart(peer_id, d.x, d.y),
            .draw_move => |d| reg.drawMove(peer_id, d.x, d.y),
            .draw_end => reg.drawEnd(peer_id),
            .draw_undo => reg.drawUndo(peer_id),
            .draw_clear => reg.drawClear(peer_id),
            .color_assign => {}, // host→viewer only, ignore if received
        }
    }

    /// Terminal data channel opened — mark peer as connected.
    /// For data-channel-only connections (no media tracks), the DC open
    /// event is the reliable signal that the peer connection is usable.
    fn termDcOpenCallback(_: c_int, ptr: ?*anyopaque) callconv(.c) void {
        const self = ptrToPeer(ptr) orelse return;
        log.info("terminal channel open for {s}", .{self.peer_id});
        self.state.store(.connected, .release);
    }

    /// Terminal data channel message — forward viewer input to PTY.
    fn termDcMessageCallback(_: c_int, raw_msg: [*c]const u8, size: c_int, ptr: ?*anyopaque) callconv(.c) void {
        const self = ptrToPeer(ptr) orelse return;
        const session = self.session;

        const cb = session.terminal_callback orelse return;

        if (size < 0) {
            // Text message (negative size in libdatachannel C API)
            const len: usize = @intCast(-(size + 1));
            const data: []const u8 = @as([*]const u8, @ptrCast(raw_msg))[0..len];

            // Check for resize escape: \x1b[R{cols};{rows}
            if (data.len > 3 and data[0] == 0x1b and data[1] == '[' and data[2] == 'R') {
                if (parseResize(data[3..])) |r| {
                    cb.onResize(cb.ptr, r.cols, r.rows);
                    return;
                }
            }

            cb.onData(cb.ptr, data);
        } else if (size > 0) {
            // Binary message
            const len: usize = @intCast(size);
            const data: []const u8 = @as([*]const u8, @ptrCast(raw_msg))[0..len];
            cb.onData(cb.ptr, data);
        }
    }

    fn parseResize(data: []const u8) ?struct { cols: u16, rows: u16 } {
        // Parse "{cols};{rows}"
        const sep = std.mem.indexOfScalar(u8, data, ';') orelse return null;
        const cols = std.fmt.parseInt(u16, data[0..sep], 10) catch return null;
        const rows = std.fmt.parseInt(u16, data[sep + 1 ..], 10) catch return null;
        return .{ .cols = cols, .rows = rows };
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

/// Interface for input injection (uinput). Optional — null if /dev/uinput
/// is not available or user hasn't opted in.
pub const InputHandler = struct {
    ptr: *anyopaque,
    moveFn: *const fn (*anyopaque, u16, u16) void,
    mouseButtonFn: *const fn (*anyopaque, u8, i32) void,
    scrollFn: *const fn (*anyopaque, i16) void,
    keyCodeFn: *const fn (*anyopaque, []const u8, i32) void,

    pub fn moveMouse(self: InputHandler, x: u16, y: u16) void {
        self.moveFn(self.ptr, x, y);
    }

    pub fn injectMouseButton(self: InputHandler, button: u8, value: i32) void {
        self.mouseButtonFn(self.ptr, button, value);
    }

    pub fn injectScroll(self: InputHandler, delta: i16) void {
        self.scrollFn(self.ptr, delta);
    }

    pub fn injectKeyCode(self: InputHandler, code: []const u8, value: i32) void {
        self.keyCodeFn(self.ptr, code, value);
    }
};

pub const BroadcastSession = struct {
    ws: c_int,
    peers: [MAX_PEERS]Peer,
    peers_mutex: std.Thread.Mutex,
    pc_config: c.rtcConfiguration,
    ice_servers: [2][*c]const u8,
    turn_uri: [256]u8,
    ws_connected: std.atomic.Value(bool),
    ws_url_z: [600]u8,
    ws_url_len: usize,
    mode: SessionMode,
    viewer_registry: ?*ViewerRegistry,
    input_handler: ?InputHandler,
    terminal_callback: ?TerminalDataCallback,

    /// Create signaling WebSocket and initialize empty peer array.
    pub fn init(signaling_url: []const u8, room_id: []const u8, share_id: []const u8, share_type: []const u8, mode: SessionMode) !BroadcastSession {
        c.rtcInitLogger(c.RTC_LOG_WARNING, null);

        // Build WS URL with share_id and share_type for multi-sharer routing
        var url_buf: [599]u8 = undefined;
        const ws_url = std.fmt.bufPrint(&url_buf, "{s}/room/{s}/ws?role=sharer&share_id={s}&share_type={s}", .{
            signaling_url, room_id, share_id, share_type,
        }) catch return error.UrlTooLong;

        var url_z: [600]u8 = undefined;
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
        session.pc_config.disableAutoNegotiation = true;
        session.ws_connected = std.atomic.Value(bool).init(false);
        session.ws_url_z = url_z;
        session.ws_url_len = ws_url.len;
        session.mode = mode;
        session.viewer_registry = null;
        session.input_handler = null;
        session.terminal_callback = null;

        // Initialize all peer slots as empty
        for (&session.peers) |*peer| {
            peer.state = std.atomic.Value(PeerState).init(.empty);
            peer.pc = -1;
            peer.track = -1;
            peer.dc = -1;
        }

        return session;
    }

    /// Register signaling WebSocket callbacks. MUST be called after init,
    /// once the session is at its final memory location.
    pub fn start(self: *BroadcastSession) void {
        // Fix up pc_config pointer — it was copied during init return
        self.pc_config.iceServers = &self.ice_servers;
        self.registerWsCallbacks();
    }

    fn registerWsCallbacks(self: *BroadcastSession) void {
        c.rtcSetUserPointer(self.ws, @ptrCast(self));
        _ = c.rtcSetOpenCallback(self.ws, wsOpenCallback);
        _ = c.rtcSetClosedCallback(self.ws, wsClosedCallback);
        _ = c.rtcSetErrorCallback(self.ws, wsErrorCallback);
        _ = c.rtcSetMessageCallback(self.ws, wsMessageCallback);
    }

    /// Send one encoded AV1 frame to all connected peers.
    /// Called from the main thread within the NVENC bitstream lock window.
    /// Holds peers_mutex to prevent deinit from invalidating track handles
    /// mid-send. The critical section is short — rtcSendMessage just enqueues.
    pub fn sendFrame(self: *BroadcastSession, data: []const u8, pts_ms: u64, capture_ntp: u64) void {
        const rtp_ts: u32 = @truncate(pts_ms * 90);
        self.peers_mutex.lock();
        defer self.peers_mutex.unlock();
        for (&self.peers) |*peer| {
            if (peer.state.load(.acquire) == .connected) {
                peer.sendFrame(data, rtp_ts, capture_ntp);
            }
        }
    }

    /// Send data over the data channel to all connected peers (terminal mode).
    /// Uses text framing (negative size in libdatachannel C API) since PTY
    /// output is UTF-8/ASCII text.
    /// Send a title update over the signaling WebSocket.
    pub fn sendTitleUpdate(self: *BroadcastSession, title: []const u8) void {
        if (!self.ws_connected.load(.acquire)) return;
        var buf: [512]u8 = undefined;
        const msg = jsonTitleUpdate(&buf, title) catch return;
        buf[msg.len] = 0;
        _ = c.rtcSendMessage(self.ws, &buf, -1);
    }

    /// Send data over the data channel to all connected peers (terminal mode).
    /// Uses binary framing — the browser handles both text and binary in onmessage.
    pub fn sendData(self: *BroadcastSession, data: []const u8) void {
        self.peers_mutex.lock();
        defer self.peers_mutex.unlock();
        for (&self.peers) |*peer| {
            if (peer.state.load(.acquire) == .connected and peer.dc >= 0) {
                _ = c.rtcSendMessage(peer.dc, @ptrCast(data.ptr), @intCast(data.len));
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
        var dc: c_int = -1;
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
                    dc = peer.dc;
                    peer.pc = -1;
                    peer.track = -1;
                    peer.dc = -1;
                    freed = peer;
                    break;
                }
            }
        }

        // Remove viewer from registry (clears cursors and drawing paths)
        if (freed) |peer| {
            if (self.viewer_registry) |reg| {
                reg.removeViewer(&peer.peer_id);
            }
        }

        // Close handles outside the mutex — rtcDeletePeerConnection blocks
        // until all scheduled callbacks for this PC complete
        if (dc >= 0) _ = c.rtcDeleteDataChannel(dc);
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
        var dcs: [MAX_PEERS]c_int = .{-1} ** MAX_PEERS;
        {
            self.peers_mutex.lock();
            defer self.peers_mutex.unlock();
            for (&self.peers, 0..) |*peer, i| {
                if (peer.state.load(.acquire) != .empty) {
                    peer.state.store(.closing, .release);
                    pcs[i] = peer.pc;
                    tracks[i] = peer.track;
                    dcs[i] = peer.dc;
                    peer.pc = -1;
                    peer.track = -1;
                    peer.dc = -1;
                }
            }
        }

        // Close handles outside mutex — rtcDeletePeerConnection blocks until
        // callbacks complete, and callbacks may try to acquire peers_mutex
        for (0..MAX_PEERS) |i| {
            if (dcs[i] >= 0) _ = c.rtcDeleteDataChannel(dcs[i]);
            if (tracks[i] >= 0) _ = c.rtcDeleteTrack(tracks[i]);
            if (pcs[i] >= 0) _ = c.rtcDeletePeerConnection(pcs[i]);
        }

        for (&self.peers) |*peer| {
            peer.state.store(.empty, .release);
        }

        c.rtcCleanup();
    }

    /// Send a "ping" text message on the signaling WebSocket.
    /// Returns true if the send succeeded, false if the WebSocket is dead.
    pub fn sendPing(self: *BroadcastSession) bool {
        if (!self.ws_connected.load(.acquire)) return false;
        const result = c.rtcSendMessage(self.ws, "ping", -1);
        if (result < 0) {
            log.warn("signaling ping failed: {d}", .{result});
            self.ws_connected.store(false, .release);
            return false;
        }
        return true;
    }

    /// Reconnect the signaling WebSocket. Call from the main thread only.
    pub fn reconnect(self: *BroadcastSession) void {
        log.info("reconnecting signaling WebSocket...", .{});

        // Close the old handle (safe even if already closed)
        if (self.ws >= 0) _ = c.rtcDeleteWebSocket(self.ws);

        const ws = c.rtcCreateWebSocket(&self.ws_url_z);
        if (ws < 0) {
            log.err("reconnect: rtcCreateWebSocket failed: {d}", .{ws});
            self.ws = -1;
            return;
        }

        self.ws = ws;
        self.registerWsCallbacks();
        // ws_connected will be set to true by wsOpenCallback
    }

    // ── Signaling WebSocket callbacks ────────────────────────────────

    fn wsOpenCallback(_: c_int, ptr: ?*anyopaque) callconv(.c) void {
        const self: *BroadcastSession = @alignCast(@ptrCast(ptr orelse return));
        self.ws_connected.store(true, .release);
        log.info("signaling WebSocket connected", .{});
    }

    fn wsClosedCallback(_: c_int, ptr: ?*anyopaque) callconv(.c) void {
        const self: *BroadcastSession = @alignCast(@ptrCast(ptr orelse return));
        self.ws_connected.store(false, .release);
        log.warn("signaling WebSocket closed", .{});
    }

    fn wsErrorCallback(_: c_int, raw_err: [*c]const u8, ptr: ?*anyopaque) callconv(.c) void {
        const self: *BroadcastSession = @alignCast(@ptrCast(ptr orelse return));
        self.ws_connected.store(false, .release);
        const err_msg = if (raw_err) |e| std.mem.span(e) else "unknown";
        log.err("signaling WebSocket error: {s}", .{err_msg});
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

            // After signaling reconnect the DO re-sends viewer-joined for
            // existing viewers. Skip if we already have an active peer.
            {
                self.peers_mutex.lock();
                defer self.peers_mutex.unlock();
                if (self.findPeerLocked(peer_id_str)) |existing| {
                    const s = existing.state.load(.acquire);
                    if (s == .connecting or s == .connected) {
                        log.info("viewer {s}: already connected, skipping", .{peer_id});
                        return;
                    }
                }
            }

            log.info("viewer joined: {s}", .{peer_id});

            const peer = self.allocPeer(peer_id);
            if (peer) |p| {
                // start() registers callbacks then creates data channel,
                // which triggers offer generation via localDescriptionCallback
                p.start();
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

/// Build {"type":"set-title","title":"<title>"}
fn jsonTitleUpdate(buf: []u8, title: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    try w.writeAll("{\"type\":\"set-title\",\"title\":\"");
    try writeJsonEscaped(w, title);
    try w.writeAll("\"}");
    return fbs.getWritten();
}

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
