const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const c = @cImport({
    if (builtin.os.tag == .macos) {
        @cInclude("util.h");
    } else {
        @cInclude("pty.h");
        @cInclude("utmp.h");
    }
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("signal.h");
    @cInclude("fcntl.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
});
const session_mod = @import("session");
const BroadcastSession = session_mod.BroadcastSession;
const SessionMode = session_mod.SessionMode;
const TerminalDataCallback = session_mod.TerminalDataCallback;
const writeJsonEscaped = session_mod.writeJsonEscaped;
const sendDcMessage = session_mod.sendDcMessage;
const OscParser = @import("osc_parser").OscParser;

const log = std.log.scoped(.terminal_share);

pub const TerminalShareConfig = struct {
    command: ?[]const u8 = null, // null = $SHELL
    record: bool = false,
    recordings_dir: []const u8 = "",
    width: u16 = 80,
    height: u16 = 24,
    base_url: []const u8 = "https://zerocast.bodar.com",
    room_id: ?[]const u8 = null, // null = auto-generate
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
    session: BroadcastSession,
    share_url_buf: [256]u8,
    share_url: []const u8,
    room_id_buf: [16]u8,
    room_id_len: usize,
    osc: OscParser,
    current_title: [200]u8,
    current_title_len: std.atomic.Value(u16),
    last_bytes_per_sec: u64,

    // Ring buffer for replay on viewer connect (256KB)
    replay_buf: [256 * 1024]u8,
    replay_pos: usize, // next write position (wraps)
    replay_len: usize, // total bytes stored (capped at buf size)
    replay_mutex: std.Thread.Mutex,

    /// Initialize in-place: fork a PTY, spawn shell/command, create BroadcastSession.
    /// MUST be called on a heap-allocated TerminalShare (pointers captured into session).
    pub fn initInPlace(self: *TerminalShare, config: TerminalShareConfig) !void {
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
            // Reset signal mask — the daemon may have blocked signals
            var empty_set: c.sigset_t = undefined;
            _ = c.sigemptyset(&empty_set);
            _ = c.sigprocmask(c.SIG_SETMASK, &empty_set, null);
            // Ensure TERM is set
            _ = c.setenv("TERM", "xterm-256color", 1);
            const shell = getShell();
            const null_ptr: [*c]const u8 = @ptrFromInt(0);
            if (config.command) |cmd| {
                // Run specific command via shell -c
                var cmd_z: [4096]u8 = undefined;
                if (cmd.len < cmd_z.len) {
                    @memcpy(cmd_z[0..cmd.len], cmd);
                    cmd_z[cmd.len] = 0;
                    const cmd_ptr: [*c]const u8 = &cmd_z;
                    _ = c.execlp(shell, shell, @as([*c]const u8, "-c"), cmd_ptr, null_ptr);
                }
            } else {
                // Interactive shell
                _ = c.execlp(shell, shell, null_ptr);
            }
            // If exec fails, exit child
            c._exit(127);
        }

        // Parent process
        self.master_fd = master_fd;
        self.child_pid = pid;
        self.should_stop = std.atomic.Value(bool).init(false);
        self.start_time = try std.time.Timer.start();
        self.config = config;
        self.recording = null;
        self.share_url_buf = undefined;
        self.share_url = "";
        self.osc = OscParser{};
        self.current_title = std.mem.zeroes([200]u8);
        self.current_title_len = std.atomic.Value(u16).init(0);
        self.last_bytes_per_sec = 0;
        self.replay_buf = undefined;
        self.replay_pos = 0;
        self.replay_len = 0;
        self.replay_mutex = .{};

        // Generate session ID
        std.crypto.random.bytes(&self.session_id);
        const charset = "0123456789abcdef";
        var hex: [16]u8 = undefined;
        for (self.session_id[0..8], 0..) |b, i| {
            hex[i * 2] = charset[b >> 4];
            hex[i * 2 + 1] = charset[b & 0x0f];
        }
        self.session_id = hex;

        // Generate room ID
        if (config.room_id) |rid| {
            if (rid.len > self.room_id_buf.len) return error.RoomIdTooLong;
            @memcpy(self.room_id_buf[0..rid.len], rid);
            self.room_id_len = rid.len;
        } else {
            self.room_id_buf = self.session_id;
            self.room_id_len = 16;
        }

        // Build signaling URL
        const base_url = config.base_url;
        const host_start = if (std.mem.indexOf(u8, base_url, "://")) |i| i + 3 else 0;
        const ws_scheme = if (std.mem.startsWith(u8, base_url, "http:")) "ws://" else "wss://";

        var signaling_buf: [256]u8 = undefined;
        const signaling_url = std.fmt.bufPrint(&signaling_buf, "{s}{s}", .{
            ws_scheme, base_url[host_start..],
        }) catch return error.UrlTooLong;

        // Share URL for CLI output
        const room_id = self.room_id_buf[0..self.room_id_len];
        self.share_url = std.fmt.bufPrint(&self.share_url_buf, "{s}/room/{s}", .{
            base_url, room_id,
        }) catch "https://zerocast.bodar.com/room/???";

        log.info("room: {s}", .{self.share_url});

        // Broadcast session (terminal mode — data channel only, no video track)
        self.session = BroadcastSession.init(signaling_url, room_id, &self.session_id, "terminal", .terminal) catch |err| {
            log.err("session init failed: {}", .{err});
            posix.close(master_fd);
            return error.SessionInitFailed;
        };

        // Wire terminal data callback — viewer input → PTY, replay on connect
        self.session.terminal_callback = .{
            .ptr = @ptrCast(self),
            .onData = termOnData,
            .onResize = termOnResize,
            .onPeerConnected = termOnPeerConnected,
        };

        self.session.meta_callback = terminalMetaCallback;

        // Start recording if requested
        if (config.record) {
            self.recording = AsciinemaWriter.init(config, self.start_time) catch |err| blk: {
                log.warn("recording init failed: {}", .{err});
                break :blk null;
            };
        }
    }

    fn termOnData(ptr: *anyopaque, data: []const u8) void {
        const self: *TerminalShare = @alignCast(@ptrCast(ptr));
        self.writeInput(data);
    }

    fn termOnResize(ptr: *anyopaque, cols: u16, rows: u16) void {
        const self: *TerminalShare = @alignCast(@ptrCast(ptr));
        self.resize(cols, rows);
    }

    fn termOnPeerConnected(ptr: *anyopaque, dc: c_int) void {
        const self: *TerminalShare = @alignCast(@ptrCast(ptr));
        self.sendReplay(dc);
    }

    fn sendTerminalMeta(self: *TerminalShare) void {
        const title_len = self.current_title_len.load(.acquire);
        const title = self.current_title[0..title_len];

        // Get current terminal size via ioctl
        var ws: c.struct_winsize = undefined;
        _ = c.ioctl(self.master_fd, c.TIOCGWINSZ, &ws);

        var meta_buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&meta_buf);
        const w = fbs.writer();
        w.writeAll("{\"type\":\"set-meta\",\"title\":\"") catch return;
        writeJsonEscaped(w, title) catch return;
        std.fmt.format(w, "\",\"cols\":{d},\"rows\":{d},\"bytes_per_sec\":{d}}}", .{
            ws.ws_col, ws.ws_row, self.last_bytes_per_sec,
        }) catch return;
        self.session.sendMeta(fbs.getWritten());
    }

    /// Append data to the replay ring buffer.
    fn appendReplay(self: *TerminalShare, data: []const u8) void {
        self.replay_mutex.lock();
        defer self.replay_mutex.unlock();

        const cap = self.replay_buf.len;
        if (data.len >= cap) {
            // Data larger than buffer — just keep the tail
            @memcpy(&self.replay_buf, data[data.len - cap ..]);
            self.replay_pos = 0;
            self.replay_len = cap;
            return;
        }

        const first = @min(data.len, cap - self.replay_pos);
        @memcpy(self.replay_buf[self.replay_pos..][0..first], data[0..first]);
        if (first < data.len) {
            @memcpy(self.replay_buf[0 .. data.len - first], data[first..]);
        }
        self.replay_pos = (self.replay_pos + data.len) % cap;
        self.replay_len = @min(self.replay_len + data.len, cap);
    }

    /// Send buffered replay data to a specific peer's data channel.
    fn sendReplay(self: *TerminalShare, dc: c_int) void {
        self.replay_mutex.lock();
        defer self.replay_mutex.unlock();

        if (self.replay_len == 0) return;

        const cap = self.replay_buf.len;
        if (self.replay_len < cap) {
            // No wrap — data is contiguous from 0..replay_len
            sendDcMessage(dc, self.replay_buf[0..self.replay_len]);
        } else {
            // Wrapped — send oldest chunk first, then newest
            const oldest = self.replay_pos; // oldest data starts here
            sendDcMessage(dc, self.replay_buf[oldest..]);
            if (oldest > 0) {
                sendDcMessage(dc, self.replay_buf[0..oldest]);
            }
        }
    }

    /// Register signaling WebSocket callbacks. MUST be called after initInPlace.
    pub fn start(self: *TerminalShare) void {
        self.session.start();
    }

    /// Run the terminal output read loop. Reads from master_fd and sends to viewers.
    pub fn runLoop(self: *TerminalShare) void {
        var buf: [4096]u8 = undefined;

        // Set master_fd non-blocking for poll
        const O_NONBLOCK: usize = c.O_NONBLOCK;
        const flags = posix.fcntl(self.master_fd, posix.F.GETFL, @as(usize, 0)) catch return;
        _ = posix.fcntl(self.master_fd, posix.F.SETFL, flags | O_NONBLOCK) catch return;

        const meta_interval_ns: u64 = 5 * std.time.ns_per_s;
        var meta_timer = std.time.Timer.start() catch return;
        var prev_bytes: u64 = 0;

        // Send initial meta
        self.sendTerminalMeta();

        while (!self.should_stop.load(.acquire)) {
            // Poll with 100ms timeout
            var fds = [_]posix.pollfd{.{
                .fd = self.master_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};

            const ready = posix.poll(&fds, 100) catch break;
            if (ready == 0) continue;

            if (meta_timer.read() >= meta_interval_ns) {
                const elapsed_ns = meta_timer.read();
                meta_timer.reset();

                const cur_bytes = self.session.bytes_sent.load(.monotonic);
                const delta_bytes = cur_bytes - prev_bytes;
                prev_bytes = cur_bytes;

                const elapsed_s = elapsed_ns / std.time.ns_per_s;
                self.last_bytes_per_sec = if (elapsed_s > 0) delta_bytes / elapsed_s else 0;

                self.sendTerminalMeta();
            }

            // Check POLLIN before POLLHUP — on child exit, both may be set
            // and we want to read any remaining output first.
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

                // Parse for terminal title changes (OSC 0/2)
                if (self.osc.feed(data)) |new_title| {
                    const old_len = self.current_title_len.load(.acquire);
                    const old = self.current_title[0..old_len];
                    if (!std.mem.eql(u8, old, new_title)) {
                        @memcpy(self.current_title[0..new_title.len], new_title);
                        self.current_title_len.store(@intCast(new_title.len), .release);
                        self.sendTerminalMeta();
                        log.info("title: {s}", .{new_title});
                    }
                }

                // Buffer for replay and send to viewers
                self.appendReplay(data);
                self.session.sendData(data);

                // Record if enabled
                if (self.recording) |*rec| {
                    rec.writeOutput(data) catch {};
                }
            } else if (fds[0].revents & posix.POLL.HUP != 0) {
                log.info("child exited (HUP)", .{});
                break;
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

    /// Get the current terminal title (thread-safe read).
    pub fn currentTitle(self: *TerminalShare) []const u8 {
        const len = self.current_title_len.load(.acquire);
        return self.current_title[0..len];
    }

    /// Get number of connected viewers.
    pub fn viewerCount(self: *TerminalShare) u32 {
        var count: u32 = 0;
        self.session.peers_mutex.lock();
        defer self.session.peers_mutex.unlock();
        for (&self.session.peers) |*peer| {
            if (peer.state.load(.acquire) == .connected) count += 1;
        }
        return count;
    }

    /// Get uptime in seconds.
    pub fn uptimeSeconds(self: *TerminalShare) u64 {
        return self.start_time.read() / std.time.ns_per_s;
    }

    pub fn deinit(self: *TerminalShare) void {
        // Clean up WebRTC session
        self.session.deinit();

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

fn terminalMetaCallback(session: *BroadcastSession) void {
    const self: *TerminalShare = @fieldParentPtr("session", session);
    self.sendTerminalMeta();
}

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
    const shell_env = c.getenv("SHELL");
    if (shell_env != null) return shell_env;
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
