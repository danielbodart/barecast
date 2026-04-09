const std = @import("std");
const Compositor = @import("compositor").Compositor;
const CapturedFrame = @import("compositor").CapturedFrame;
const Debounce = @import("debounce").Debounce;
const StoppedClock = @import("clock").StoppedClock;
const posix = std.posix;

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("GLES2/gl2.h");
});

const ResizeEvent = struct {
    width: u32,
    height: u32,
};

const ResizeArgs = struct { w: u32, h: u32 };

const MAX_EVENTS = 32;
const ms = std.time.ns_per_ms;

// Test state (module-level so callbacks can access it)
var resize_events: [MAX_EVENTS]ResizeEvent = undefined;
var resize_count: usize = 0;
var raw_resize_count: usize = 0;
var capture_next_frame: bool = false;
var frames_captured: usize = 0;
var debounce_clock: StoppedClock = .{};
var resize_debounce: Debounce(ResizeArgs) = undefined;

fn recordResize(args: ResizeArgs, _: ?*anyopaque) void {
    std.debug.print("  debounced resize #{d}: {d}x{d}\n", .{ resize_count + 1, args.w, args.h });
    if (resize_count < MAX_EVENTS) {
        resize_events[resize_count] = .{ .width = args.w, .height = args.h };
        resize_count += 1;
    }
    capture_next_frame = true;
}

fn rawResizeCallback(width: u32, height: u32, _: ?*anyopaque) void {
    raw_resize_count += 1;
    std.debug.print("  raw resize #{d}: {d}x{d}\n", .{ raw_resize_count, width, height });
    resize_debounce.trigger(.{ .w = width, .h = height });
}

fn frameCallback(frame: *const CapturedFrame, _: ?*anyopaque) void {
    if (!capture_next_frame) return;
    capture_next_frame = false;
    if (frame.fbo == 0) return;
    saveFboToPpm(frame.fbo, frame.width, frame.height) catch {};
}

fn saveFboToPpm(fbo: u32, width: u32, height: u32) !void {
    const size = @as(usize, width) * @as(usize, height) * 4;
    const pixels = std.heap.c_allocator.alloc(u8, size) catch return error.OutOfMemory;
    defer std.heap.c_allocator.free(pixels);

    c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
    c.glReadPixels(0, 0, @intCast(width), @intCast(height), c.GL_RGBA, c.GL_UNSIGNED_BYTE, pixels.ptr);
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);

    frames_captured += 1;
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/tmp/compositor-resize-{d}_{d}x{d}.ppm", .{
        frames_captured, width, height,
    }) catch return;

    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();

    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ width, height }) catch return;
    file.writeAll(header) catch return;

    var row_buf = std.heap.c_allocator.alloc(u8, @as(usize, width) * 3) catch return;
    defer std.heap.c_allocator.free(row_buf);

    var y: usize = height;
    while (y > 0) {
        y -= 1;
        const row_start = y * @as(usize, width) * 4;
        for (0..width) |x| {
            const src = row_start + x * 4;
            row_buf[x * 3 + 0] = pixels[src + 0];
            row_buf[x * 3 + 1] = pixels[src + 1];
            row_buf[x * 3 + 2] = pixels[src + 2];
        }
        file.writeAll(row_buf) catch return;
    }

    std.debug.print("  screenshot saved: {s}\n", .{path});
}

fn launchApp(command: []const u8, socket: [*:0]const u8) !posix.pid_t {
    const pid = posix.fork() catch return error.ForkFailed;
    if (pid == 0) {
        _ = c.setenv("WAYLAND_DISPLAY", socket, 1);
        _ = c.setenv("GDK_BACKEND", "wayland", 1);
        _ = c.setenv("QT_QPA_PLATFORM", "wayland", 1);
        _ = c.unsetenv("DISPLAY");

        const devnull = posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch posix.exit(127);
        posix.dup2(devnull, 1) catch {};
        posix.dup2(devnull, 2) catch {};

        var cmd_z: [513]u8 = undefined;
        @memcpy(cmd_z[0..command.len], command);
        cmd_z[command.len] = 0;

        const argv = [_:null]?[*:0]const u8{
            "/bin/sh",
            "-c",
            @ptrCast(cmd_z[0..command.len :0]),
        };
        posix.execveZ("/bin/sh", &argv, @ptrCast(std.c.environ)) catch {};
        posix.exit(127);
    }
    return pid;
}

test "app launch triggers exactly one debounced resize" {
    // Reset test state
    resize_count = 0;
    raw_resize_count = 0;
    frames_captured = 0;
    capture_next_frame = false;
    debounce_clock = .{};
    resize_debounce = Debounce(ResizeArgs).init(recordResize, null, debounce_clock.clock(), 250 * ms);

    const session_id = "test000000000000";

    var comp = Compositor.init(1920, 1080, 30, null, session_id) catch |err| {
        std.debug.print("compositor init failed (no GPU?): {}\n", .{err});
        return error.SkipZigTest;
    };
    defer comp.deinit();

    comp.resize_callback = rawResizeCallback;
    comp.frame_callback = frameCallback;

    const socket = comp.socketName();
    std.debug.print("compositor ready on {s}\n", .{std.mem.span(socket)});

    const pid = try launchApp("gnome-calculator", socket);
    defer {
        posix.kill(pid, posix.SIG.TERM) catch {};
        _ = posix.waitpid(pid, 0);
    }

    // Phase 1: dispatch until we get raw resizes, then wait for them to settle.
    // wlroots runs in real time — we just need the app to map and commit.
    var frames_since_last_raw: u32 = 0;
    const settle_frames: u32 = 30; // ~1 second of no raw resizes = settled
    const max_dispatch: u32 = 600; // ~20 second timeout
    var dispatches: u32 = 0;

    while (dispatches < max_dispatch) : (dispatches += 1) {
        const before = raw_resize_count;
        comp.dispatch(100);

        if (raw_resize_count > before) {
            frames_since_last_raw = 0; // reset settle counter
        } else if (raw_resize_count > 0) {
            frames_since_last_raw += 1;
            if (frames_since_last_raw >= settle_frames) break;
        }
    }

    std.debug.print("raw resizes settled: {d} events in {d} dispatches\n", .{ raw_resize_count, dispatches });

    // Phase 2: debounce hasn't fired yet (stopped clock is at 0).
    // Verify no premature firing.
    try std.testing.expect(!resize_debounce.tick());
    try std.testing.expectEqual(@as(usize, 0), resize_count);

    // Phase 3: advance the stopped clock past the debounce delay.
    debounce_clock.advance(250 * ms);

    // Tick the debounce — it should fire exactly once with the last args.
    // Dispatch one more frame so the screenshot captures the final state.
    try std.testing.expect(resize_debounce.tick());
    comp.dispatch(100);

    std.debug.print("test complete: {d} raw resizes, {d} debounced resizes, {d} screenshots\n", .{
        raw_resize_count, resize_count, frames_captured,
    });
    for (resize_events[0..resize_count], 0..) |evt, i| {
        std.debug.print("  event {d}: {d}x{d}\n", .{ i + 1, evt.width, evt.height });
    }

    // Assertions
    try std.testing.expect(raw_resize_count >= 2); // GTK fires at least 2 raw resizes
    try std.testing.expectEqual(@as(usize, 1), resize_count); // debounce coalesces to 1
    try std.testing.expectEqual(@as(u32, 486), resize_events[0].height); // settled on final size
}
