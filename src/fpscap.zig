// fpscap.zig — LD_PRELOAD frame rate cap for OpenGL apps on headless displays.
// Hooks glXSwapBuffers to insert a clock_nanosleep, capping frame rate to $FPS.
// Without hardware vsync (UseDisplayDevice "none"), OpenGL apps spin at 100% CPU.
// This provides software-based frame pacing via wall clock timing.

const std = @import("std");
const c = @cImport(@cInclude("dlfcn.h"));

const ns_per_s = std.time.ns_per_s;

var target_ns: i128 = 33_333_333; // default 30fps
var last: std.time.Instant = undefined;
var initialized = false;

fn init() void {
    if (initialized) return;
    initialized = true;
    if (std.posix.getenv("FPS")) |fps| {
        const f = std.fmt.parseInt(u32, fps, 10) catch 0;
        if (f > 0) target_ns = @divTrunc(ns_per_s, f);
    }
    last = std.time.Instant.now() catch unreachable;
}

const SwapBuffersFn = *const fn (?*anyopaque, c_ulong) callconv(.c) void;

export fn glXSwapBuffers(dpy: ?*anyopaque, drawable: c_ulong) callconv(.c) void {
    init();

    const real: SwapBuffersFn = @ptrCast(c.dlsym(c.RTLD_NEXT, "glXSwapBuffers") orelse unreachable);

    const now = std.time.Instant.now() catch unreachable;
    const elapsed: i128 = @intCast(now.since(last));

    if (elapsed < target_ns) {
        std.Thread.sleep(@intCast(target_ns - elapsed));
    }

    last = std.time.Instant.now() catch unreachable;
    real(dpy, drawable);
}
