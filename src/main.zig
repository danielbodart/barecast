const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");
const NvFbc = @import("nvfbc").NvFbc;
const Encoder = @import("encoder").Encoder;
const FrameSink = @import("encoder").FrameSink;
const IvfWriter = @import("ivf").IvfWriter;
const WebRtc = @import("webrtc").WebRtc;

var should_exit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn main() void {
    std.debug.print("barecast v{s}\n", .{build_options.version});
    installSignalHandler();

    const cli = parseCli();
    switch (cli) {
        .record => |r| runRecord(r.path, r.seconds),
        .stream => runStream(),
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

fn runStream() void {
    const allocator = std.heap.c_allocator;

    var fbc = NvFbc.init() catch return;
    defer fbc.deinit();

    const first_frame = fbc.grabFrame() catch return;
    std.debug.print("NvFBC: {}x{}, texture={}\n", .{
        first_frame.width, first_frame.height, first_frame.texture_id,
    });

    // Generate room ID (8 random bytes → 16 hex chars)
    const room_id = generateRoomId() catch {
        std.debug.print("Failed to generate room ID\n", .{});
        return;
    };

    // Signaling URL from env or default
    const signaling_url = std.process.getEnvVarOwned(allocator, "BARECAST_URL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => allocator.dupe(u8, "wss://barecast.dev") catch return,
        else => return,
    };
    defer allocator.free(signaling_url);

    std.debug.print("\n  Room: https://barecast.dev/?room={s}\n\n", .{&room_id});
    std.debug.print("Connecting to signaling server...\n", .{});

    var rtc = WebRtc.init(allocator, signaling_url, &room_id) catch |err| {
        std.debug.print("WebRTC init failed: {}\n", .{err});
        return;
    };
    defer rtc.deinit();

    // Register callbacks now that rtc is at its final stack location
    rtc.start();

    std.debug.print("Waiting for viewer...\n", .{});
    rtc.waitForConnection(120_000, &should_exit) catch |err| {
        std.debug.print("Connection failed: {}\n", .{err});
        return;
    };
    std.debug.print("Viewer connected, streaming...\n", .{});

    var enc = Encoder.init(&fbc, first_frame, .{ .webrtc = &rtc }) catch |err| {
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

    while (!should_exit.load(.acquire) and rtc.state.load(.acquire) == .connected) {
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
    stream: void,
};

fn parseCli() Cli {
    var args = std.process.args();
    _ = args.next(); // skip argv[0]

    const first = args.next() orelse return .{ .stream = {} };

    if (std.mem.eql(u8, first, "--record")) {
        const path = args.next() orelse {
            std.debug.print("Usage: barecast --record <output.ivf> [seconds]\n", .{});
            std.process.exit(1);
        };
        const seconds: ?u32 = if (args.next()) |s|
            std.fmt.parseInt(u32, s, 10) catch {
                std.debug.print("Invalid duration: expected integer seconds\n", .{});
                std.process.exit(1);
            }
        else
            null;
        return .{ .record = .{ .path = path, .seconds = seconds } };
    }

    // Legacy: bare number means record mode with default output
    if (std.fmt.parseInt(u32, first, 10)) |s| {
        return .{ .record = .{ .path = "output.ivf", .seconds = s } };
    } else |_| {}

    std.debug.print("Usage:\n", .{});
    std.debug.print("  barecast                          Stream via WebRTC\n", .{});
    std.debug.print("  barecast --record output.ivf      Record to IVF\n", .{});
    std.debug.print("  barecast --record output.ivf 5    Record 5s to IVF\n", .{});
    std.process.exit(1);
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
