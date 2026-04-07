const std = @import("std");
const posix = std.posix;
const control = @import("control");
const AppShare = @import("app_share").AppShare;
const AppShareConfig = @import("app_share").AppShareConfig;
const WaylandAppShare = @import("app_share_vaapi").WaylandAppShare;
const WaylandAppShareConfig = @import("app_share_vaapi").AppShareConfig;
const gpu_detect = @import("gpu_detect");
const TerminalShare = @import("terminal_share").TerminalShare;
const TerminalShareConfig = @import("terminal_share").TerminalShareConfig;
const build_options = @import("build_options");

const log = std.log.scoped(.daemon);

pub const std_options: std.Options = .{
    .log_level = if (@import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe) .debug else .info,
};

var should_exit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// ── Session slots ────────────────────────────────────────────────────────

const MAX_SESSIONS = 8;

const SharePayload = union(enum) {
    terminal: *TerminalShare,
    app: *AppShare,
    wayland_app: *WaylandAppShare,
};

const SessionSlot = struct {
    payload: ?SharePayload = null,
    thread: ?std.Thread = null,
};

var sessions: [MAX_SESSIONS]SessionSlot = [_]SessionSlot{.{}} ** MAX_SESSIONS;
var sessions_mutex: std.Thread.Mutex = .{};

// ── Room state ──────────────────────────────────────────────────────────

var current_room_buf: [64]u8 = undefined;
var current_room_len: usize = 0;

fn currentRoom() ?[]const u8 {
    if (current_room_len == 0) return null;
    return current_room_buf[0..current_room_len];
}

fn setRoom(room: []const u8) void {
    const len = @min(room.len, current_room_buf.len);
    @memcpy(current_room_buf[0..len], room[0..len]);
    current_room_len = len;
}

fn clearRoom() void {
    current_room_len = 0;
}

/// Run the daemon: bind socket, accept connections, dispatch commands.
pub fn run() void {
    installSignalHandler();

    var sock_path_buf: [256]u8 = undefined;
    const sock_path = control.getSocketPath(&sock_path_buf) orelse {
        log.err("failed to determine socket path", .{});
        return;
    };

    // Check for existing daemon — connect and send a status request.
    // A successful response means the daemon is genuinely alive.
    // A connect failure or response timeout means the socket is stale.
    switch (checkExistingDaemon(sock_path)) {
        .alive => {
            log.err("daemon already running (socket responds at {s})", .{sock_path});
            return;
        },
        .stale => {
            log.info("removing stale socket at {s}", .{sock_path});
            std.fs.cwd().deleteFile(sock_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => {
                    log.err("failed to unlink stale socket: {}", .{err});
                    return;
                },
            };
        },
        .none => {},
    }

    const sock_path_z = toSockaddr(sock_path) orelse {
        log.err("socket path too long", .{});
        return;
    };

    // Create and bind the listener
    const listener = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0) catch |err| {
        log.err("socket(): {}", .{err});
        return;
    };
    defer posix.close(listener);

    posix.bind(listener, @ptrCast(&sock_path_z), @sizeOf(@TypeOf(sock_path_z))) catch |err| {
        log.err("bind({s}): {}", .{ sock_path, err });
        return;
    };

    // Cleanup socket file on exit
    defer std.fs.cwd().deleteFile(sock_path) catch {};

    posix.listen(listener, 5) catch |err| {
        log.err("listen(): {}", .{err});
        return;
    };

    log.info("daemon v{s} listening on {s}", .{ build_options.version, sock_path });

    // Main accept loop
    while (!should_exit.load(.acquire)) {
        // poll with 500ms timeout so we check should_exit periodically
        var fds = [_]posix.pollfd{.{
            .fd = listener,
            .events = posix.POLL.IN,
            .revents = 0,
        }};

        const ready = posix.poll(&fds, 500) catch |err| {
            log.err("poll(): {}", .{err});
            continue;
        };

        if (ready == 0) continue; // timeout

        if (fds[0].revents & posix.POLL.IN != 0) {
            const conn = posix.accept(listener, null, null, posix.SOCK.CLOEXEC) catch |err| {
                if (err == error.WouldBlock) continue;
                log.warn("accept(): {}", .{err});
                continue;
            };
            defer posix.close(conn);
            handleConnection(conn);
        }
    }

    // Stop all sessions on shutdown
    _ = stopAllSessions();
    log.info("daemon shutting down", .{});
}

fn handleConnection(fd: posix.fd_t) void {
    // Read one request (newline-delimited JSON, max 4KB)
    var read_buf: [4096]u8 = undefined;
    var total: usize = 0;

    // Set a read timeout so we don't block forever on a misbehaving client
    const timeout = posix.timeval{ .sec = 5, .usec = 0 };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

    while (total < read_buf.len) {
        const n = posix.read(fd, read_buf[total..]) catch |err| {
            log.warn("read(): {}", .{err});
            return;
        };
        if (n == 0) break;
        total += n;

        // Check for newline delimiter
        if (std.mem.indexOfScalar(u8, read_buf[0..total], '\n') != null) break;
    }

    if (total == 0) return;

    // Strip trailing newline
    const msg = std.mem.trimRight(u8, read_buf[0..total], "\n\r");

    const request = control.parseRequest(msg) orelse {
        var resp_buf: [256]u8 = undefined;
        const resp = control.writeErrorResponse(&resp_buf, "invalid request") orelse return;
        _ = posix.write(fd, resp) catch {};
        return;
    };

    var resp_buf: [4096]u8 = undefined;
    const response = dispatch(request, &resp_buf);
    _ = posix.write(fd, response) catch {};
}

fn dispatch(request: control.Request, buf: []u8) []const u8 {
    switch (request) {
        .status => return handleStatus(buf),
        .share => |s| return handleShare(s, buf),
        .unshare => |u| return handleUnshare(u, buf),
        .join => |j| return handleJoin(j, buf),
        .leave => return handleLeave(buf),
        .shutdown => {
            should_exit.store(true, .release);
            return control.writeSimpleOk(buf) orelse "";
        },
    }
}

fn handleStatus(buf: []u8) []const u8 {
    var infos: [MAX_SESSIONS]control.SessionInfo = undefined;
    var count: usize = 0;

    sessions_mutex.lock();
    defer sessions_mutex.unlock();

    for (&sessions) |*slot| {
        if (slot.payload) |payload| {
            switch (payload) {
                .terminal => |share| {
                    infos[count] = .{
                        .id = &share.session_id,
                        .type = .terminal,
                        .room = share.share_url,
                        .viewers = share.viewerCount(),
                        .recording = share.recording != null,
                        .uptime_s = share.uptimeSeconds(),
                        .title = share.currentTitle(),
                    };
                },
                .app => |share| {
                    infos[count] = .{
                        .id = &share.session_id,
                        .type = .app,
                        .room = share.share_url,
                        .viewers = share.viewerCount(),
                        .recording = false,
                        .uptime_s = share.uptimeSeconds(),
                    };
                },
                .wayland_app => |share| {
                    infos[count] = .{
                        .id = &share.session_id,
                        .type = .app,
                        .room = share.share_url,
                        .viewers = share.viewerCount(),
                        .recording = false,
                        .uptime_s = share.uptimeSeconds(),
                    };
                },
            }
            count += 1;
        }
    }

    return control.writeStatusResponse(buf, infos[0..count], currentRoom()) orelse
        control.writeErrorResponse(buf, "internal error") orelse "";
}

fn handleShare(req: control.ShareRequest, buf: []u8) []const u8 {
    if (req.type == .terminal) {
        return handleShareTerminal(req, buf);
    }
    if (req.type == .app) {
        return handleShareApp(req, buf);
    }
    return control.writeErrorResponse(buf, "unknown share type") orelse "";
}

// ── App share ────────────────────────────────────────────────────────────

const AppInitResult = struct {
    share: ?*AppShare = null,
    err_msg: ?[]const u8 = null,
    done: std.Thread.ResetEvent = .{},
};

fn handleShareApp(req: control.ShareRequest, buf: []u8) []const u8 {
    if (req.gpu == .nvidia_x11) {
        return handleShareAppNvidia(req, buf);
    }
    if (req.gpu == .intel or req.gpu == .nvidia) {
        return handleShareAppWayland(req, buf);
    }

    // auto → detect best GPU with hardware encode
    const result = gpu_detect.detectGpus();
    if (result.best()) |gpu| {
        if (gpu.best_codec != null) {
            // Route to Wayland path with detected GPU
            var auto_req = req;
            auto_req.gpu = switch (gpu.vendor) {
                .nvidia => .nvidia,
                .intel => .intel,
                .amd => .intel, // AMD uses VA-API path (same as intel)
                .unknown => .intel,
            };
            return handleShareAppWayland(auto_req, buf);
        }
    }

    // Fallback: X11+NvFBC pipeline
    log.info("auto-detect: no Wayland-capable encoder found, falling back to X11+NvFBC", .{});
    return handleShareAppNvidia(req, buf);
}

fn handleShareAppNvidia(req: control.ShareRequest, buf: []u8) []const u8 {
    const allocator = std.heap.c_allocator;

    const command = req.command orelse
        return control.writeErrorResponse(buf, "app share requires a command") orelse "";

    const base_url = std.process.getEnvVarOwned(allocator, "ZEROCAST_URL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => allocator.dupe(u8, "https://zerocast.bodar.com") catch
            return control.writeErrorResponse(buf, "internal error") orelse "",
        else => return control.writeErrorResponse(buf, "internal error") orelse "",
    };

    if (currentRoom() == null) {
        const id_buf = control.generateRoomId();
        setRoom(&id_buf);
        log.info("auto-joined room: {s}", .{currentRoom().?});
    }

    const record_dir = std.process.getEnvVarOwned(allocator, "ZEROCAST_RECORD_DIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => null,
    };

    const config = AppShareConfig{
        .command = command,
        .fps = req.fps,
        .base_url = base_url,
        .room_id = currentRoom(),
        .record_dir = if (record_dir) |d| d else null,
    };

    const slot_idx = findEmptySlot() orelse {
        return control.writeErrorResponse(buf, "maximum sessions reached") orelse "";
    };

    const result = allocator.create(AppInitResult) catch
        return control.writeErrorResponse(buf, "out of memory") orelse "";
    defer allocator.destroy(result);
    result.* = .{};

    const thread = std.Thread.spawn(.{}, appThreadEntry, .{ result, config, slot_idx }) catch |err| {
        log.err("app thread spawn failed: {}", .{err});
        return control.writeErrorResponse(buf, "failed to start app thread") orelse "";
    };

    result.done.wait();

    if (result.err_msg) |err_msg| {
        thread.join();
        return control.writeErrorResponse(buf, err_msg) orelse "";
    }

    const share = result.share.?;

    sessions_mutex.lock();
    sessions[slot_idx].thread = thread;
    sessions_mutex.unlock();

    return control.writeOkResponse(buf, &share.session_id, share.share_url) orelse
        control.writeErrorResponse(buf, "internal error") orelse "";
}

fn handleShareAppWayland(req: control.ShareRequest, buf: []u8) []const u8 {
    const allocator = std.heap.c_allocator;

    const command = req.command orelse
        return control.writeErrorResponse(buf, "app share requires a command") orelse "";

    const base_url = std.process.getEnvVarOwned(allocator, "ZEROCAST_URL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => allocator.dupe(u8, "https://zerocast.bodar.com") catch
            return control.writeErrorResponse(buf, "internal error") orelse "",
        else => return control.writeErrorResponse(buf, "internal error") orelse "",
    };

    if (currentRoom() == null) {
        const id_buf = control.generateRoomId();
        setRoom(&id_buf);
        log.info("auto-joined room: {s}", .{currentRoom().?});
    }

    const record_dir = std.process.getEnvVarOwned(allocator, "ZEROCAST_RECORD_DIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => null,
    };

    // Detect render device for the requested GPU vendor
    const render_device: [*:0]const u8 = blk: {
        const detected = gpu_detect.detectGpus();
        const target_vendor: gpu_detect.GpuVendor = switch (req.gpu) {
            .nvidia_x11 => unreachable, // routed to X11 path before this
            .nvidia => .nvidia,
            .intel => .intel,
            .auto => if (detected.best()) |b| b.vendor else .intel,
        };
        for (detected.candidates[0..detected.count]) |*c2| {
            if (c2.vendor == target_vendor) break :blk c2.renderPath();
        }
        // Fallback defaults
        break :blk if (req.gpu == .nvidia) "/dev/dri/renderD129" else "/dev/dri/renderD128";
    };

    const config = WaylandAppShareConfig{
        .command = command,
        .fps = req.fps,
        .base_url = base_url,
        .room_id = currentRoom(),
        .record_dir = if (record_dir) |d| d else null,
        .gpu = req.gpu,
        .render_device = render_device,
    };

    const slot_idx = findEmptySlot() orelse {
        return control.writeErrorResponse(buf, "maximum sessions reached") orelse "";
    };

    const result = allocator.create(WaylandInitResult) catch
        return control.writeErrorResponse(buf, "out of memory") orelse "";
    defer allocator.destroy(result);
    result.* = .{};

    const thread = std.Thread.spawn(.{}, waylandAppThreadEntry, .{ result, config, slot_idx }) catch |err| {
        log.err("wayland app thread spawn failed: {}", .{err});
        return control.writeErrorResponse(buf, "failed to start wayland app thread") orelse "";
    };

    result.done.wait();

    if (result.err_msg) |err_msg| {
        thread.join();
        return control.writeErrorResponse(buf, err_msg) orelse "";
    }

    const share = result.share.?;

    sessions_mutex.lock();
    sessions[slot_idx].thread = thread;
    sessions_mutex.unlock();

    return control.writeOkResponse(buf, &share.session_id, share.share_url) orelse
        control.writeErrorResponse(buf, "internal error") orelse "";
}

fn appThreadEntry(result: *AppInitResult, config: AppShareConfig, slot_idx: usize) void {
    const allocator = std.heap.c_allocator;

    const share = allocator.create(AppShare) catch {
        result.err_msg = "out of memory";
        result.done.set();
        return;
    };

    share.initInPlace(config) catch {
        allocator.destroy(share);
        result.err_msg = "app share init failed";
        result.done.set();
        return;
    };

    sessions_mutex.lock();
    sessions[slot_idx].payload = .{ .app = share };
    sessions_mutex.unlock();

    share.start();

    result.share = share;
    result.done.set();

    share.runLoop();

    // Clean up on the same thread (GL/CUDA contexts are thread-local)
    share.deinit();

    // Clear the session slot. If stopAllSessions/stopSessionById already
    // cleared it (leave/unshare), the daemon owns the free after thread.join().
    // Otherwise we're exiting naturally and must free here.
    sessions_mutex.lock();
    const daemon_owns_free = sessions[slot_idx].payload == null;
    sessions[slot_idx] = .{};
    sessions_mutex.unlock();

    if (!daemon_owns_free) allocator.destroy(share);
}

const WaylandInitResult = struct {
    share: ?*WaylandAppShare = null,
    err_msg: ?[]const u8 = null,
    done: std.Thread.ResetEvent = .{},
};

fn waylandAppThreadEntry(result: *WaylandInitResult, config: WaylandAppShareConfig, slot_idx: usize) void {
    const allocator = std.heap.c_allocator;

    const share = allocator.create(WaylandAppShare) catch {
        result.err_msg = "out of memory";
        result.done.set();
        return;
    };

    share.initInPlace(config) catch {
        allocator.destroy(share);
        result.err_msg = "wayland app share init failed";
        result.done.set();
        return;
    };

    sessions_mutex.lock();
    sessions[slot_idx].payload = .{ .wayland_app = share };
    sessions_mutex.unlock();

    share.start();

    result.share = share;
    result.done.set();

    share.runLoop();

    // Clean up on the same thread (GPU contexts are thread-local)
    share.deinit();

    sessions_mutex.lock();
    const daemon_owns_free = sessions[slot_idx].payload == null;
    sessions[slot_idx] = .{};
    sessions_mutex.unlock();

    if (!daemon_owns_free) allocator.destroy(share);
}

// ── Terminal share ───────────────────────────────────────────────────────

fn handleShareTerminal(req: control.ShareRequest, buf: []u8) []const u8 {
    const allocator = std.heap.c_allocator;

    // Resolve base URL
    const base_url = std.process.getEnvVarOwned(allocator, "ZEROCAST_URL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => allocator.dupe(u8, "https://zerocast.bodar.com") catch
            return control.writeErrorResponse(buf, "internal error") orelse "",
        else => return control.writeErrorResponse(buf, "internal error") orelse "",
    };

    // Auto-join a room if not in one
    if (currentRoom() == null) {
        const id_buf = control.generateRoomId();
        setRoom(&id_buf);
        log.info("auto-joined room: {s}", .{currentRoom().?});
    }

    const config = TerminalShareConfig{
        .command = req.command,
        .record = req.record,
        .base_url = base_url,
        .room_id = currentRoom(),
    };

    // Find empty slot before spawning
    const slot_idx = findEmptySlot() orelse {
        return control.writeErrorResponse(buf, "maximum sessions reached") orelse "";
    };

    const share = allocator.create(TerminalShare) catch
        return control.writeErrorResponse(buf, "out of memory") orelse "";

    share.initInPlace(config) catch |err| {
        log.err("terminal share init failed: {}", .{err});
        allocator.destroy(share);
        return control.writeErrorResponse(buf, "terminal share init failed") orelse "";
    };

    sessions_mutex.lock();
    sessions[slot_idx].payload = .{ .terminal = share };
    sessions_mutex.unlock();

    // Register signaling callbacks
    share.start();

    // Spawn read loop thread
    const thread = std.Thread.spawn(.{}, runTerminalThread, .{share}) catch |err| {
        log.err("thread spawn failed: {}", .{err});
        sessions_mutex.lock();
        sessions[slot_idx] = .{};
        sessions_mutex.unlock();
        share.deinit();
        allocator.destroy(share);
        return control.writeErrorResponse(buf, "failed to start terminal thread") orelse "";
    };

    sessions_mutex.lock();
    sessions[slot_idx].thread = thread;
    sessions_mutex.unlock();

    return control.writeOkResponse(buf, &share.session_id, share.share_url) orelse
        control.writeErrorResponse(buf, "internal error") orelse "";
}

fn handleJoin(req: control.JoinRequest, buf: []u8) []const u8 {
    // Stop existing shares if switching rooms
    if (currentRoom() != null) {
        const stopped = stopAllSessions();
        if (stopped > 0) log.info("join: stopped {d} session(s) from previous room", .{stopped});
    }

    if (req.room) |room| {
        if (room.len == 0 or room.len > current_room_buf.len)
            return control.writeErrorResponse(buf, "invalid room name") orelse "";
        setRoom(room);
    } else {
        const id_buf = control.generateRoomId();
        setRoom(&id_buf);
    }

    log.info("joined room: {s}", .{currentRoom().?});

    // Build room URL for response
    const allocator = std.heap.c_allocator;
    const base_url = std.process.getEnvVarOwned(allocator, "ZEROCAST_URL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => allocator.dupe(u8, "https://zerocast.bodar.com") catch
            return control.writeErrorResponse(buf, "internal error") orelse "",
        else => return control.writeErrorResponse(buf, "internal error") orelse "",
    };
    defer allocator.free(base_url);

    var url_buf: [512]u8 = undefined;
    const room_url = std.fmt.bufPrint(&url_buf, "{s}/room/{s}", .{
        base_url, currentRoom().?,
    }) catch return control.writeErrorResponse(buf, "internal error") orelse "";

    return control.writeJoinResponse(buf, room_url) orelse
        control.writeErrorResponse(buf, "internal error") orelse "";
}

fn handleLeave(buf: []u8) []const u8 {
    if (currentRoom() == null) {
        return control.writeErrorResponse(buf, "not in a room") orelse "";
    }

    const stopped = stopAllSessions();
    log.info("leave: stopped {d} session(s)", .{stopped});
    clearRoom();

    return control.writeSimpleOk(buf) orelse "";
}

fn findEmptySlot() ?usize {
    sessions_mutex.lock();
    defer sessions_mutex.unlock();
    for (&sessions, 0..) |*slot, i| {
        if (slot.payload == null) return i;
    }
    return null;
}

fn runTerminalThread(share: *TerminalShare) void {
    share.runLoop();
}

fn handleUnshare(req: control.UnshareRequest, buf: []u8) []const u8 {
    var stopped: u32 = 0;

    if (req.session_id) |sid| {
        // Stop specific session by ID
        if (stopSessionById(sid)) {
            stopped = 1;
        } else {
            return control.writeErrorResponse(buf, "no session with that ID") orelse "";
        }
    } else if (req.type) |t| {
        // Stop all sessions of a given type
        stopped = stopSessionsByType(t);
    } else {
        // Stop all sessions
        stopped += stopAllSessions();
    }

    log.info("unshare: stopped {d} session(s)", .{stopped});
    return control.writeSimpleOk(buf) orelse "";
}

fn getSessionId(payload: SharePayload) *const [16]u8 {
    return switch (payload) {
        .terminal => |t| &t.session_id,
        .app => |a| &a.session_id,
        .wayland_app => |a| &a.session_id,
    };
}

fn getSessionType(payload: SharePayload) control.ShareType {
    return switch (payload) {
        .terminal => .terminal,
        .app, .wayland_app => .app,
    };
}

fn signalStop(payload: SharePayload) void {
    switch (payload) {
        .terminal => |t| t.should_stop.store(true, .release),
        .app => |a| a.should_stop.store(true, .release),
        .wayland_app => |a| a.should_stop.store(true, .release),
    }
}

fn deinitAndFree(payload: SharePayload) void {
    const allocator = std.heap.c_allocator;
    switch (payload) {
        // App shares deinit on their capture thread (GPU contexts are thread-local).
        // We only free the heap allocation here after thread.join().
        .app => |a| allocator.destroy(a),
        .wayland_app => |a| allocator.destroy(a),
        .terminal => |t| {
            t.deinit();
            allocator.destroy(t);
        },
    }
}

fn stopSessionById(session_id: []const u8) bool {
    sessions_mutex.lock();
    for (&sessions) |*slot| {
        if (slot.payload) |payload| {
            const sid = getSessionId(payload);
            if (session_id.len >= 16 and std.mem.eql(u8, session_id[0..16], sid)) {
                signalStop(payload);
                const thread = slot.thread;
                const p = payload;
                slot.* = .{};
                sessions_mutex.unlock();

                if (thread) |t| t.join();
                deinitAndFree(p);
                return true;
            }
        }
    }
    sessions_mutex.unlock();
    return false;
}

fn stopSessionsByType(t: control.ShareType) u32 {
    var stopped: u32 = 0;

    var to_stop: [MAX_SESSIONS]struct { payload: SharePayload, thread: ?std.Thread } = undefined;
    var stop_count: usize = 0;

    sessions_mutex.lock();
    for (&sessions) |*slot| {
        if (slot.payload) |payload| {
            if (getSessionType(payload) == t) {
                signalStop(payload);
                to_stop[stop_count] = .{ .payload = payload, .thread = slot.thread };
                stop_count += 1;
                slot.* = .{};
            }
        }
    }
    sessions_mutex.unlock();

    for (to_stop[0..stop_count]) |item| {
        if (item.thread) |th| th.join();
        deinitAndFree(item.payload);
        stopped += 1;
    }

    return stopped;
}

fn stopAllSessions() u32 {
    var stopped: u32 = 0;

    var to_stop: [MAX_SESSIONS]struct { payload: SharePayload, thread: ?std.Thread } = undefined;
    var stop_count: usize = 0;

    sessions_mutex.lock();
    for (&sessions) |*slot| {
        if (slot.payload) |payload| {
            signalStop(payload);
            to_stop[stop_count] = .{ .payload = payload, .thread = slot.thread };
            stop_count += 1;
            slot.* = .{};
        }
    }
    sessions_mutex.unlock();

    for (to_stop[0..stop_count]) |item| {
        if (item.thread) |th| th.join();
        deinitAndFree(item.payload);
        stopped += 1;
    }

    return stopped;
}

// ── Helpers ──────────────────────────────────────────────────────────────

const DaemonCheck = enum { alive, stale, none };

fn checkExistingDaemon(path: []const u8) DaemonCheck {
    // First check if the socket file exists at all
    std.fs.cwd().access(path, .{}) catch return .none;

    const addr = toSockaddr(path) orelse return .none;
    const sock = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch return .none;
    defer posix.close(sock);

    // Socket file exists — try to connect. If nobody is listening, it's stale.
    posix.connect(sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) catch return .stale;

    // Connected — but is it actually responding? Send a status request with a short timeout.
    const timeout = posix.timeval{ .sec = 2, .usec = 0 };
    posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch return .stale;
    posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch return .stale;

    const request = "{\"cmd\":\"status\"}\n";
    _ = posix.write(sock, request) catch return .stale;

    // Read response — any valid data means the daemon is alive
    var buf: [4096]u8 = undefined;
    const n = posix.read(sock, &buf) catch return .stale;
    if (n == 0) return .stale;

    return .alive;
}

fn toSockaddr(path: []const u8) ?std.posix.sockaddr.un {
    if (path.len >= @as(usize, @typeInfo(@TypeOf(@as(std.posix.sockaddr.un, undefined).path)).array.len)) return null;
    var addr = std.mem.zeroes(std.posix.sockaddr.un);
    addr.family = posix.AF.UNIX;
    @memcpy(addr.path[0..path.len], path);
    return addr;
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

// ── Tests ────────────────────────────────────────────────────────────────

test "toSockaddr valid" {
    const addr = toSockaddr("/tmp/test.sock").?;
    try std.testing.expectEqual(posix.AF.UNIX, addr.family);
    try std.testing.expectEqualSlices(u8, "/tmp/test.sock", addr.path[0..14]);
}

test "toSockaddr too long" {
    const path_max = @typeInfo(@TypeOf(@as(std.posix.sockaddr.un, undefined).path)).array.len;
    const long_path = "a" ** path_max;
    try std.testing.expect(toSockaddr(long_path) == null);
}

test "dispatch status returns empty sessions" {
    // Reset session state for test isolation
    sessions_mutex.lock();
    for (&sessions) |*slot| slot.* = .{};
    sessions_mutex.unlock();

    var buf: [4096]u8 = undefined;
    const resp = dispatch(.status, &buf);
    try std.testing.expect(resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"sessions\":[]") != null);
}

test "dispatch shutdown sets exit flag" {
    should_exit.store(false, .release);
    var buf: [4096]u8 = undefined;
    const resp = dispatch(.shutdown, &buf);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":true") != null);
    try std.testing.expect(should_exit.load(.acquire));
    should_exit.store(false, .release); // reset for other tests
}

test "socket bind and accept" {
    // Create a temp socket, bind, connect, send request, read response
    const path = "/tmp/zerocast-test.sock";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    const addr = toSockaddr(path).?;

    const listener = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch return;
    defer posix.close(listener);
    posix.bind(listener, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) catch return;
    posix.listen(listener, 1) catch return;

    // Client side
    const client = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch return;
    defer posix.close(client);
    posix.connect(client, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) catch return;

    // Send a status request
    const msg = "{\"cmd\":\"status\"}\n";
    _ = posix.write(client, msg) catch return;

    // Accept and handle on server side
    const conn = posix.accept(listener, null, null, posix.SOCK.CLOEXEC) catch return;
    defer posix.close(conn);
    handleConnection(conn);

    // Read response on client side
    var resp_buf: [4096]u8 = undefined;
    const n = posix.read(client, &resp_buf) catch return;
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp_buf[0..n], "\"sessions\":[]") != null);
}
