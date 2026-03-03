const std = @import("std");
const posix = std.posix;
const c = @cImport({
    @cInclude("pty.h");
    @cInclude("utmp.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("signal.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
});

const log = std.log.scoped(.terminal_share);

pub const TerminalShareConfig = struct {
    command: ?[]const u8 = null, // null = $SHELL
    record: bool = false,
    recordings_dir: []const u8 = "",
    width: u16 = 80,
    height: u16 = 24,
};

/// Self-contained terminal share session. Spawns a PTY, streams output
/// via a WebRTC data channel, and optionally records to asciinema v2 format.
pub const TerminalShare = struct {
    session_id: [16]u8,
    master_fd: posix.fd_t,
    child_pid: c.pid_t,
    should_stop: std.atomic.Value(bool),
    start_time: std.time.Timer,
    config: TerminalShareConfig,
    recording: ?AsciinemaWriter,

    // Callback for sending output to viewers
    output_callback: ?*const fn (data: []const u8, ctx: *anyopaque) void = null,
    output_ctx: ?*anyopaque = null,

    /// Initialize: fork a PTY, spawn shell/command.
    pub fn init(config: TerminalShareConfig) !TerminalShare {
        var master_fd: c_int = undefined;
        var ws: c.struct_winsize = .{
            .ws_col = config.width,
            .ws_row = config.height,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        const pid = c.forkpty(&master_fd, null, null, &ws);
        if (pid < 0) return error.ForkPtyFailed;

        if (pid == 0) {
            // Child process — exec shell or command
            const shell = getShell();
            if (config.command) |cmd| {
                // Run specific command via shell -c
                var cmd_z: [4096]u8 = undefined;
                if (cmd.len < cmd_z.len) {
                    @memcpy(cmd_z[0..cmd.len], cmd);
                    cmd_z[cmd.len] = 0;
                    const cmd_ptr: [*c]const u8 = &cmd_z;
                    const dash_c: [*c]const u8 = "-c";
                    const argv = [_:null]?[*c]const u8{ shell, dash_c, cmd_ptr, null };
                    _ = c.execvp(shell, @ptrCast(&argv));
                }
            } else {
                // Interactive shell
                const argv = [_:null]?[*c]const u8{ shell, null };
                _ = c.execvp(shell, @ptrCast(&argv));
            }
            // If exec fails, exit child
            c._exit(127);
        }

        // Parent process
        var self = TerminalShare{
            .session_id = undefined,
            .master_fd = master_fd,
            .child_pid = pid,
            .should_stop = std.atomic.Value(bool).init(false),
            .start_time = try std.time.Timer.start(),
            .config = config,
            .recording = null,
        };

        // Generate session ID
        std.crypto.random.bytes(&self.session_id);
        const charset = "0123456789abcdef";
        var hex: [16]u8 = undefined;
        for (self.session_id[0..8], 0..) |b, i| {
            hex[i * 2] = charset[b >> 4];
            hex[i * 2 + 1] = charset[b & 0x0f];
        }
        self.session_id = hex;

        // Start recording if requested
        if (config.record) {
            self.recording = AsciinemaWriter.init(config, self.start_time) catch |err| blk: {
                log.warn("recording init failed: {}", .{err});
                break :blk null;
            };
        }

        return self;
    }

    /// Run the terminal output read loop. Reads from master_fd and sends to viewers.
    pub fn runLoop(self: *TerminalShare) void {
        var buf: [4096]u8 = undefined;

        // Set master_fd non-blocking for poll
        const O_NONBLOCK: usize = 0o4000; // linux x86_64
        const flags = posix.fcntl(self.master_fd, posix.F.GETFL, @as(usize, 0)) catch return;
        _ = posix.fcntl(self.master_fd, posix.F.SETFL, flags | O_NONBLOCK) catch return;

        while (!self.should_stop.load(.acquire)) {
            // Poll with 100ms timeout
            var fds = [_]posix.pollfd{.{
                .fd = self.master_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};

            const ready = posix.poll(&fds, 100) catch break;
            if (ready == 0) continue;

            if (fds[0].revents & posix.POLL.HUP != 0) {
                log.info("child exited (HUP)", .{});
                break;
            }

            if (fds[0].revents & posix.POLL.IN != 0) {
                const n = posix.read(self.master_fd, &buf) catch |err| {
                    if (err == error.WouldBlock) continue;
                    log.info("master read ended: {}", .{err});
                    break;
                };
                if (n == 0) {
                    log.info("child exited (EOF)", .{});
                    break;
                }

                const data = buf[0..n];

                // Send to viewers
                if (self.output_callback) |cb| {
                    cb(data, self.output_ctx.?);
                }

                // Record if enabled
                if (self.recording) |*rec| {
                    rec.writeOutput(data) catch {};
                }
            }
        }

        log.info("terminal share stopped", .{});
    }

    /// Write input from a viewer to the PTY.
    pub fn writeInput(self: *TerminalShare, data: []const u8) void {
        _ = posix.write(self.master_fd, data) catch |err| {
            log.warn("write to PTY failed: {}", .{err});
        };
    }

    /// Resize the PTY.
    pub fn resize(self: *TerminalShare, cols: u16, rows: u16) void {
        const ws = c.struct_winsize{
            .ws_col = cols,
            .ws_row = rows,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = c.ioctl(self.master_fd, c.TIOCSWINSZ, &ws);

        // Record resize event
        if (self.recording) |*rec| {
            rec.writeResize(cols, rows) catch {};
        }
    }

    /// Get uptime in seconds.
    pub fn uptimeSeconds(self: *TerminalShare) u64 {
        return self.start_time.read() / std.time.ns_per_s;
    }

    pub fn deinit(self: *TerminalShare) void {
        // Signal child to exit
        _ = c.kill(self.child_pid, c.SIGTERM);

        // Wait for child with timeout (non-blocking waitpid + sleep)
        var status: c_int = 0;
        const result = c.waitpid(self.child_pid, &status, c.WNOHANG);
        if (result == 0) {
            // Child still running — give it a moment
            std.Thread.sleep(100 * std.time.ns_per_ms);
            _ = c.waitpid(self.child_pid, &status, c.WNOHANG);
        }

        posix.close(self.master_fd);

        if (self.recording) |*rec| {
            rec.deinit();
        }
    }
};

// ── Asciinema v2 recording ──────────────────────────────────────────────

const AsciinemaWriter = struct {
    file: std.fs.File,
    start_time: std.time.Timer,

    fn init(config: TerminalShareConfig, timer: std.time.Timer) !AsciinemaWriter {
        const allocator = std.heap.c_allocator;

        const recordings_dir = if (config.recordings_dir.len > 0)
            config.recordings_dir
        else
            getDefaultRecordingsDir(allocator) catch return error.NoRecordingsDir;

        std.fs.cwd().makePath(recordings_dir) catch return error.MakePath;

        var path_buf: [512]u8 = undefined;
        const now = std.time.timestamp();
        const path = std.fmt.bufPrint(&path_buf, "{s}/terminal-{d}.cast", .{
            recordings_dir, now,
        }) catch return error.PathTooLong;

        const file = std.fs.cwd().createFile(path, .{}) catch return error.CreateFile;
        log.info("recording to {s}", .{path});

        var self = AsciinemaWriter{
            .file = file,
            .start_time = timer,
        };

        // Write header
        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "{{\"version\":2,\"width\":{d},\"height\":{d},\"timestamp\":{d}}}\n", .{
            config.width, config.height, now,
        }) catch return error.Format;
        self.file.writeAll(header) catch return error.Write;

        return self;
    }

    fn writeOutput(self: *AsciinemaWriter, data: []const u8) !void {
        const elapsed_ns = self.start_time.read();
        const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));

        var line_buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&line_buf);
        const w = fbs.writer();

        try std.fmt.format(w, "[{d:.6},\"o\",\"", .{elapsed_s});
        // JSON-escape the data
        for (data) |ch| {
            switch (ch) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                else => {
                    if (ch < 0x20) {
                        try std.fmt.format(w, "\\u{X:0>4}", .{ch});
                    } else {
                        try w.writeByte(ch);
                    }
                },
            }
        }
        try w.writeAll("\"]\n");

        self.file.writeAll(fbs.getWritten()) catch {};
    }

    fn writeResize(self: *AsciinemaWriter, cols: u16, rows: u16) !void {
        const elapsed_ns = self.start_time.read();
        const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));

        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "[{d:.6},\"r\",\"{d}x{d}\"]\n", .{
            elapsed_s, cols, rows,
        }) catch return;

        self.file.writeAll(line) catch {};
    }

    fn deinit(self: *AsciinemaWriter) void {
        self.file.close();
    }
};

// ── Helpers ──────────────────────────────────────────────────────────────

fn getShell() [*c]const u8 {
    const shell_env = std.posix.getenv("SHELL");
    if (shell_env) |s| return s.ptr;
    return "/bin/sh";
}

fn getDefaultRecordingsDir(allocator: std.mem.Allocator) ![]const u8 {
    const data_home = std.process.getEnvVarOwned(allocator, "XDG_DATA_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => blk: {
            const home = try std.process.getEnvVarOwned(allocator, "HOME");
            defer allocator.free(home);
            break :blk try std.fmt.allocPrint(allocator, "{s}/.local/share", .{home});
        },
        else => return err,
    };
    defer allocator.free(data_home);
    return std.fmt.allocPrint(allocator, "{s}/zerocast/recordings", .{data_home});
}

// ── Tests ────────────────────────────────────────────────────────────────

test "getShell returns a path" {
    const shell = getShell();
    try std.testing.expect(shell[0] == '/');
}
