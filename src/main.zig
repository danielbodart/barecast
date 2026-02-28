const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");
const NvFbc = @import("nvfbc").NvFbc;
const Encoder = @import("encoder").Encoder;
const FrameSink = @import("encoder").FrameSink;
const IvfWriter = @import("ivf").IvfWriter;
const BroadcastSession = @import("session").BroadcastSession;

var should_exit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn main() void {
    std.debug.print("zerocast v{s}\n", .{build_options.version});
    installSignalHandler();

    const cli = parseCli();
    switch (cli) {
        .record => |r| runRecord(r.path, r.seconds),
        .stream => |s| runStream(s.room_id),
    }
}

// ─── Record mode ─────────────────────────────────────────────────────────

fn runRecord(output_path: []const u8, seconds: ?u32) void {
    var fbc = NvFbc.init() catch return;
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

fn runStream(cli_room_id: ?[]const u8) void {
    const allocator = std.heap.c_allocator;

    var fbc = NvFbc.init() catch return;
    defer fbc.deinit();

    const first_frame = fbc.grabFrame() catch return;
    std.debug.print("NvFBC: {}x{}, texture={}\n", .{
        first_frame.width, first_frame.height, first_frame.texture_id,
    });

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
    while (!should_exit.load(.acquire)) {
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

fn parseCli() Cli {
    var args = std.process.args();
    _ = args.next(); // skip argv[0]

    var room_id: ?[]const u8 = null;
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
        } else if (first == null) {
            first = arg;
        }
    }

    // No positional arg → stream mode
    if (first == null) return .{ .stream = .{ .room_id = room_id } };

    if (std.mem.eql(u8, first.?, "--record")) {
        // Re-parse for record mode — room flag is ignored
        var args2 = std.process.args();
        _ = args2.next(); // skip argv[0]
        var path: ?[]const u8 = null;
        var seconds: ?u32 = null;
        while (args2.next()) |a| {
            if (std.mem.eql(u8, a, "--record")) {
                path = args2.next();
            } else if (std.mem.eql(u8, a, "--room")) {
                _ = args2.next(); // skip room value
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
        return .{ .record = .{ .path = path.?, .seconds = seconds } };
    }

    // Legacy: bare number means record mode with default output
    if (std.fmt.parseInt(u32, first.?, 10)) |s| {
        return .{ .record = .{ .path = "output.ivf", .seconds = s } };
    } else |_| {}

    std.debug.print("Usage:\n", .{});
    std.debug.print("  zerocast                              Stream via WebRTC\n", .{});
    std.debug.print("  zerocast --room <id>                  Stream with a stable room ID\n", .{});
    std.debug.print("  zerocast --record output.ivf          Record to IVF\n", .{});
    std.debug.print("  zerocast --record output.ivf 5        Record 5s to IVF\n", .{});
    std.process.exit(1);
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
