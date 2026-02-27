const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol");
const ipc = @import("ipc");

const log = std.log.scoped(.kms_client);

const Self = @This();

sock_fd: posix.fd_t = -1,
server_pid: posix.pid_t = 0,

/// Launch the barecast-kms helper process and establish IPC.
pub fn init(card_path: []const u8) !Self {
    const pair = try ipc.socketPair();

    // Resolve barecast-kms path relative to our own executable
    var helper_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const helper_path = resolveHelperPath(&helper_path_buf) catch |err| {
        log.err("failed to resolve barecast-kms path: {}", .{err});
        return error.HelperNotFound;
    };

    const pid = try posix.fork();
    if (pid == 0) {
        // Child: close parent's end, exec the helper
        posix.close(pair[0]);

        var fd_buf: [16]u8 = undefined;
        const fd_str = std.fmt.bufPrint(&fd_buf, "{d}", .{pair[1]}) catch unreachable;
        // Null-terminate for execvpe
        fd_buf[fd_str.len] = 0;
        const fd_z: [*:0]const u8 = fd_buf[0..fd_str.len :0];

        // card_path needs to be null-terminated
        var card_buf: [256]u8 = undefined;
        if (card_path.len >= card_buf.len) {
            log.err("card path too long", .{});
            std.process.exit(1);
        }
        @memcpy(card_buf[0..card_path.len], card_path);
        card_buf[card_path.len] = 0;
        const card_z: [*:0]const u8 = card_buf[0..card_path.len :0];

        const argv = [_:null]?[*:0]const u8{ "barecast-kms", fd_z, card_z, null };
        const envp = [_:null]?[*:0]const u8{null};

        const err = posix.execvpeZ(helper_path, &argv, &envp);
        log.err("execvpe failed: {}", .{err});
        std.process.exit(1);
    }

    // Parent: close child's end
    posix.close(pair[1]);

    return .{
        .sock_fd = pair[0],
        .server_pid = pid,
    };
}

/// Request a frame from the KMS helper. Populates response and maps received fds
/// into the response planes.
pub fn getFrame(self: *Self, response: *protocol.Response) !void {
    const request = protocol.Request{ .type = .get_frame };
    try ipc.sendRequest(self.sock_fd, &request);

    var fd_buf: [protocol.max_planes * protocol.max_dma_bufs_per_plane]i32 = undefined;
    const num_fds = try ipc.recvResponse(self.sock_fd, response, &fd_buf);

    // Map received fds back into response planes
    var fd_idx: u32 = 0;
    for (response.planes[0..response.num_planes]) |*plane| {
        for (plane.dma_bufs[0..plane.num_dma_bufs]) |*dma_buf| {
            if (fd_idx < num_fds) {
                dma_buf.fd = fd_buf[fd_idx];
                fd_idx += 1;
            }
        }
    }
}

/// Close DMA-BUF fds from a previous getFrame response. Must be called before
/// requesting the next frame.
pub fn closeFds(_: *Self, response: *protocol.Response) void {
    for (response.planes[0..response.num_planes]) |*plane| {
        for (plane.dma_bufs[0..plane.num_dma_bufs]) |*dma_buf| {
            if (dma_buf.fd >= 0) {
                posix.close(dma_buf.fd);
                dma_buf.fd = -1;
            }
        }
    }
}

const pci_vendor_nvidia = "0x10de";

/// Find the NVIDIA GPU's card path by reading sysfs vendor IDs.
/// Returns e.g. "/dev/dri/card2". Falls back to first available card.
pub fn findNvidiaCard(buf: *[64]u8) ?[]const u8 {
    var first_card: ?[]const u8 = null;

    var dir = std.fs.openDirAbsolute("/sys/class/drm", .{ .iterate = true }) catch return null;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        // Match "card0", "card1", etc. — skip "card0-DP-1" etc.
        if (!std.mem.startsWith(u8, entry.name, "card")) continue;
        const suffix = entry.name["card".len..];
        if (suffix.len == 0) continue;
        // Must be digits only (no connector suffixes like "-DP-1")
        var all_digits = true;
        for (suffix) |c| {
            if (c < '0' or c > '9') {
                all_digits = false;
                break;
            }
        }
        if (!all_digits) continue;

        const dev_path = std.fmt.bufPrint(buf, "/dev/dri/{s}", .{entry.name}) catch continue;

        if (first_card == null) first_card = dev_path;

        // Read /sys/class/drm/cardN/device/vendor
        var vendor_path_buf: [128]u8 = undefined;
        const vendor_path = std.fmt.bufPrint(&vendor_path_buf, "/sys/class/drm/{s}/device/vendor", .{entry.name}) catch continue;
        var vendor_buf: [16]u8 = undefined;
        const vendor = readSysfsLine(vendor_path, &vendor_buf) orelse continue;

        if (std.mem.eql(u8, vendor, pci_vendor_nvidia)) {
            return dev_path;
        }
    }

    // No NVIDIA card found, return first available
    if (first_card) |card| {
        // Re-print into buf since the previous bufPrint may have been overwritten
        return std.fmt.bufPrint(buf, "{s}", .{card}) catch null;
    }
    return null;
}

fn readSysfsLine(path: []const u8, buf: *[16]u8) ?[]const u8 {
    // Need null-terminated path for openat
    var path_buf: [256]u8 = undefined;
    if (path.len >= path_buf.len) return null;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = path_buf[0..path.len :0];

    const fd = posix.openatZ(posix.AT.FDCWD, path_z, .{}, 0) catch return null;
    defer posix.close(fd);
    const n = posix.read(fd, buf) catch return null;
    if (n == 0) return null;
    // Strip trailing newline
    const len = if (n > 0 and buf[n - 1] == '\n') n - 1 else n;
    return buf[0..len];
}

/// Resolve the path to barecast-kms by looking in the same directory as our own executable.
fn resolveHelperPath(buf: *[std.fs.max_path_bytes]u8) ![*:0]const u8 {
    const self_path = try std.fs.selfExePath(buf);
    // Find the last '/' to get the directory
    const dir_end = if (std.mem.lastIndexOfScalar(u8, self_path, '/')) |pos| pos + 1 else 0;
    const helper_name = "barecast-kms";
    const total_len = dir_end + helper_name.len;
    if (total_len >= buf.len) return error.NameTooLong;
    @memcpy(buf[dir_end..][0..helper_name.len], helper_name);
    buf[total_len] = 0;
    return buf[0..total_len :0];
}

/// Send shutdown request and clean up.
pub fn deinit(self: *Self) void {
    if (self.sock_fd >= 0) {
        const request = protocol.Request{ .type = .shutdown };
        ipc.sendRequest(self.sock_fd, &request) catch {};
        posix.close(self.sock_fd);
        self.sock_fd = -1;
    }

    if (self.server_pid > 0) {
        _ = posix.waitpid(self.server_pid, 0);
        self.server_pid = 0;
    }
}
