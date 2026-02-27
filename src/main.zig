const std = @import("std");
const build_options = @import("build_options");
const NvFbc = @import("nvfbc").NvFbc;
const Encoder = @import("encoder").Encoder;

pub fn main() void {
    std.debug.print("barecast v{s}\n", .{build_options.version});

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
    defer enc.deinit();

    // Process the first frame we already grabbed
    enc.processFrame(first_frame) catch |err| {
        std.debug.print("Encode error: {}\n", .{err});
        return;
    };

    // Capture loop — 300 frames (~10s at 30fps)
    const max_frames: u32 = 300;
    var i: u32 = 1;
    while (i < max_frames) : (i += 1) {
        const frame = fbc.grabFrame() catch |err| {
            std.debug.print("Capture error at frame {}: {}\n", .{ i, err });
            break;
        };

        enc.processFrame(frame) catch |err| {
            std.debug.print("Encode error at frame {}: {}\n", .{ i, err });
            break;
        };
    }

    // Flush encoder and finalize IVF
    enc.finish() catch |err| {
        std.debug.print("Finalize error: {}\n", .{err});
    };

    const stats = enc.stats;
    std.debug.print("Done: {} encoded, {} skipped, {} keyframes, {} bytes\n", .{
        stats.frames_encoded, stats.frames_skipped, stats.keyframes, stats.total_bytes,
    });
}

test "placeholder" {
    try std.testing.expect(true);
}
