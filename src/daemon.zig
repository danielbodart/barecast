const std = @import("std");
const posix = std.posix;
const control = @import("control");
const ScreenShare = @import("screen_share").ScreenShare;
const ScreenShareConfig = @import("screen_share").ScreenShareConfig;
const parseGeometry = @import("screen_share").parseGeometry;
const TerminalShare = @import("terminal_share").TerminalShare;
const TerminalShareConfig = @import("terminal_share").TerminalShareConfig;
const build_options = @import("build_options");

const log = std.log.scoped(.daemon);

pub const std_options: std.Options = .{
    .log_level = .info,
};

var should_exit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// ── Session slots ────────────────────────────────────────────────────────

const MAX_SESSIONS = 8;

const SharePayload = union(enum) {
    screen: *ScreenShare,
    terminal: *TerminalShare,
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

    // Check for existing daemon
    if (isSocketAlive(sock_path)) {
        log.err("daemon already running (socket responds at {s})", .{sock_path});
        return;
    }

    // Unlink stale socket if it exists
    const sock_path_z = toSockaddr(sock_path) orelse {
        log.err("socket path too long", .{});
        return;
    };

    std.fs.cwd().deleteFile(sock_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            log.err("failed to unlink stale socket: {}", .{err});
            return;
        },
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
                .screen => |share| {
                    infos[count] = .{
                        .id = &share.session_id,
                        .type = .screen,
                        .room = share.share_url,
                        .viewers = share.viewerCount(),
                        .recording = share.recording != null,
                        .uptime_s = share.uptimeSeconds(),
                    };
                },
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
    return handleShareScreen(req, buf);
}

/// Thread-safe init result passed from capture thread back to daemon.
const ScreenInitResult = struct {
    share: ?*ScreenShare = null,
    err_msg: ?[]const u8 = null,
    done: std.Thread.ResetEvent = .{},
};

fn handleShareScreen(req: control.ShareRequest, buf: []u8) []const u8 {
    const allocator = std.heap.c_allocator;

    // Resolve base URL
    const base_url = std.process.getEnvVarOwned(allocator, "ZEROCAST_URL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => allocator.dupe(u8, "https://zerocast.bodar.com") catch
            return control.writeErrorResponse(buf, "internal error") orelse "",
        else => return control.writeErrorResponse(buf, "internal error") orelse "",
    };

    // Auto-join a room if not in one
    if (currentRoom() == null) {
        var id_buf: [16]u8 = undefined;
        generateRoomId(&id_buf) catch
            return control.writeErrorResponse(buf, "failed to generate room ID") orelse "";
        setRoom(&id_buf);
        log.info("auto-joined room: {s}", .{currentRoom().?});
    }

    var config = ScreenShareConfig{
        .fps = req.fps,
        .record = req.record,
        .base_url = base_url,
        .room_id = currentRoom(),
    };

    if (req.geometry) |geom| {
        config.geometry = parseGeometry(geom) orelse
            return control.writeErrorResponse(buf, "invalid geometry format (expected WxH+X+Y)") orelse "";
    }

    // Find empty slot before spawning thread
    const slot_idx = findEmptySlot() orelse {
        return control.writeErrorResponse(buf, "maximum sessions reached") orelse "";
    };

    // Allocate init result on heap (shared between threads)
    const result = allocator.create(ScreenInitResult) catch
        return control.writeErrorResponse(buf, "out of memory") orelse "";
    defer allocator.destroy(result);
    result.* = .{};

    // Spawn thread that does ALL GPU work: init + start + runLoop
    // GL/CUDA contexts must be created and used on the same thread.
    const thread = std.Thread.spawn(.{}, screenThreadEntry, .{ result, config, slot_idx }) catch |err| {
        log.err("thread spawn failed: {}", .{err});
        return control.writeErrorResponse(buf, "failed to start capture thread") orelse "";
    };

    // Wait for init to complete on the capture thread
    result.done.wait();

    if (result.err_msg) |err_msg| {
        thread.join();
        return control.writeErrorResponse(buf, err_msg) orelse "";
    }

    const share = result.share.?;

    // Store thread handle
    sessions_mutex.lock();
    sessions[slot_idx].thread = thread;
    sessions_mutex.unlock();

    return control.writeOkResponse(buf, &share.session_id, share.share_url) orelse
        control.writeErrorResponse(buf, "internal error") orelse "";
}

fn screenThreadEntry(result: *ScreenInitResult, config: ScreenShareConfig, slot_idx: usize) void {
    const allocator = std.heap.c_allocator;

    const share = allocator.create(ScreenShare) catch {
        result.err_msg = "out of memory";
        result.done.set();
        return;
    };

    // Init in-place — all internal pointers (encoder → session, session →
    // viewer_registry) are captured against the heap address, not a stack copy.
    share.initInPlace(config) catch {
        allocator.destroy(share);
        result.err_msg = "screen share init failed";
        result.done.set();
        return;
    };

    // Register session slot
    sessions_mutex.lock();
    sessions[slot_idx].payload = .{ .screen = share };
    sessions_mutex.unlock();

    // Register signaling callbacks
    share.start();

    // Signal success to the daemon thread
    result.share = share;
    result.done.set();

    // Run the capture loop (blocks until should_stop)
    share.runLoop();

    // Clean up GPU resources on the same thread they were created
    // (GL/CUDA contexts are thread-local)
    share.deinit();
}

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
        var id_buf: [16]u8 = undefined;
        generateRoomId(&id_buf) catch
            return control.writeErrorResponse(buf, "failed to generate room ID") orelse "";
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
        var id_buf: [16]u8 = undefined;
        generateRoomId(&id_buf) catch
            return control.writeErrorResponse(buf, "failed to generate room ID") orelse "";
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

fn generateRoomId(out: *[16]u8) !void {
    var random_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    const charset = "0123456789abcdef";
    for (random_bytes, 0..) |b, i| {
        out[i * 2] = charset[b >> 4];
        out[i * 2 + 1] = charset[b & 0x0f];
    }
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
        .screen => |s| &s.session_id,
        .terminal => |t| &t.session_id,
    };
}

fn getSessionType(payload: SharePayload) control.ShareType {
    return switch (payload) {
        .screen => .screen,
        .terminal => .terminal,
    };
}

fn signalStop(payload: SharePayload) void {
    switch (payload) {
        .screen => |s| s.should_stop.store(true, .release),
        .terminal => |t| t.should_stop.store(true, .release),
    }
}

fn deinitAndFree(payload: SharePayload) void {
    const allocator = std.heap.c_allocator;
    switch (payload) {
        // Screen shares deinit on their capture thread (GL contexts are thread-local).
        // We only free the heap allocation here after thread.join().
        .screen => |s| allocator.destroy(s),
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

fn isSocketAlive(path: []const u8) bool {
    const addr = toSockaddr(path) orelse return false;
    const sock = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch return false;
    defer posix.close(sock);

    posix.connect(sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) catch return false;
    return true;
}

fn toSockaddr(path: []const u8) ?std.os.linux.sockaddr.un {
    if (path.len >= 108) return null; // sun_path limit
    var addr = std.mem.zeroes(std.os.linux.sockaddr.un);
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
    const long_path = "a" ** 108;
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
