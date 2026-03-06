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
        execSystemctl("start");
    } else if (std.mem.eql(u8, subcmd, "stop")) {
        execSystemctl("stop");
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
        std.debug.print("Usage: zerocast share <screen|terminal> [options]\n", .{});
        std.process.exit(1);
    };

    if (!std.mem.eql(u8, share_type, "screen") and !std.mem.eql(u8, share_type, "terminal")) {
        std.debug.print("Unknown share type: {s}\nExpected: screen, terminal\n", .{share_type});
        std.process.exit(1);
    }

    // Build JSON request
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.writeAll("{\"cmd\":\"share\",\"type\":\"") catch return;
    w.writeAll(share_type) catch return;
    w.writeByte('"') catch return;

    const is_screen = std.mem.eql(u8, share_type, "screen");

    // Parse remaining flags
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--fps")) {
            if (!is_screen) {
                std.debug.print("--fps is only valid for screen shares\n", .{});
                std.process.exit(1);
            }
            const fps = args.next() orelse {
                std.debug.print("--fps requires a value\n", .{});
                std.process.exit(1);
            };
            w.writeAll(",\"fps\":") catch return;
            w.writeAll(fps) catch return;
        } else if (std.mem.eql(u8, arg, "--record")) {
            w.writeAll(",\"record\":true") catch return;
        } else if (is_screen and (std.mem.eql(u8, arg, "--geometry") or isPossibleGeometry(arg))) {
            const geom = if (std.mem.eql(u8, arg, "--geometry"))
                (args.next() orelse {
                    std.debug.print("--geometry requires a WxH+X+Y value\n", .{});
                    std.process.exit(1);
                })
            else
                arg;
            w.writeAll(",\"geometry\":\"") catch return;
            w.writeAll(geom) catch return;
            w.writeByte('"') catch return;
        } else if (!is_screen) {
            // Positional arg in terminal mode = command
            w.writeAll(",\"command\":\"") catch return;
            w.writeAll(arg) catch return;
            w.writeByte('"') catch return;
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            std.process.exit(1);
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
        if (std.mem.eql(u8, t, "screen") or std.mem.eql(u8, t, "terminal")) {
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

fn execSystemctl(action: []const u8) void {
    const argv = [_]?[*:0]const u8{
        "systemctl",
        "--user",
        if (std.mem.eql(u8, action, "start")) "start" else "stop",
        "zerocast",
        null,
    };
    const err = std.posix.execvpeZ("systemctl", @ptrCast(&argv), std.c.environ);
    std.debug.print("Failed to exec systemctl: {}\n", .{err});
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

fn toSockaddr(path: []const u8) ?std.os.linux.sockaddr.un {
    if (path.len >= 108) return null;
    var addr = std.mem.zeroes(std.os.linux.sockaddr.un);
    addr.family = posix.AF.UNIX;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

/// Quick heuristic: does this look like WxH+X+Y geometry?
fn isPossibleGeometry(s: []const u8) bool {
    if (s.len < 7) return false; // minimum: "1x1+0+0"
    var has_x = false;
    var has_plus: u8 = 0;
    for (s) |ch| {
        if (ch == 'x') has_x = true;
        if (ch == '+') has_plus += 1;
    }
    return has_x and has_plus >= 2;
}

fn printUsage() void {
    std.debug.print(
        \\zerocast v{s}
        \\
        \\Usage:
        \\  zerocast join [room-name]                     Join a room (random if omitted)
        \\  zerocast leave                                Leave room and stop all shares
        \\  zerocast share screen [WxH+X+Y] [--fps <n>] [--record]
        \\  zerocast share terminal [command] [--record]
        \\  zerocast unshare [screen | terminal | <session-id>]
        \\  zerocast status                               Show current room and sessions
        \\  zerocast start                                Start the daemon (systemd)
        \\  zerocast stop                                 Stop the daemon (systemd)
        \\  zerocast daemon                               Run daemon in foreground
        \\
        \\Examples:
        \\  zerocast join my-room                         Join a stable room
        \\  zerocast share screen                         Share full screen
        \\  zerocast share screen 1920x1080+0+0           Share a sub-region
        \\  zerocast share screen --fps 60 --record       60fps + record to IVF
        \\  zerocast share terminal                       Share interactive shell
        \\  zerocast share terminal htop --record         Share htop + record .cast
        \\  zerocast unshare                              Stop all shares
        \\
    , .{build_options.version});
}

// ── Tests ────────────────────────────────────────────────────────────────

test "isPossibleGeometry" {
    try std.testing.expect(isPossibleGeometry("1920x1080+0+0"));
    try std.testing.expect(isPossibleGeometry("800x600+100+200"));
    try std.testing.expect(!isPossibleGeometry("screen"));
    try std.testing.expect(!isPossibleGeometry("--room"));
    try std.testing.expect(!isPossibleGeometry("htop"));
    try std.testing.expect(!isPossibleGeometry("123"));
}
