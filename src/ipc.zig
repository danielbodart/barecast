const std = @import("std");
const posix = std.posix;
const c = std.c;
const protocol = @import("protocol");

// ─── Linux-specific types for SCM_RIGHTS ────────────────────────────────────

const SCM_RIGHTS = 0x01;
const SOL_SOCKET = 1;

const CmsgHdr = extern struct {
    len: usize,
    level: c_int,
    type: c_int,
};

fn cmsgLen(data_len: usize) usize {
    return cmsgAlign(@sizeOf(CmsgHdr)) + data_len;
}

fn cmsgSpace(data_len: usize) usize {
    return cmsgAlign(@sizeOf(CmsgHdr)) + cmsgAlign(data_len);
}

fn cmsgAlign(len: usize) usize {
    return (len + @sizeOf(usize) - 1) & ~(@as(usize, @sizeOf(usize) - 1));
}

fn cmsgData(cmsg: *CmsgHdr) [*]u8 {
    const ptr: [*]u8 = @ptrCast(cmsg);
    return ptr + cmsgAlign(@sizeOf(CmsgHdr));
}

// ─── Public API ─────────────────────────────────────────────────────────────

const max_fds = protocol.max_planes * protocol.max_dma_bufs_per_plane; // 32

/// Send a protocol Response over a Unix socket, with DMA-BUF fds attached via SCM_RIGHTS.
pub fn sendResponse(sock_fd: posix.fd_t, response: *const protocol.Response, fds: []const i32) !void {
    var iov = c.iovec{
        .base = @constCast(@ptrCast(response)),
        .len = @sizeOf(protocol.Response),
    };

    var msg = std.mem.zeroes(c.msghdr_const);
    msg.iov = @ptrCast(&iov);
    msg.iovlen = 1;

    var cmsg_buf: [cmsgSpace(max_fds * @sizeOf(i32))]u8 align(@alignOf(CmsgHdr)) = undefined;
    @memset(&cmsg_buf, 0);

    if (fds.len > 0) {
        const data_len = fds.len * @sizeOf(i32);
        const cmsg: *CmsgHdr = @ptrCast(@alignCast(&cmsg_buf));
        cmsg.level = SOL_SOCKET;
        cmsg.type = SCM_RIGHTS;
        cmsg.len = cmsgLen(data_len);

        const fd_data: [*]i32 = @ptrCast(@alignCast(cmsgData(cmsg)));
        for (fds, 0..) |fd, i| {
            fd_data[i] = fd;
        }

        msg.control = @ptrCast(&cmsg_buf);
        msg.controllen = @intCast(cmsgSpace(data_len));
    }

    const sent = c.sendmsg(sock_fd, @ptrCast(&msg), 0);
    if (sent < 0) return error.SendFailed;
    if (@as(usize, @intCast(sent)) != @sizeOf(protocol.Response)) return error.ShortSend;
}

/// Receive a protocol Response from a Unix socket, extracting DMA-BUF fds from SCM_RIGHTS.
/// Returns the number of fds extracted.
pub fn recvResponse(sock_fd: posix.fd_t, response: *protocol.Response, fd_buf: []i32) !u32 {
    var iov = c.iovec{
        .base = @ptrCast(response),
        .len = @sizeOf(protocol.Response),
    };

    var msg = std.mem.zeroes(c.msghdr);
    msg.iov = @ptrCast(&iov);
    msg.iovlen = 1;

    var cmsg_buf: [cmsgSpace(max_fds * @sizeOf(i32))]u8 align(@alignOf(CmsgHdr)) = undefined;
    @memset(&cmsg_buf, 0);
    msg.control = @ptrCast(&cmsg_buf);
    msg.controllen = @intCast(cmsg_buf.len);

    const received = c.recvmsg(sock_fd, @ptrCast(&msg), 0);
    if (received == 0) return error.PeerDisconnected;
    if (received < 0) return error.RecvFailed;
    if (@as(usize, @intCast(received)) != @sizeOf(protocol.Response)) return error.ShortRecv;

    // Extract fds from control message
    var num_fds: u32 = 0;
    const cmsg: *const CmsgHdr = @ptrCast(@alignCast(msg.control));
    if (msg.controllen > 0 and cmsg.level == SOL_SOCKET and cmsg.type == SCM_RIGHTS) {
        const fd_data: [*]const i32 = @ptrCast(@alignCast(cmsgData(@constCast(cmsg))));
        const payload_len = cmsg.len - cmsgLen(0);
        const fd_count = payload_len / @sizeOf(i32);
        for (0..fd_count) |i| {
            if (num_fds < fd_buf.len) {
                fd_buf[num_fds] = fd_data[i];
                num_fds += 1;
            }
        }
    }

    return num_fds;
}

/// Send a protocol Request over a Unix socket (no fds).
pub fn sendRequest(sock_fd: posix.fd_t, request: *const protocol.Request) !void {
    var iov = c.iovec{
        .base = @constCast(@ptrCast(request)),
        .len = @sizeOf(protocol.Request),
    };

    var msg = std.mem.zeroes(c.msghdr_const);
    msg.iov = @ptrCast(&iov);
    msg.iovlen = 1;

    const sent = c.sendmsg(sock_fd, @ptrCast(&msg), 0);
    if (sent < 0) return error.SendFailed;
    if (@as(usize, @intCast(sent)) != @sizeOf(protocol.Request)) return error.ShortSend;
}

/// Receive a protocol Request from a Unix socket (no fds).
pub fn recvRequest(sock_fd: posix.fd_t, request: *protocol.Request) !void {
    var iov = c.iovec{
        .base = @ptrCast(request),
        .len = @sizeOf(protocol.Request),
    };

    var msg = std.mem.zeroes(c.msghdr);
    msg.iov = @ptrCast(&iov);
    msg.iovlen = 1;

    const received = c.recvmsg(sock_fd, @ptrCast(&msg), 0);
    if (received == 0) return error.PeerDisconnected;
    if (received < 0) return error.RecvFailed;
    if (@as(usize, @intCast(received)) != @sizeOf(protocol.Request)) return error.ShortRecv;
}

/// Create a Unix socketpair.
pub fn socketPair() ![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    if (c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds) != 0)
        return error.SocketPairFailed;
    return .{ fds[0], fds[1] };
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "SCM_RIGHTS roundtrip — send and receive fds via socketpair" {
    const fds = try socketPair();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const null1 = try posix.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    defer posix.close(null1);
    const null2 = try posix.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    defer posix.close(null2);

    var send_resp = protocol.Response{};
    send_resp.num_planes = 1;
    send_resp.planes[0].num_dma_bufs = 2;
    send_resp.planes[0].width = 1920;
    send_resp.planes[0].height = 1080;
    send_resp.planes[0].dma_bufs[0].fd = null1;
    send_resp.planes[0].dma_bufs[1].fd = null2;

    const send_fds = [_]i32{ null1, null2 };
    try sendResponse(fds[0], &send_resp, &send_fds);

    var recv_resp: protocol.Response = undefined;
    var recv_fds: [32]i32 = undefined;
    const num_fds = try recvResponse(fds[1], &recv_resp, &recv_fds);

    for (recv_fds[0..num_fds]) |fd| posix.close(fd);

    try std.testing.expectEqual(num_fds, 2);
    try std.testing.expectEqual(recv_resp.num_planes, 1);
    try std.testing.expectEqual(recv_resp.planes[0].width, 1920);
    try std.testing.expectEqual(recv_resp.planes[0].height, 1080);
    try std.testing.expect(recv_fds[0] >= 0);
    try std.testing.expect(recv_fds[1] >= 0);
}

test "Request roundtrip — send and receive without fds" {
    const fds = try socketPair();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const send_req = protocol.Request{ .type = .get_frame };
    try sendRequest(fds[0], &send_req);

    var recv_req: protocol.Request = undefined;
    try recvRequest(fds[1], &recv_req);

    try std.testing.expectEqual(recv_req.version, protocol.protocol_version);
    try std.testing.expectEqual(recv_req.type, .get_frame);
}

test "Response with no fds roundtrip" {
    const fds = try socketPair();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var send_resp = protocol.Response{};
    send_resp.setError("test error");

    try sendResponse(fds[0], &send_resp, &.{});

    var recv_resp: protocol.Response = undefined;
    var recv_fds: [32]i32 = undefined;
    const num_fds = try recvResponse(fds[1], &recv_resp, &recv_fds);

    try std.testing.expectEqual(num_fds, 0);
    try std.testing.expectEqual(recv_resp.result, .err);
    try std.testing.expectEqualStrings("test error", recv_resp.errorMessage());
}
