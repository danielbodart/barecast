const std = @import("std");
const posix = std.posix;
const control = @import("control");
const build_options = @import("build_options");

// ── CLI dispatch ─────────────────────────────────────────────────────────

pub fn dispatch() void {
    var args = std.process.args();
    _ = args.next(); // skip argv[0]

    const subcmd = args.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, subcmd, "status")) {
        sendCommand("{\"cmd\":\"status\"}\n", .{ .print_raw = true });
    } else if (std.mem.eql(u8, subcmd, "share")) {
        handleShare(&args);
    } else if (std.mem.eql(u8, subcmd, "unshare")) {
        handleUnshare(&args);
    } else if (std.mem.eql(u8, subcmd, "join")) {
        handleJoin(&args);
    } else if (std.mem.eql(u8, subcmd, "leave")) {
        sendCommand("{\"cmd\":\"leave\"}\n", .{});
    } else if (std.mem.eql(u8, subcmd, "start")) {
        execServiceCtl("start");
    } else if (std.mem.eql(u8, subcmd, "stop")) {
        execServiceCtl("stop");
    } else if (std.mem.eql(u8, subcmd, "attach")) {
        const session_id = args.next() orelse {
            std.debug.print("Usage: zerocast attach <session-id>\n", .{});
            std.process.exit(1);
        };
        _ = session_id;
        std.debug.print("attach: not yet implemented (Phase 4)\n", .{});
        std.process.exit(1);
    } else if (std.mem.eql(u8, subcmd, "version") or std.mem.eql(u8, subcmd, "--version") or std.mem.eql(u8, subcmd, "-v")) {
        std.debug.print("zerocast v{s}\n", .{build_options.version});
    } else if (std.mem.eql(u8, subcmd, "help") or std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{subcmd});
        printUsage();
        std.process.exit(1);
    }
}

fn handleShare(args: *std.process.ArgIterator) void {
    const share_type = args.next() orelse {
        std.debug.print("Usage: zerocast share <terminal|app> [options]\n", .{});
        std.process.exit(1);
    };

    if (!std.mem.eql(u8, share_type, "terminal") and !std.mem.eql(u8, share_type, "app")) {
        std.debug.print("Unknown share type: {s}\nExpected: terminal, app\n", .{share_type});
        std.process.exit(1);
    }

    // Build JSON request
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.writeAll("{\"cmd\":\"share\",\"type\":\"") catch return;
    w.writeAll(share_type) catch return;
    w.writeByte('"') catch return;

    // Parse remaining flags
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--record")) {
            w.writeAll(",\"record\":true") catch return;
        } else if (std.mem.eql(u8, arg, "--gpu")) {
            if (args.next()) |gpu| {
                w.writeAll(",\"gpu\":\"") catch return;
                w.writeAll(gpu) catch return;
                w.writeByte('"') catch return;
            }
        } else if (std.mem.eql(u8, arg, "--qp")) {
            if (args.next()) |qp| {
                w.writeAll(",\"qp\":") catch return;
                w.writeAll(qp) catch return;
            }
        } else {
            // Positional arg in terminal/app mode = command
            w.writeAll(",\"command\":\"") catch return;
            w.writeAll(arg) catch return;
            w.writeByte('"') catch return;
        }
    }

    w.writeAll("}\n") catch return;

    const msg = fbs.getWritten();
    sendCommand(msg, .{ .extract_session_id = true });
}

fn handleUnshare(args: *std.process.ArgIterator) void {
    const target = args.next();

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.writeAll("{\"cmd\":\"unshare\"") catch return;

    if (target) |t| {
        if (std.mem.eql(u8, t, "terminal") or std.mem.eql(u8, t, "app")) {
            w.writeAll(",\"type\":\"") catch return;
            w.writeAll(t) catch return;
            w.writeByte('"') catch return;
        } else {
            // Assume it's a session ID
            w.writeAll(",\"session_id\":\"") catch return;
            w.writeAll(t) catch return;
            w.writeByte('"') catch return;
        }
    }

    w.writeAll("}\n") catch return;
    sendCommand(fbs.getWritten(), .{});
}

fn handleJoin(args: *std.process.ArgIterator) void {
    const room = args.next();

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.writeAll("{\"cmd\":\"join\"") catch return;
    if (room) |r| {
        w.writeAll(",\"room\":\"") catch return;
        w.writeAll(r) catch return;
        w.writeByte('"') catch return;
    }
    w.writeAll("}\n") catch return;

    sendCommand(fbs.getWritten(), .{ .extract_room = true });
}

const builtin = @import("builtin");

fn execServiceCtl(action: []const u8) void {
    const is_start = std.mem.eql(u8, action, "start");
    switch (builtin.os.tag) {
        .linux => {
            const argv = [_]?[*:0]const u8{
                "systemctl",
                "--user",
                if (is_start) "start" else "stop",
                "zerocast",
                null,
            };
            const err = std.posix.execvpeZ("systemctl", @ptrCast(&argv), std.c.environ);
            std.debug.print("Failed to exec systemctl: {}\n", .{err});
        },
        .macos => {
            const label = "com.zerocast.daemon";
            if (is_start) {
                const argv = [_]?[*:0]const u8{ "launchctl", "start", label, null };
                const err = std.posix.execvpeZ("launchctl", @ptrCast(&argv), std.c.environ);
                std.debug.print("Failed to exec launchctl: {}\n", .{err});
            } else {
                const argv = [_]?[*:0]const u8{ "launchctl", "stop", label, null };
                const err = std.posix.execvpeZ("launchctl", @ptrCast(&argv), std.c.environ);
                std.debug.print("Failed to exec launchctl: {}\n", .{err});
            }
        },
        else => {
            std.debug.print("Service management not supported on this platform\n", .{});
        },
    }
    std.process.exit(1);
}

const SendOptions = struct {
    print_raw: bool = false,
    extract_session_id: bool = false,
    extract_room: bool = false,
};

fn sendCommand(msg: []const u8, opts: SendOptions) void {
    var sock_path_buf: [256]u8 = undefined;
    const sock_path = control.getSocketPath(&sock_path_buf) orelse {
        std.debug.print("Failed to determine socket path\n", .{});
        std.process.exit(1);
    };

    const addr = toSockaddr(sock_path) orelse {
        std.debug.print("Socket path too long\n", .{});
        std.process.exit(1);
    };

    const sock = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch |err| {
        std.debug.print("Cannot connect to daemon: {}\n", .{err});
        std.debug.print("Is the daemon running? Start with: zerocast daemon\n", .{});
        std.process.exit(1);
    };
    defer posix.close(sock);

    posix.connect(sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) catch {
        std.debug.print("Cannot connect to daemon at {s}\n", .{sock_path});
        std.debug.print("Is the daemon running? Start with: zerocast daemon\n", .{});
        std.process.exit(1);
    };

    _ = posix.write(sock, msg) catch |err| {
        std.debug.print("Failed to send command: {}\n", .{err});
        std.process.exit(1);
    };

    // Shutdown write side to signal EOF to daemon
    std.posix.shutdown(sock, .send) catch {};

    // Read response
    var resp_buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < resp_buf.len) {
        const n = posix.read(sock, resp_buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    if (total == 0) {
        std.debug.print("No response from daemon\n", .{});
        std.process.exit(1);
    }

    const resp = std.mem.trimRight(u8, resp_buf[0..total], "\n\r");

    // Check for error
    if (control.jsonExtract(resp, "error")) |err_msg| {
        std.debug.print("Error: {s}\n", .{err_msg});
        std.process.exit(1);
    }

    if (opts.extract_session_id) {
        // Print session ID to stdout (pipeable), room URL to stderr
        if (control.jsonExtract(resp, "session_id")) |sid| {
            // stdout: just the session ID
            var buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{s}\n", .{sid}) catch sid;
            _ = posix.write(posix.STDOUT_FILENO, line) catch {};

            // stderr: room URL for humans
            if (control.jsonExtract(resp, "room")) |room| {
                std.debug.print("{s}\n", .{room});
            }
        } else {
            std.debug.print("{s}\n", .{resp});
        }
    } else if (opts.extract_room) {
        if (control.jsonExtract(resp, "room")) |room| {
            std.debug.print("{s}\n", .{room});
        }
    } else if (opts.print_raw) {
        std.debug.print("{s}\n", .{resp});
    } else {
        // Simple ok acknowledgment — just print "OK" or the full response
        if (std.mem.indexOf(u8, resp, "\"ok\":true") != null) {
            std.debug.print("OK\n", .{});
        } else {
            std.debug.print("{s}\n", .{resp});
        }
    }
}

fn toSockaddr(path: []const u8) ?std.posix.sockaddr.un {
    if (path.len >= @as(usize, @typeInfo(@TypeOf(@as(std.posix.sockaddr.un, undefined).path)).array.len)) return null;
    var addr = std.mem.zeroes(std.posix.sockaddr.un);
    addr.family = posix.AF.UNIX;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

fn printUsage() void {
    std.debug.print(
        \\zerocast v{s}
        \\
        \\Usage:
        \\  zerocast join [room-name]                     Join a room (random if omitted)
        \\  zerocast leave                                Leave room and stop all shares
        \\  zerocast share terminal [command] [--record]
        \\  zerocast share app <command>
        \\  zerocast unshare [terminal | app | <session-id>]
        \\  zerocast status                               Show current room and sessions
        \\  zerocast start                                Start the daemon (systemd)
        \\  zerocast stop                                 Stop the daemon (systemd)
        \\  zerocast daemon                               Run daemon in foreground
        \\
        \\Examples:
        \\  zerocast join my-room                         Join a stable room
        \\  zerocast share terminal                       Share interactive shell
        \\  zerocast share terminal htop --record         Share htop + record .cast
        \\  zerocast share app code                       Share VS Code
        \\  zerocast share app glxgears                   Share glxgears
        \\  zerocast unshare                              Stop all shares
        \\
    , .{build_options.version});
}

// ── Tests ────────────────────────────────────────────────────────────────

