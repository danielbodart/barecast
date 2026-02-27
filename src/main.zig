const std = @import("std");
const build_options = @import("build_options");
const NvFbc = @import("nvfbc").NvFbc;
const Encoder = @import("encoder").Encoder;

pub fn main() void {
    std.debug.print("barecast v{s}\n", .{build_options.version});

    // Parse duration: `barecast [seconds]` (default 10)
    const seconds = parseSeconds();
    const duration_ns: u64 = @as(u64, seconds) * std.time.ns_per_s;

    var fbc = NvFbc.init() catch return;
    defer fbc.deinit();

    // Grab first frame to get dimensions and initial texture
    const first_frame = fbc.grabFrame() catch return;
    std.debug.print("NvFBC: {}x{}, texture={}\n", .{
        first_frame.width, first_frame.height, first_frame.texture_id,
    });

    // Initialize encode pipeline: CUDA interop → NVENC AV1 → IVF file
    var enc = Encoder.init(&fbc, first_frame, "output.ivf") catch |err| {
        std.debug.print("Encoder init failed: {}\n", .{err});
        return;
    };
    defer {
        enc.finish() catch |err| {
            std.debug.print("Finalize error: {}\n", .{err});
        };
        const stats = enc.stats;
        std.debug.print("Done: {} encoded, {} skipped, {} keyframes, {} bytes\n", .{
            stats.frames_encoded, stats.frames_skipped, stats.keyframes, stats.total_bytes,
        });
        enc.deinit();
    }

    std.debug.print("Capturing {}s...\n", .{seconds});

    var timer = std.time.Timer.start() catch {
        std.debug.print("Timer unavailable\n", .{});
        return;
    };

    // Process the first frame we already grabbed
    enc.processFrame(first_frame) catch |err| {
        std.debug.print("Encode error: {}\n", .{err});
        return;
    };

    // Capture loop — NvFBC blocks at ~30fps via dwSamplingRateMs,
    // wall clock timer controls total duration
    while (timer.read() < duration_ns) {
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

fn parseSeconds() u32 {
    var args = std.process.args();
    _ = args.next(); // skip argv[0]
    const arg = args.next() orelse return 10;
    return std.fmt.parseInt(u32, arg, 10) catch {
        std.debug.print("Usage: barecast [seconds]\n", .{});
        return 10;
    };
}

test "placeholder" {
    try std.testing.expect(true);
}
