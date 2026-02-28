const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");
const nvfbc = @import("nvfbc");
const NvFbc = nvfbc.NvFbc;
const Box = nvfbc.Box;
const Encoder = @import("encoder").Encoder;
const FrameSink = @import("encoder").FrameSink;
const IvfWriter = @import("ivf").IvfWriter;
const BroadcastSession = @import("session").BroadcastSession;
const Overlay = @import("overlay").Overlay;

var should_exit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn main() void {
    std.debug.print("zerocast v{s}\n", .{build_options.version});
    installSignalHandler();

    const parsed = parseCli();
    switch (parsed.cli) {
        .record => |r| runRecord(r.path, r.seconds, parsed.geometry),
        .stream => |s| runStream(s.room_id, parsed.geometry),
    }
}

// ─── Record mode ─────────────────────────────────────────────────────────

fn runRecord(output_path: []const u8, seconds: ?u32, geometry: Box) void {
    var fbc = NvFbc.init(geometry) catch return;
    defer fbc.deinit();

    const first_frame = fbc.grabFrame() catch return;
    std.debug.print("NvFBC: {}x{}, texture={}\n", .{
        first_frame.width, first_frame.height, first_frame.texture_id,
    });

    const ivf = IvfWriter.init(output_path) catch |err| {
        std.debug.print("IVF init failed: {}\n", .{err});
        return;
    };
    var enc = Encoder.init(&fbc, first_frame, .{ .ivf = ivf }) catch |err| {
        std.debug.print("Encoder init failed: {}\n", .{err});
        return;
    };
    defer {
        enc.finish() catch |err| {
            std.debug.print("Finalize error: {}\n", .{err});
        };
        printStats(enc.stats);
        enc.deinit();
    }

    if (seconds) |s| {
        std.debug.print("Recording {}s to {s}...\n", .{ s, output_path });
    } else {
        std.debug.print("Recording to {s}... (Ctrl-C to stop)\n", .{output_path});
    }

    const duration_ns: ?u64 = if (seconds) |s| @as(u64, s) * std.time.ns_per_s else null;

    var timer = std.time.Timer.start() catch {
        std.debug.print("Timer unavailable\n", .{});
        return;
    };

    enc.processFrame(first_frame) catch |err| {
        std.debug.print("Encode error: {}\n", .{err});
        return;
    };

    while (!should_exit.load(.acquire)) {
        if (duration_ns) |d| {
            if (timer.read() >= d) break;
        }

        const frame = fbc.grabFrame() catch |err| {
            std.debug.print("Capture error: {}\n", .{err});
            break;
        };

        enc.processFrame(frame) catch |err| {
            std.debug.print("Encode error: {}\n", .{err});
            break;
        };
    }
}

// ─── Stream mode (WebRTC) ────────────────────────────────────────────────

fn runStream(cli_room_id: ?[]const u8, geometry: Box) void {
    const allocator = std.heap.c_allocator;

    var fbc = NvFbc.init(geometry) catch return;
    defer fbc.deinit();

    const first_frame = fbc.grabFrame() catch return;
    std.debug.print("NvFBC: {}x{}, texture={}\n", .{
        first_frame.width, first_frame.height, first_frame.texture_id,
    });

    // Show corner brackets indicating the shared region
    const overlay_box = if (geometry.w != 0) geometry else Box{
        .x = 0, .y = 0, .w = first_frame.width, .h = first_frame.height,
    };
    var overlay: ?Overlay = Overlay.init(overlay_box) catch |err| blk: {
        std.debug.print("Overlay init failed (non-fatal): {}\n", .{err});
        break :blk null;
    };
    defer if (overlay) |*o| o.deinit();

    // Room ID: from --room flag or generate random
    var generated_id: [16]u8 = undefined;
    const room_id: []const u8 = if (cli_room_id) |id| id else blk: {
        generated_id = generateRoomId() catch {
            std.debug.print("Failed to generate room ID\n", .{});
            return;
        };
        break :blk &generated_id;
    };

    // Base URL from env or default (https://)
    const base_url = std.process.getEnvVarOwned(allocator, "ZEROCAST_URL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => allocator.dupe(u8, "https://zerocast.bodar.com") catch return,
        else => return,
    };
    defer allocator.free(base_url);

    // Derive WebSocket URL: https:// → wss://, http:// → ws://
    const ws_scheme: []const u8 = if (std.mem.startsWith(u8, base_url, "https://")) "wss://" else "ws://";
    const host_start: usize = if (std.mem.startsWith(u8, base_url, "https://"))
        @as(usize, 8)
    else if (std.mem.startsWith(u8, base_url, "http://"))
        @as(usize, 7)
    else
        @as(usize, 0);
    var ws_url_buf: [512]u8 = undefined;
    const signaling_url = std.fmt.bufPrint(&ws_url_buf, "{s}{s}", .{
        ws_scheme, base_url[host_start..],
    }) catch return;

    // Share URL for display
    var share_url_buf: [512]u8 = undefined;
    const share_url = std.fmt.bufPrint(&share_url_buf, "{s}/room/{s}", .{
        base_url, room_id,
    }) catch "https://zerocast.bodar.com/room/???";
    std.debug.print("\n  Room: {s}\n\n", .{share_url});
    std.debug.print("Connecting to signaling server...\n", .{});

    var session = BroadcastSession.init(signaling_url, room_id) catch |err| {
        std.debug.print("Session init failed: {}\n", .{err});
        return;
    };
    defer session.deinit();

    // Register callbacks now that session is at its final stack location
    session.start();

    std.debug.print("Streaming. Viewers can connect at any time.\n", .{});

    var enc = Encoder.init(&fbc, first_frame, .{ .session = &session }) catch |err| {
        std.debug.print("Encoder init failed: {}\n", .{err});
        return;
    };
    defer {
        enc.finish() catch {};
        printStats(enc.stats);
        enc.deinit();
    }

    enc.processFrame(first_frame) catch |err| {
        std.debug.print("Encode error: {}\n", .{err});
        return;
    };

    // Capture loop — runs regardless of viewer count.
    // Frames are silently dropped when no viewers are connected.
    const ping_interval_ns: u64 = 30 * std.time.ns_per_s;
    var ping_timer = std.time.Timer.start() catch {
        std.debug.print("Timer unavailable\n", .{});
        return;
    };

    while (!should_exit.load(.acquire)) {
        // Periodic signaling keepalive / reconnect check
        if (ping_timer.read() >= ping_interval_ns) {
            ping_timer.reset();
            if (!session.sendPing()) {
                session.reconnect();
            }
        }

        const frame = fbc.grabFrame() catch |err| {
            std.debug.print("Capture error: {}\n", .{err});
            break;
        };

        enc.processFrame(frame) catch |err| {
            std.debug.print("Encode error: {}\n", .{err});
            break;
        };
    }

    std.debug.print("Stream ended.\n", .{});
}

// ─── CLI parsing ─────────────────────────────────────────────────────────

const Cli = union(enum) {
    record: struct { path: []const u8, seconds: ?u32 },
    stream: struct { room_id: ?[]const u8 },
};

const ParsedCli = struct {
    cli: Cli,
    geometry: Box, // zero = full screen
};

fn parseCli() ParsedCli {
    var args = std.process.args();
    _ = args.next(); // skip argv[0]

    var room_id: ?[]const u8 = null;
    var geometry: Box = .{};
    var first: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--room")) {
            room_id = args.next() orelse {
                std.debug.print("--room requires a room ID argument\n", .{});
                std.process.exit(1);
            };
            // Validate: alphanumeric + dash + underscore, max 64 chars
            if (!isValidRoomId(room_id.?)) {
                std.debug.print("Invalid room ID: use alphanumeric, dash, underscore (max 64 chars)\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--geometry")) {
            const val = args.next() orelse {
                std.debug.print("--geometry requires a WxH+X+Y argument\n", .{});
                std.process.exit(1);
            };
            geometry = parseGeometry(val) orelse {
                std.debug.print("Invalid geometry '{s}': expected WxH+X+Y (e.g. 1920x1080+0+0)\n", .{val});
                std.process.exit(1);
            };
        } else if (first == null) {
            first = arg;
        }
    }

    // No positional arg → stream mode
    if (first == null) return .{ .cli = .{ .stream = .{ .room_id = room_id } }, .geometry = geometry };

    if (std.mem.eql(u8, first.?, "--record")) {
        // Re-parse for record mode — room flag is ignored
        var args2 = std.process.args();
        _ = args2.next(); // skip argv[0]
        var path: ?[]const u8 = null;
        var seconds: ?u32 = null;
        while (args2.next()) |a| {
            if (std.mem.eql(u8, a, "--record")) {
                path = args2.next();
            } else if (std.mem.eql(u8, a, "--room") or std.mem.eql(u8, a, "--geometry")) {
                _ = args2.next(); // skip value
            } else if (path != null and seconds == null) {
                seconds = std.fmt.parseInt(u32, a, 10) catch {
                    std.debug.print("Invalid duration: expected integer seconds\n", .{});
                    std.process.exit(1);
                };
            }
        }
        if (path == null) {
            std.debug.print("Usage: zerocast --record <output.ivf> [seconds]\n", .{});
            std.process.exit(1);
        }
        return .{ .cli = .{ .record = .{ .path = path.?, .seconds = seconds } }, .geometry = geometry };
    }

    // Legacy: bare number means record mode with default output
    if (std.fmt.parseInt(u32, first.?, 10)) |s| {
        return .{ .cli = .{ .record = .{ .path = "output.ivf", .seconds = s } }, .geometry = geometry };
    } else |_| {}

    std.debug.print("Usage:\n", .{});
    std.debug.print("  zerocast                                     Stream via WebRTC\n", .{});
    std.debug.print("  zerocast --room <id>                         Stream with a stable room ID\n", .{});
    std.debug.print("  zerocast --geometry WxH+X+Y                  Capture a sub-region\n", .{});
    std.debug.print("  zerocast --record output.ivf                 Record to IVF\n", .{});
    std.debug.print("  zerocast --record output.ivf 5               Record 5s to IVF\n", .{});
    std.process.exit(1);
}

/// Parse X11 geometry format: WxH+X+Y
fn parseGeometry(s: []const u8) ?Box {
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

fn isValidRoomId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    }
    return true;
}

// ─── Helpers ─────────────────────────────────────────────────────────────

fn generateRoomId() ![16]u8 {
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

fn printStats(stats: @import("encoder").Stats) void {
    std.debug.print("Done: {} encoded, {} skipped, {} keyframes, {} bytes\n", .{
        stats.frames_encoded, stats.frames_skipped, stats.keyframes, stats.total_bytes,
    });
}

fn installSignalHandler() void {
    const handler = struct {
        fn handle(_: c_int) callconv(.c) void {
            should_exit.store(true, .release);
        }
    }.handle;

    const act = posix.Sigaction{
        .handler = .{ .handler = handler },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);
}

// ─── Tests ───────────────────────────────────────────────────────────────

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

test "isValidRoomId" {
    try std.testing.expect(isValidRoomId("abc123"));
    try std.testing.expect(isValidRoomId("my-room_01"));
    try std.testing.expect(!isValidRoomId(""));
    try std.testing.expect(!isValidRoomId("room with spaces"));
    try std.testing.expect(!isValidRoomId("a" ** 65));
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
    try std.testing.expectEqual(@as(u32, 0), b.x);
    try std.testing.expectEqual(@as(u32, 0), b.y);
}

test "parseGeometry rejects zero dimensions" {
    try std.testing.expect(parseGeometry("0x720+0+0") == null);
    try std.testing.expect(parseGeometry("1280x0+0+0") == null);
}

test "parseGeometry rejects malformed" {
    try std.testing.expect(parseGeometry("1280x720") == null);
    try std.testing.expect(parseGeometry("1280x720+0") == null);
    try std.testing.expect(parseGeometry("abcxdef+0+0") == null);
    try std.testing.expect(parseGeometry("") == null);
}
