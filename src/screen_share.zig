const std = @import("std");
const nvfbc = @import("nvfbc");
const NvFbc = nvfbc.NvFbc;
const Box = nvfbc.Box;
const Encoder = @import("encoder").Encoder;
const FrameSink = @import("encoder").FrameSink;
const IvfWriter = @import("ivf").IvfWriter;
const BroadcastSession = @import("session").BroadcastSession;
const InputHandler = @import("session").InputHandler;
const Overlay = @import("overlay").Overlay;
const ViewerRegistry = @import("viewer_state").ViewerRegistry;
const VirtualInput = @import("uinput").VirtualInput;

const log = std.log.scoped(.screen_share);

pub const ScreenShareConfig = struct {
    geometry: Box = .{}, // zero = full screen
    fps: u32 = 30,
    room_id: ?[]const u8 = null,
    record: bool = false,
    base_url: []const u8 = "https://zerocast.bodar.com",
    recordings_dir: []const u8 = "", // set by daemon
};

/// Self-contained screen share session. Wraps the NvFbc → Encoder → BroadcastSession pipeline.
/// Created by the daemon on `share screen`, runs in a dedicated thread.
///
/// Uses init-in-place pattern (same as Peer.initInPlace in session.zig) to avoid
/// copying the struct after init. Internal pointers (encoder → session, session →
/// viewer_registry) point at fields within `self`, so `self` must be at its final
/// memory location before init is called.
pub const ScreenShare = struct {
    session_id: [16]u8,
    room_id_buf: [16]u8,
    room_id: []const u8,
    room_url_buf: [512]u8,
    room_url: []const u8,
    share_url_buf: [512]u8,
    share_url: []const u8,
    fbc: NvFbc,
    overlay: ?Overlay,
    viewer_registry: ViewerRegistry,
    vinput: ?VirtualInput,
    session: BroadcastSession,
    encoder: Encoder,
    recording: ?IvfWriter,
    should_stop: std.atomic.Value(bool),
    start_time: std.time.Timer,
    last_fps: u32,
    last_bitrate: u64,
    config: ScreenShareConfig,

    /// Initialize a screen share session in-place. `self` must already be at
    /// its final memory location (heap-allocated by the caller).
    /// After init, call start() to register signaling callbacks.
    pub fn initInPlace(self: *ScreenShare, config: ScreenShareConfig) !void {
        const allocator = std.heap.c_allocator;

        self.should_stop = std.atomic.Value(bool).init(false);
        self.config = config;

        var fbc = try NvFbc.init(config.geometry, config.fps);
        errdefer fbc.deinit();

        const first_frame = try fbc.grabFrame();
        log.info("NvFBC: {}x{}, texture={}", .{
            first_frame.width, first_frame.height, first_frame.texture_id,
        });

        // Overlay for shared region
        const overlay_box = if (config.geometry.w != 0) config.geometry else Box{
            .x = 0, .y = 0, .w = first_frame.width, .h = first_frame.height,
        };
        var overlay: ?Overlay = Overlay.init(overlay_box) catch |err| blk: {
            log.warn("overlay init failed (non-fatal): {}", .{err});
            break :blk null;
        };
        errdefer if (overlay) |*o| o.deinit();

        // Room ID
        if (config.room_id) |id| {
            self.room_id = id;
        } else {
            self.room_id_buf = generateRoomId() catch return error.RoomIdGenFailed;
            self.room_id = &self.room_id_buf;
        }

        // Session ID
        self.session_id = generateRoomId() catch return error.SessionIdGenFailed;

        // Build URLs
        const base_url = config.base_url;
        const ws_scheme: []const u8 = if (std.mem.startsWith(u8, base_url, "https://")) "wss://" else "ws://";
        const host_start: usize = if (std.mem.startsWith(u8, base_url, "https://"))
            @as(usize, 8)
        else if (std.mem.startsWith(u8, base_url, "http://"))
            @as(usize, 7)
        else
            @as(usize, 0);

        const signaling_url = std.fmt.bufPrint(&self.room_url_buf, "{s}{s}", .{
            ws_scheme, base_url[host_start..],
        }) catch return error.UrlTooLong;

        self.share_url = std.fmt.bufPrint(&self.share_url_buf, "{s}/room/{s}", .{
            base_url, self.room_id,
        }) catch "https://zerocast.bodar.com/room/???";

        log.info("room: {s}", .{self.share_url});

        // Viewer state registry
        self.viewer_registry = ViewerRegistry.init();

        // Virtual input
        self.vinput = VirtualInput.init(
            fbc.screen_size.w,
            fbc.screen_size.h,
            @intCast(config.geometry.x),
            @intCast(config.geometry.y),
        ) catch |err| blk: {
            log.warn("virtual input init failed (non-fatal): {}", .{err});
            break :blk null;
        };

        // Broadcast session
        self.session = BroadcastSession.init(signaling_url, self.room_id, &self.session_id, "screen", .screen) catch |err| {
            log.err("session init failed: {}", .{err});
            if (self.vinput) |*vi| vi.deinit();
            if (overlay) |*o| o.deinit();
            fbc.deinit();
            return error.SessionInitFailed;
        };
        // These point at fields within self — safe because self is already at its final location
        self.session.viewer_registry = &self.viewer_registry;
        self.session.meta_callback = screenMetaCallback;
        if (self.vinput) |*vi| {
            self.session.input_handler = vinputHandler(vi);
        }

        // Recording
        self.recording = if (config.record) blk: {
            const recordings_dir = if (config.recordings_dir.len > 0)
                config.recordings_dir
            else
                getDefaultRecordingsDir(allocator) catch {
                    log.warn("failed to determine recordings dir", .{});
                    break :blk null;
                };

            std.fs.cwd().makePath(recordings_dir) catch |err| {
                log.warn("failed to create recordings dir: {}", .{err});
                break :blk null;
            };

            var path_buf: [512]u8 = undefined;
            const now = std.time.timestamp();
            const path = std.fmt.bufPrint(&path_buf, "{s}/screen-{d}.ivf", .{
                recordings_dir, now,
            }) catch {
                log.warn("recording path too long", .{});
                break :blk null;
            };

            const ivf = IvfWriter.init(path) catch |err| {
                log.warn("IVF init failed: {}", .{err});
                break :blk null;
            };
            log.info("recording to {s}", .{path});
            break :blk ivf;
        } else null;

        // Encoder — sink points at self.session which is already at its final address
        self.encoder = Encoder.init(&fbc, first_frame, .{ .session = &self.session }, config.fps) catch |err| {
            log.err("encoder init failed: {}", .{err});
            self.session.deinit();
            if (self.vinput) |*vi| vi.deinit();
            if (overlay) |*o| o.deinit();
            fbc.deinit();
            return error.EncoderInitFailed;
        };

        self.last_fps = 0;
        self.last_bitrate = 0;
        self.fbc = fbc;
        self.overlay = overlay;
        self.start_time = std.time.Timer.start() catch return error.TimerUnavailable;
    }

    /// Register signaling callbacks. Must be called after initInPlace.
    pub fn start(self: *ScreenShare) void {
        self.session.start();
    }

    /// Run the capture loop until should_stop is set. Called from a dedicated thread.
    pub fn runLoop(self: *ScreenShare) void {
        const first_frame = self.fbc.grabFrame() catch |err| {
            log.err("first frame grab failed: {}", .{err});
            return;
        };

        self.encoder.processFrame(first_frame) catch |err| {
            log.err("first frame encode error: {}", .{err});
            return;
        };

        const ping_interval_ns: u64 = 30 * std.time.ns_per_s;
        var ping_timer = std.time.Timer.start() catch return;

        const meta_interval_ns: u64 = 5 * std.time.ns_per_s;
        var meta_timer = std.time.Timer.start() catch return;
        var prev_bytes: u64 = 0;
        var prev_frames: u64 = 0;

        // Send initial meta (resolution known, fps/bitrate = 0)
        self.sendScreenMeta();

        while (!self.should_stop.load(.acquire)) {
            if (ping_timer.read() >= ping_interval_ns) {
                ping_timer.reset();
                if (!self.session.sendPing()) {
                    self.session.reconnect();
                }
            }

            if (meta_timer.read() >= meta_interval_ns) {
                const elapsed_ns = meta_timer.read();
                meta_timer.reset();

                const cur_bytes = self.session.bytes_sent.load(.monotonic);
                const cur_frames = self.session.frames_sent.load(.monotonic);

                const delta_bytes = cur_bytes - prev_bytes;
                const delta_frames = cur_frames - prev_frames;
                prev_bytes = cur_bytes;
                prev_frames = cur_frames;

                const elapsed_s = elapsed_ns / std.time.ns_per_s;
                if (elapsed_s > 0) {
                    self.last_fps = @intCast(delta_frames / elapsed_s);
                    self.last_bitrate = (delta_bytes * 8) / elapsed_s;
                }

                self.sendScreenMeta();
            }

            const frame = self.fbc.grabFrame() catch |err| {
                log.err("capture error: {}", .{err});
                break;
            };

            self.encoder.processFrame(frame) catch |err| {
                log.err("encode error: {}", .{err});
                break;
            };
        }

        log.info("screen share stopped", .{});
    }

    /// Get the number of connected viewers.
    pub fn viewerCount(self: *ScreenShare) u32 {
        var count: u32 = 0;
        for (&self.session.peers) |*peer| {
            if (peer.state.load(.acquire) == .connected) {
                count += 1;
            }
        }
        return count;
    }

    /// Get uptime in seconds.
    pub fn uptimeSeconds(self: *ScreenShare) u64 {
        return self.start_time.read() / std.time.ns_per_s;
    }

    pub fn deinit(self: *ScreenShare) void {
        self.encoder.finish() catch {};
        self.encoder.deinit();
        self.session.deinit();
        if (self.vinput) |*vi| vi.deinit();
        if (self.overlay) |*o| o.deinit();
        if (self.recording) |*r| {
            r.finalize(
                @intCast(self.encoder.width),
                @intCast(self.encoder.height),
                self.config.fps,
                1,
            ) catch {};
            r.deinit();
        }
        self.fbc.deinit();
    }

    fn sendScreenMeta(self: *ScreenShare) void {
        var buf: [256]u8 = undefined;
        const meta = std.fmt.bufPrint(&buf, "{{\"type\":\"set-meta\",\"title\":\"Screen\",\"res\":\"{d}x{d}\",\"fps\":{d},\"bitrate\":{d}}}", .{
            self.encoder.width,
            self.encoder.height,
            self.last_fps,
            self.last_bitrate,
        }) catch return;
        self.session.sendMeta(meta);
    }
};

fn screenMetaCallback(session: *BroadcastSession) void {
    const self: *ScreenShare = @fieldParentPtr("session", session);
    self.sendScreenMeta();
}

// ── Helpers ──────────────────────────────────────────────────────────────

fn vinputHandler(vi: *VirtualInput) InputHandler {
    return .{
        .ptr = @ptrCast(vi),
        .moveFn = &struct {
            fn f(ptr: *anyopaque, x: u16, y: u16) void {
                const v: *VirtualInput = @alignCast(@ptrCast(ptr));
                v.moveMouse(x, y);
            }
        }.f,
        .mouseButtonFn = &struct {
            fn f(ptr: *anyopaque, button: u8, value: i32) void {
                const v: *VirtualInput = @alignCast(@ptrCast(ptr));
                v.injectMouseButton(button, value);
            }
        }.f,
        .scrollFn = &struct {
            fn f(ptr: *anyopaque, delta: i16) void {
                const v: *VirtualInput = @alignCast(@ptrCast(ptr));
                v.injectScroll(delta);
            }
        }.f,
        .keyCodeFn = &struct {
            fn f(ptr: *anyopaque, code: []const u8, value: i32) void {
                const v: *VirtualInput = @alignCast(@ptrCast(ptr));
                v.injectKeyCode(code, value);
            }
        }.f,
    };
}

pub fn generateRoomId() ![16]u8 {
    var bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    var hex: [16]u8 = undefined;
    const charset = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        hex[i * 2] = charset[b >> 4];
        hex[i * 2 + 1] = charset[b & 0x0f];
    }
    return hex;
}

fn getDefaultRecordingsDir(allocator: std.mem.Allocator) ![]const u8 {
    const data_home = std.process.getEnvVarOwned(allocator, "XDG_DATA_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => blk: {
            const home = try std.process.getEnvVarOwned(allocator, "HOME");
            defer allocator.free(home);
            break :blk try std.fmt.allocPrint(allocator, "{s}/.local/share", .{home});
        },
        else => return err,
    };
    defer allocator.free(data_home);
    return std.fmt.allocPrint(allocator, "{s}/zerocast/recordings", .{data_home});
}

/// Parse X11 geometry format: WxH+X+Y
pub fn parseGeometry(s: []const u8) ?Box {
    const x_pos = std.mem.indexOfScalar(u8, s, 'x') orelse return null;
    const plus1 = std.mem.indexOfScalarPos(u8, s, x_pos, '+') orelse return null;
    if (plus1 + 1 >= s.len) return null;
    const plus2 = std.mem.indexOfScalarPos(u8, s, plus1 + 1, '+') orelse return null;

    const w = std.fmt.parseInt(u32, s[0..x_pos], 10) catch return null;
    const h = std.fmt.parseInt(u32, s[x_pos + 1 .. plus1], 10) catch return null;
    const x = std.fmt.parseInt(u32, s[plus1 + 1 .. plus2], 10) catch return null;
    const y = std.fmt.parseInt(u32, s[plus2 + 1 ..], 10) catch return null;

    if (w == 0 or h == 0) return null;

    return .{ .x = x, .y = y, .w = w, .h = h };
}

pub fn isValidRoomId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    }
    return true;
}

// ── Tests ────────────────────────────────────────────────────────────────

test "generateRoomId produces 16 hex chars" {
    const id = try generateRoomId();
    for (id) |ch| {
        try std.testing.expect((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'));
    }
}

test "generateRoomId produces unique IDs" {
    const a = try generateRoomId();
    const b = try generateRoomId();
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "parseGeometry valid" {
    const b = parseGeometry("1280x720+100+200").?;
    try std.testing.expectEqual(@as(u32, 1280), b.w);
    try std.testing.expectEqual(@as(u32, 720), b.h);
    try std.testing.expectEqual(@as(u32, 100), b.x);
    try std.testing.expectEqual(@as(u32, 200), b.y);
}

test "parseGeometry zero origin" {
    const b = parseGeometry("1920x1080+0+0").?;
    try std.testing.expectEqual(@as(u32, 1920), b.w);
    try std.testing.expectEqual(@as(u32, 1080), b.h);
}

test "parseGeometry rejects malformed" {
    try std.testing.expect(parseGeometry("1280x720") == null);
    try std.testing.expect(parseGeometry("0x720+0+0") == null);
    try std.testing.expect(parseGeometry("") == null);
}

test "isValidRoomId" {
    try std.testing.expect(isValidRoomId("abc123"));
    try std.testing.expect(isValidRoomId("my-room_01"));
    try std.testing.expect(!isValidRoomId(""));
    try std.testing.expect(!isValidRoomId("room with spaces"));
    try std.testing.expect(!isValidRoomId("a" ** 65));
}
