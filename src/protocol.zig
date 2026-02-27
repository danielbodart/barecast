const std = @import("std");

/// Wire protocol between barecast (unprivileged) and barecast-kms (CAP_SYS_ADMIN).
/// Communicated over a Unix socketpair via sendmsg/recvmsg with SCM_RIGHTS for DMA-BUF fds.

pub const protocol_version: u32 = 1;

pub const max_planes: usize = 8;
pub const max_dma_bufs_per_plane: usize = 4;

pub const RequestType = enum(u32) {
    get_frame = 1,
    shutdown = 2,
};

pub const Request = extern struct {
    version: u32 = protocol_version,
    type: RequestType,
};

pub const DmaBuf = extern struct {
    fd: i32 = -1,
    pitch: u32 = 0,
    offset: u32 = 0,
};

pub const Rotation = enum(u32) {
    rot_0 = 0,
    rot_90 = 1,
    rot_180 = 2,
    rot_270 = 3,
};

pub const Plane = extern struct {
    dma_bufs: [max_dma_bufs_per_plane]DmaBuf = [_]DmaBuf{.{}} ** max_dma_bufs_per_plane,
    num_dma_bufs: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    pixel_format: u32 = 0,
    modifier: u64 = 0,
    connector_id: u32 = 0,
    is_cursor: bool = false,
    rotation: Rotation = .rot_0,
    x: i32 = 0,
    y: i32 = 0,
    src_w: u32 = 0,
    src_h: u32 = 0,
};

pub const ResultType = enum(u32) {
    ok = 0,
    err = 1,
};

pub const Response = extern struct {
    version: u32 = protocol_version,
    result: ResultType = .ok,
    err_msg: [128]u8 = [_]u8{0} ** 128,
    planes: [max_planes]Plane = [_]Plane{.{}} ** max_planes,
    num_planes: u32 = 0,

    pub fn setError(self: *Response, msg: []const u8) void {
        self.result = .err;
        const len = @min(msg.len, self.err_msg.len - 1);
        @memcpy(self.err_msg[0..len], msg[0..len]);
        self.err_msg[len] = 0;
    }

    pub fn errorMessage(self: *const Response) []const u8 {
        const sentinel = std.mem.indexOfScalar(u8, &self.err_msg, 0) orelse self.err_msg.len;
        return self.err_msg[0..sentinel];
    }

    /// Collect all valid DMA-BUF fds from all planes into a flat slice.
    pub fn collectFds(self: *const Response, buf: []i32) u32 {
        var count: u32 = 0;
        for (self.planes[0..self.num_planes]) |plane| {
            for (plane.dma_bufs[0..plane.num_dma_bufs]) |dma_buf| {
                if (dma_buf.fd >= 0 and count < buf.len) {
                    buf[count] = dma_buf.fd;
                    count += 1;
                }
            }
        }
        return count;
    }
};

// ─── Tests ─────────────────────────────────────────────────────────────────

test "Request has stable size" {
    try std.testing.expectEqual(@sizeOf(Request), 8);
}

test "Response setError and errorMessage roundtrip" {
    var resp = Response{};
    resp.setError("test error");
    try std.testing.expectEqualStrings("test error", resp.errorMessage());
    try std.testing.expectEqual(resp.result, .err);
}

test "Response setError truncates long messages" {
    var resp = Response{};
    const long_msg = "x" ** 200;
    resp.setError(long_msg);
    try std.testing.expectEqual(resp.errorMessage().len, 127);
}

test "Response collectFds gathers plane fds" {
    var resp = Response{};
    resp.num_planes = 2;
    resp.planes[0].num_dma_bufs = 1;
    resp.planes[0].dma_bufs[0].fd = 10;
    resp.planes[1].num_dma_bufs = 2;
    resp.planes[1].dma_bufs[0].fd = 20;
    resp.planes[1].dma_bufs[1].fd = 30;

    var fds: [32]i32 = undefined;
    const count = resp.collectFds(&fds);
    try std.testing.expectEqual(count, 3);
    try std.testing.expectEqual(fds[0], 10);
    try std.testing.expectEqual(fds[1], 20);
    try std.testing.expectEqual(fds[2], 30);
}

test "Response collectFds skips invalid fds" {
    var resp = Response{};
    resp.num_planes = 1;
    resp.planes[0].num_dma_bufs = 2;
    resp.planes[0].dma_bufs[0].fd = -1; // invalid
    resp.planes[0].dma_bufs[1].fd = 5;

    var fds: [32]i32 = undefined;
    const count = resp.collectFds(&fds);
    try std.testing.expectEqual(count, 1);
    try std.testing.expectEqual(fds[0], 5);
}
