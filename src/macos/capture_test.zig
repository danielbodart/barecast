// Standalone capture test — launches Calculator, moves it off-screen,
// captures just the window content (no decorations), encodes HEVC,
// writes raw Annex B to /tmp/zerocast-test.hevc.

const std = @import("std");
const VideoToolboxBackend = @import("encoder_videotoolbox").VideoToolboxBackend;

const c = @cImport({
    @cInclude("macos/screen_capture.h");
});

pub fn main() !void {
    const fps: u32 = 30;
    const duration_s: u64 = 5;
    const total_frames = fps * duration_s;

    // ── Launch Calculator and move off-screen ───────────────────────
    std.debug.print("Launching Calculator...\n", .{});

    var app_pid: i64 = 0;
    const window_id = c.sc_launch_app_offscreen("/System/Applications/Calculator.app", &app_pid);
    if (window_id == 0) {
        std.debug.print("WARNING: Failed to launch app or find window.\n", .{});
        std.debug.print("Falling back to main display capture.\n", .{});
    } else {
        std.debug.print("Calculator window {d} (pid {d}) moved off-screen\n", .{ window_id, app_pid });
    }

    // Give app time to render
    std.Thread.sleep(500 * std.time.ns_per_ms);

    // ── Create capture session ──────────────────────────────────────
    std.debug.print("Creating capture session...\n", .{});

    const capture = if (window_id != 0)
        c.sc_capture_create_window(window_id, fps)
    else
        c.sc_capture_create_display(0, fps);

    if (capture == null) {
        std.debug.print("ERROR: ScreenCaptureKit init failed.\n", .{});
        std.debug.print("Grant Screen Recording permission in:\n", .{});
        std.debug.print("  System Settings → Privacy & Security → Screen Recording\n", .{});
        return error.CaptureInitFailed;
    }
    defer c.sc_capture_destroy(capture);

    if (c.sc_capture_start(capture) != 0) {
        std.debug.print("ERROR: capture start failed\n", .{});
        return error.CaptureStartFailed;
    }

    // Wait for first frame
    var frame: c.SCFrameResult = undefined;
    var attempts: u32 = 0;
    while (attempts < 200) : (attempts += 1) {
        if (c.sc_capture_get_frame(capture, &frame) == 0) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    if (attempts >= 200) {
        std.debug.print("ERROR: no frame received after 2s\n", .{});
        return error.NoFrame;
    }

    const cap_width = frame.width;
    const cap_height = frame.height;
    std.debug.print("Capture: {d}x{d} (window content only)\n", .{ cap_width, cap_height });
    c.sc_capture_release_frame(frame.pixel_buffer);

    // ── Create encoder ──────────────────────────────────────────────
    var vt = try VideoToolboxBackend.init(cap_width, cap_height, fps);
    defer vt.backend().deinit();

    // ── Open output file ────────────────────────────────────────────
    const path = "/tmp/zerocast-test.hevc";
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    std.debug.print("Recording {d} frames to {s}...\n", .{ total_frames, path });

    const frame_interval_ns: u64 = std.time.ns_per_s / fps;
    var timer = try std.time.Timer.start();
    var frames_written: u64 = 0;
    var total_bytes: u64 = 0;

    while (frames_written < total_frames) {
        var f: c.SCFrameResult = undefined;
        if (c.sc_capture_get_frame(capture, &f) != 0) {
            std.Thread.sleep(1 * std.time.ns_per_ms);
            continue;
        }

        const pb = f.pixel_buffer orelse continue;
        defer c.sc_capture_release_frame(pb);

        vt.setPixelBuffer(pb);

        const force_key = frames_written == 0;
        const maybe_encoded = try vt.backend().encode(force_key);

        if (maybe_encoded) |encoded| {
            try file.writeAll(encoded.data);
            total_bytes += encoded.data.len;
            frames_written += 1;
        }

        // Frame pacing
        const elapsed = timer.read();
        if (elapsed < frame_interval_ns) {
            std.Thread.sleep(frame_interval_ns - elapsed);
        }
        timer.reset();
    }

    std.debug.print("Done: {d} frames, {d} bytes ({d} KB)\n", .{
        frames_written, total_bytes, total_bytes / 1024,
    });
    std.debug.print("Output: {s}\n", .{path});
    std.debug.print("Play with: ffplay {s}\n", .{path});
}
