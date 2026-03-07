const std = @import("std");
const posix = std.posix;
const libc = @cImport({
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});

const log = std.log.scoped(.headless);

/// Manages a headless Xorg display for app sharing.
/// Generates a temp xorg.conf, spawns the zerocast-xorg helper,
/// starts picom compositor, and sets the resolution via xrandr.
/// All process management runs unprivileged — only the helper is setuid.
pub const HeadlessDisplay = struct {
    display_num: u8,
    display_env: [16]u8,
    display_env_len: usize,
    xorg_pid: ?posix.pid_t,
    picom_pid: ?posix.pid_t,
    config_path: [128]u8,
    config_path_len: usize,
    width: u32,
    height: u32,

    const xorg_helper_paths = [_][*:0]const u8{
        "/usr/local/bin/zerocast-xorg",
    };

    pub const InitError = error{
        ConfigWriteFailed,
        HelperNotFound,
        HelperFailed,
        XrandrFailed,
        PicomFailed,
    };

    /// Start a headless display at the given resolution.
    /// Blocks until the display is ready.
    pub fn start(width: u32, height: u32) InitError!HeadlessDisplay {
        var self: HeadlessDisplay = undefined;
        self.width = width;
        self.height = height;
        self.xorg_pid = null;
        self.picom_pid = null;

        // Generate temp xorg.conf
        self.writeConfig() catch return error.ConfigWriteFailed;

        // Spawn zerocast-xorg helper
        self.spawnXorg() catch return error.HelperFailed;

        // Set resolution via xrandr
        self.setResolution() catch |err| {
            log.warn("xrandr --fb failed: {}, display may be at default resolution", .{err});
        };

        // Start picom compositor (enables NvFBC diff map for idle detection)
        self.spawnPicom() catch |err| {
            log.warn("picom failed to start: {}, NvFBC diff map may not work", .{err});
        };

        log.info("headless display :{d} ready ({d}x{d})", .{ self.display_num, width, height });
        return self;
    }

    /// Get the DISPLAY environment variable value (e.g. ":10").
    pub fn displayEnv(self: *const HeadlessDisplay) []const u8 {
        return self.display_env[0..self.display_env_len];
    }

    /// Resize the display (called when viewer resizes).
    /// After xrandr, picom must be restarted — xrandr invalidates picom's
    /// compositing state, which breaks NvFBC's push model damage subscription.
    pub fn resize(self: *HeadlessDisplay, width: u32, height: u32) void {
        self.width = width;
        self.height = height;
        self.setResolution() catch |err| {
            log.warn("resize failed: {}", .{err});
            return;
        };
        self.restartPicom();
    }

    fn restartPicom(self: *HeadlessDisplay) void {
        if (self.picom_pid) |pid| {
            posix.kill(pid, posix.SIG.TERM) catch {};
            _ = posix.waitpid(pid, 0);
            self.picom_pid = null;
        }
        self.spawnPicom() catch |err| {
            log.warn("picom restart failed: {}", .{err});
        };
    }

    /// Stop the headless display and clean up all processes.
    pub fn stop(self: *HeadlessDisplay) void {
        if (self.picom_pid) |pid| {
            posix.kill(pid, posix.SIG.TERM) catch {};
            _ = posix.waitpid(pid, 0);
            self.picom_pid = null;
        }
        if (self.xorg_pid) |pid| {
            posix.kill(pid, posix.SIG.TERM) catch {};
            _ = posix.waitpid(pid, 0);
            self.xorg_pid = null;
        }
        // Clean up temp config
        const path = self.config_path[0..self.config_path_len];
        std.fs.cwd().deleteFile(path) catch {};
        log.info("headless display :{d} stopped", .{self.display_num});
    }

    // ── Internal ──────────────────────────────────────────────────────

    fn writeConfig(self: *HeadlessDisplay) !void {
        const config =
            \\Section "ServerLayout"
            \\    Identifier "Layout0"
            \\    Screen 0 "Screen0"
            \\EndSection
            \\
            \\Section "ServerFlags"
            \\    Option "AllowMouseOpenFail" "true"
            \\    Option "AllowEmptyInput" "true"
            \\EndSection
            \\
            \\Section "Device"
            \\    Identifier "Device0"
            \\    Driver "nvidia"
            \\    Option "AllowEmptyInitialConfiguration" "true"
            \\    Option "UseDisplayDevice" "none"
            \\    Option "HardDPMS" "false"
            \\EndSection
            \\
            \\Section "Screen"
            \\    Identifier "Screen0"
            \\    Device "Device0"
            \\    DefaultDepth 24
            \\EndSection
            \\
        ;

        // Write to /tmp/zerocast-xorg-<pid>.conf
        const pid = std.os.linux.getpid();
        const path = std.fmt.bufPrint(&self.config_path, "/tmp/zerocast-xorg-{d}.conf", .{pid}) catch return error.ConfigWriteFailed;
        self.config_path_len = path.len;

        const file = std.fs.cwd().createFile(path, .{}) catch return error.ConfigWriteFailed;
        defer file.close();
        file.writeAll(config) catch return error.ConfigWriteFailed;
    }

    fn spawnXorg(self: *HeadlessDisplay) !void {
        const helper_path = findHelper() orelse return error.HelperNotFound;

        const config_z = self.configPathZ();
        const argv = [_:null]?[*:0]const u8{
            helper_path,
            config_z,
        };

        const pid = posix.fork() catch return error.HelperFailed;

        if (pid == 0) {
            // Child: exec the helper
            posix.execveZ(
                helper_path,
                &argv,
                @ptrCast(std.c.environ),
            ) catch {};
            posix.exit(127);
        }

        self.xorg_pid = pid;

        // Wait for the helper to report the display number via stdout
        // The helper writes "<display_num>\n" when ready
        // For now, poll for the socket file
        const display_num = self.waitForHelperReady(pid) catch return error.HelperFailed;
        self.display_num = display_num;

        const env = std.fmt.bufPrint(&self.display_env, ":{d}", .{display_num}) catch return error.HelperFailed;
        self.display_env_len = env.len;
    }

    fn waitForHelperReady(self: *HeadlessDisplay, pid: posix.pid_t) !u8 {
        _ = self;

        // The helper finds a free display and starts Xorg on it.
        // Wait for ANY new socket in /tmp/.X11-unix/ (range :10-:99).
        // Record which sockets exist before we started.
        var existing = [_]bool{false} ** 100;
        for (10..100) |d| {
            var path_buf: [32]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/tmp/.X11-unix/X{d}", .{d}) catch continue;
            path_buf[path.len] = 0;
            if (std.c.access(@ptrCast(path.ptr), 0) == 0) {
                existing[d] = true;
            }
        }

        // Poll for a NEW socket (up to 15 seconds)
        for (0..150) |_| {
            std.Thread.sleep(100 * std.time.ns_per_ms);

            // Check if helper exited prematurely
            const wr = posix.waitpid(pid, posix.W.NOHANG);
            if (wr.pid != 0) return error.HelperFailed;

            for (10..100) |d| {
                if (existing[d]) continue;
                var path_buf: [32]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buf, "/tmp/.X11-unix/X{d}", .{d}) catch continue;
                path_buf[path.len] = 0;
                if (std.c.access(@ptrCast(path.ptr), 0) == 0) {
                    return @intCast(d);
                }
            }
        }
        return error.HelperFailed;
    }

    fn setResolution(self: *HeadlessDisplay) !void {
        var display_z: [16]u8 = undefined;
        const env = std.fmt.bufPrint(&display_z, ":{d}", .{self.display_num}) catch return error.XrandrFailed;
        display_z[env.len] = 0;

        var res_buf: [16]u8 = undefined;
        const res = std.fmt.bufPrint(&res_buf, "{d}x{d}", .{ self.width, self.height }) catch return error.XrandrFailed;
        res_buf[res.len] = 0;

        const pid = posix.fork() catch return error.XrandrFailed;
        if (pid == 0) {
            _ = libc.setenv("DISPLAY", @ptrCast(display_z[0..env.len :0]), 1);
            const argv = [_:null]?[*:0]const u8{
                "xrandr",
                "--fb",
                @ptrCast(res_buf[0..res.len :0]),
            };
            _ = libc.execvp("xrandr", @ptrCast(&argv));
            posix.exit(127);
        }
        _ = posix.waitpid(pid, 0);
    }

    fn spawnPicom(self: *HeadlessDisplay) !void {
        const pid = posix.fork() catch return error.PicomFailed;
        if (pid == 0) {
            // Set DISPLAY
            var display_z: [16]u8 = undefined;
            const env = std.fmt.bufPrint(&display_z, ":{d}", .{self.display_num}) catch posix.exit(127);
            display_z[env.len] = 0;
            _ = libc.setenv("DISPLAY", @ptrCast(display_z[0..env.len :0]), 1);

            // Redirect stdout/stderr to /dev/null
            const devnull = posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch posix.exit(127);
            posix.dup2(devnull, 1) catch {};
            posix.dup2(devnull, 2) catch {};

            const argv = [_:null]?[*:0]const u8{
                "picom",
                "--backend",
                "glx",
            };
            _ = libc.execvp("picom", @ptrCast(&argv));
            posix.exit(127);
        }
        self.picom_pid = pid;
        // Give picom a moment to initialize
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }

    fn configPathZ(self: *HeadlessDisplay) [*:0]const u8 {
        self.config_path[self.config_path_len] = 0;
        return @ptrCast(self.config_path[0..self.config_path_len :0]);
    }

    fn findHelper() ?[*:0]const u8 {
        for (xorg_helper_paths) |path| {
            if (std.c.access(path, 1) == 0) { // 1 = X_OK
                return path;
            }
        }
        return null;
    }
};
