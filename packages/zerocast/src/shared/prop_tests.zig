const std = @import("std");
const minish = @import("minish");
const mgen = minish.gen;
const input_protocol = @import("input_protocol");

const runs = 200;

const msg_byte_gen = mgen.string(.{
    .min_len = 0,
    .max_len = 200,
    .charset = .ascii,
});

// ─── Input protocol property: random bytes never panic ──────────────────────

fn prop_input_decode_never_panics(data: []const u8) !void {
    // decode() should return a valid message or an error, never panic/crash
    _ = input_protocol.decode(data) catch return;
}

fn prop_color_assign_roundtrip(data: []const u8) !void {
    if (data.len == 0) return;
    const color_index = data[0];
    const encoded = input_protocol.encodeColorAssign(color_index);
    const msg = input_protocol.decode(&encoded) catch return error.TestUnexpectedResult;
    try std.testing.expectEqual(msg.color_assign.color_index, color_index);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try minish.check(allocator, msg_byte_gen, prop_input_decode_never_panics, .{ .num_runs = runs });
    try minish.check(allocator, msg_byte_gen, prop_color_assign_roundtrip, .{ .num_runs = runs });

    std.debug.print("All property tests passed.\n", .{});
}
