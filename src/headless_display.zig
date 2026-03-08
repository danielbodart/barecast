const std = @import("std");
const posix = std.posix;
const libc = @cImport({
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});

const log = std.log.scoped(.headless);

/// Manages a headless Xorg display for app sharing.
/// Generates a temp xorg.conf, spawns the zerocast-xorg helper,
/// and sets the resolution via xrandr.
/// All process management runs unprivileged — only the helper is setuid.
pub const HeadlessDisplay = struct {
    display_num: u8,
    display_env: [16]u8,
    display_env_len: usize,
    xorg_pid: ?posix.pid_t,
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
    };

    /// Start a headless display at the given resolution.
    /// Blocks until the display is ready.
    pub fn start(width: u32, height: u32) InitError!HeadlessDisplay {
        var self: HeadlessDisplay = undefined;
        self.width = width;
        self.height = height;
        self.xorg_pid = null;

        // Generate temp xorg.conf
        self.writeConfig() catch return error.ConfigWriteFailed;

        // Spawn zerocast-xorg helper
        self.spawnXorg() catch return error.HelperFailed;

        // Set resolution via xrandr
        self.setResolution() catch |err| {
            log.warn("xrandr --fb failed: {}, display may be at default resolution", .{err});
        };

        log.info("headless display :{d} ready ({d}x{d})", .{ self.display_num, width, height });
        return self;
    }

    /// Get the DISPLAY environment variable value (e.g. ":10").
    pub fn displayEnv(self: *const HeadlessDisplay) []const u8 {
        return self.display_env[0..self.display_env_len];
    }

    /// Resize the display via xrandr.
    pub fn resize(self: *HeadlessDisplay, width: u32, height: u32) void {
        self.width = width;
        self.height = height;
        self.setResolution() catch |err| {
            log.warn("resize failed: {}", .{err});
        };
    }

    /// Stop the headless display and clean up all processes.
    pub fn stop(self: *HeadlessDisplay) void {
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
            \\    InputDevice "Pointer0" "CorePointer"
            \\    InputDevice "Keyboard0" "CoreKeyboard"
            \\EndSection
            \\
            \\Section "ServerFlags"
            \\    Option "AllowMouseOpenFail" "true"
            \\    Option "AllowEmptyInput" "true"
            \\    Option "AutoAddDevices" "false"
            \\EndSection
            \\
            \\Section "Files"
            \\    FontPath "/usr/share/fonts/X11/misc"
            \\    FontPath "built-ins"
            \\EndSection
            \\
            \\Section "InputDevice"
            \\    Identifier "Pointer0"
            \\    Driver "void"
            \\EndSection
            \\
            \\Section "InputDevice"
            \\    Identifier "Keyboard0"
            \\    Driver "void"
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

        const display_num = findFreeDisplay() orelse return error.HelperFailed;
        self.display_num = display_num;

        const env = std.fmt.bufPrint(&self.display_env, ":{d}", .{display_num}) catch return error.HelperFailed;
        self.display_env_len = env.len;

        var display_arg: [4]u8 = undefined;
        const display_str = std.fmt.bufPrint(&display_arg, "{d}", .{display_num}) catch return error.HelperFailed;
        display_arg[display_str.len] = 0;

        const config_z = self.configPathZ();
        const argv = [_:null]?[*:0]const u8{
            helper_path,
            config_z,
            @ptrCast(display_arg[0..display_str.len :0]),
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
        self.waitForReady(pid, display_num) catch return error.HelperFailed;
    }

    fn waitForReady(_: *HeadlessDisplay, pid: posix.pid_t, display_num: u8) !void {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/tmp/.X11-unix/X{d}", .{display_num}) catch return error.HelperFailed;
        path_buf[path.len] = 0;

        for (0..150) |_| {
            std.Thread.sleep(100 * std.time.ns_per_ms);

            const wr = posix.waitpid(pid, posix.W.NOHANG);
            if (wr.pid != 0) return error.HelperFailed;

            if (std.c.access(@ptrCast(path_buf[0..path.len :0]), 0) == 0) {
                return;
            }
        }
        return error.HelperFailed;
    }

    fn findFreeDisplay() ?u8 {
        for (10..100) |d| {
            var socket_buf: [32]u8 = undefined;
            const socket_path = std.fmt.bufPrint(&socket_buf, "/tmp/.X11-unix/X{d}", .{d}) catch continue;
            socket_buf[socket_path.len] = 0;
            if (std.c.access(@ptrCast(socket_buf[0..socket_path.len :0]), 0) != 0) {
                return @intCast(d);
            }
            if (isDisplayStale(d)) {
                log.info("cleaning up stale display :{d}", .{d});
                cleanupDisplay(d);
                return @intCast(d);
            }
        }
        return null;
    }

    fn isDisplayStale(display: usize) bool {
        var lock_buf: [32]u8 = undefined;
        const lock_path = std.fmt.bufPrint(&lock_buf, "/tmp/.X{d}-lock", .{display}) catch return false;

        const file = std.fs.openFileAbsolute(lock_path, .{}) catch return false;
        defer file.close();

        var pid_buf: [16]u8 = undefined;
        const n = file.read(&pid_buf) catch return false;
        const pid_str = std.mem.trim(u8, pid_buf[0..n], " \n\r");
        const pid = std.fmt.parseInt(posix.pid_t, pid_str, 10) catch return false;

        posix.kill(pid, 0) catch |err| {
            if (err == error.ProcessNotFound) return true;
        };
        return false;
    }

    fn cleanupDisplay(display: usize) void {
        var lock_buf: [32]u8 = undefined;
        if (std.fmt.bufPrint(&lock_buf, "/tmp/.X{d}-lock", .{display})) |path| {
            std.fs.cwd().deleteFile(path) catch {};
        } else |_| {}

        var socket_buf: [32]u8 = undefined;
        if (std.fmt.bufPrint(&socket_buf, "/tmp/.X11-unix/X{d}", .{display})) |path| {
            std.fs.cwd().deleteFile(path) catch {};
        } else |_| {}
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
