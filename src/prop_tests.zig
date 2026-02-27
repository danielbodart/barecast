const std = @import("std");
const minish = @import("minish");
const mgen = minish.gen;
const protocol = @import("protocol");

const runs = 200;

// Generator for error message bytes
const msg_byte_gen = mgen.string(.{
    .min_len = 0,
    .max_len = 200,
    .charset = .ascii,
});

// Generator for fd-like values
const fd_gen = mgen.intRange(i32, -10, 100);

// ─── Protocol roundtrip properties ─────────────────────────────────────────

fn prop_setError_roundtrip(data: []const u8) !void {
    var resp = protocol.Response{};
    resp.setError(data);
    const msg = resp.errorMessage();
    const expected_len = @min(data.len, 127);
    try std.testing.expectEqual(msg.len, expected_len);
    // Content should match up to the truncation point
    try std.testing.expectEqualSlices(u8, data[0..expected_len], msg);
}

fn prop_setError_marks_err(data: []const u8) !void {
    var resp = protocol.Response{};
    resp.setError(data);
    try std.testing.expectEqual(resp.result, .err);
}

fn prop_collectFds_count(data: []const u8) !void {
    _ = data;
    var resp = protocol.Response{};

    // Use a simple deterministic pattern: one fd per plane
    var expected: u32 = 0;
    const num_planes: u32 = 3;
    resp.num_planes = num_planes;

    for (0..num_planes) |i| {
        resp.planes[i].num_dma_bufs = 1;
        const fd_val: i32 = @as(i32, @intCast(i)) * 10;
        resp.planes[i].dma_bufs[0].fd = fd_val;
        if (fd_val >= 0) expected += 1;
    }

    var fds: [32]i32 = undefined;
    const count = resp.collectFds(&fds);
    try std.testing.expectEqual(count, expected);
}

fn prop_default_response_is_ok(_: []const u8) !void {
    const resp = protocol.Response{};
    try std.testing.expectEqual(resp.result, .ok);
    try std.testing.expectEqual(resp.num_planes, 0);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try minish.check(allocator, msg_byte_gen, prop_setError_roundtrip, .{ .num_runs = runs });
    try minish.check(allocator, msg_byte_gen, prop_setError_marks_err, .{ .num_runs = runs });
    try minish.check(allocator, msg_byte_gen, prop_collectFds_count, .{ .num_runs = runs });
    try minish.check(allocator, msg_byte_gen, prop_default_response_is_ok, .{ .num_runs = runs });

    std.debug.print("All property tests passed.\n", .{});
}
