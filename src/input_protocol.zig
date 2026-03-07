const std = @import("std");

/// Wire protocol message types for viewer → host communication over WebRTC data channel.
/// All multi-byte integers are little-endian (matches DataView default in browser).
/// Messages are self-delimiting — WebRTC data channel provides framing.

pub const MsgType = enum(u8) {
    // Input events (viewer → host)
    mouse_move = 0x01,
    mouse_down = 0x02,
    mouse_up = 0x03,
    scroll = 0x04,
    key_down = 0x05,
    key_up = 0x06,

    // Draw events (viewer → host)
    draw_start = 0x10,
    draw_move = 0x11,
    draw_end = 0x12,
    draw_undo = 0x13,
    draw_clear = 0x14,

    // Host → viewer
    viewer_left = 0xFD,
    relay = 0xFE,
    color_assign = 0xFF,
};

pub const MouseButton = enum(u8) {
    left = 0,
    right = 1,
    middle = 2,
};

pub const Message = union(MsgType) {
    mouse_move: struct { x: u16, y: u16 },
    mouse_down: struct { x: u16, y: u16, button: MouseButton },
    mouse_up: struct { x: u16, y: u16, button: MouseButton },
    scroll: struct { x: u16, y: u16, delta: i16 },
    key_down: struct { code: []const u8 },
    key_up: struct { code: []const u8 },
    draw_start: struct { x: u16, y: u16 },
    draw_move: struct { x: u16, y: u16 },
    draw_end: void,
    draw_undo: void,
    draw_clear: void,
    viewer_left: struct { color_index: u8 },
    relay: struct { color_index: u8, payload: []const u8 },
    color_assign: struct { color_index: u8 },
};

pub const DecodeError = error{
    EmptyMessage,
    UnknownType,
    Truncated,
    InvalidButton,
};

/// Decode a binary message from a WebRTC data channel.
/// For key_down/key_up, the returned `code` slice points into the input `data` buffer.
pub fn decode(data: []const u8) DecodeError!Message {
    if (data.len == 0) return error.EmptyMessage;

    const tag = std.meta.intToEnum(MsgType, data[0]) catch return error.UnknownType;

    switch (tag) {
        .mouse_move => {
            if (data.len < 5) return error.Truncated;
            return .{ .mouse_move = .{
                .x = readU16(data[1..3]),
                .y = readU16(data[3..5]),
            } };
        },
        .mouse_down => {
            if (data.len < 6) return error.Truncated;
            const button = std.meta.intToEnum(MouseButton, data[5]) catch return error.InvalidButton;
            return .{ .mouse_down = .{
                .x = readU16(data[1..3]),
                .y = readU16(data[3..5]),
                .button = button,
            } };
        },
        .mouse_up => {
            if (data.len < 6) return error.Truncated;
            const button = std.meta.intToEnum(MouseButton, data[5]) catch return error.InvalidButton;
            return .{ .mouse_up = .{
                .x = readU16(data[1..3]),
                .y = readU16(data[3..5]),
                .button = button,
            } };
        },
        .scroll => {
            if (data.len < 7) return error.Truncated;
            return .{ .scroll = .{
                .x = readU16(data[1..3]),
                .y = readU16(data[3..5]),
                .delta = readI16(data[5..7]),
            } };
        },
        .key_down => {
            if (data.len < 2) return error.Truncated;
            const code_len: usize = data[1];
            if (data.len < 2 + code_len) return error.Truncated;
            return .{ .key_down = .{ .code = data[2 .. 2 + code_len] } };
        },
        .key_up => {
            if (data.len < 2) return error.Truncated;
            const code_len: usize = data[1];
            if (data.len < 2 + code_len) return error.Truncated;
            return .{ .key_up = .{ .code = data[2 .. 2 + code_len] } };
        },
        .draw_start => {
            if (data.len < 5) return error.Truncated;
            return .{ .draw_start = .{
                .x = readU16(data[1..3]),
                .y = readU16(data[3..5]),
            } };
        },
        .draw_move => {
            if (data.len < 5) return error.Truncated;
            return .{ .draw_move = .{
                .x = readU16(data[1..3]),
                .y = readU16(data[3..5]),
            } };
        },
        .draw_end => return .{ .draw_end = {} },
        .draw_undo => return .{ .draw_undo = {} },
        .draw_clear => return .{ .draw_clear = {} },
        .viewer_left => {
            if (data.len < 2) return error.Truncated;
            return .{ .viewer_left = .{ .color_index = data[1] } };
        },
        .relay => {
            if (data.len < 3) return error.Truncated;
            return .{ .relay = .{ .color_index = data[1], .payload = data[2..] } };
        },
        .color_assign => {
            if (data.len < 2) return error.Truncated;
            return .{ .color_assign = .{ .color_index = data[1] } };
        },
    }
}

/// Encode a color_assign message (host → viewer).
pub fn encodeColorAssign(color_index: u8) [2]u8 {
    return .{ @intFromEnum(MsgType.color_assign), color_index };
}

/// Encode a viewer_left message (host → viewer).
pub fn encodeViewerLeft(color_index: u8) [2]u8 {
    return .{ @intFromEnum(MsgType.viewer_left), color_index };
}

/// Encode a relay message (host → viewer): [0xFE][color_index][original...].
/// Returns the number of bytes written, or null if buf is too small.
pub fn encodeRelay(color_index: u8, original: []const u8, buf: []u8) ?usize {
    const total = 2 + original.len;
    if (total > buf.len) return null;
    buf[0] = @intFromEnum(MsgType.relay);
    buf[1] = color_index;
    @memcpy(buf[2 .. 2 + original.len], original);
    return total;
}

fn readU16(bytes: *const [2]u8) u16 {
    return std.mem.readInt(u16, bytes, .little);
}

fn readI16(bytes: *const [2]u8) i16 {
    return std.mem.readInt(i16, bytes, .little);
}

// ── Tests ────────────────────────────────────────────────────────────────

test "decode mouse_move" {
    const data = [_]u8{ 0x01, 0x80, 0x07, 0x38, 0x04 }; // x=1920, y=1080
    const msg = try decode(&data);
    try std.testing.expectEqual(msg.mouse_move.x, 1920);
    try std.testing.expectEqual(msg.mouse_move.y, 1080);
}

test "decode mouse_down left" {
    const data = [_]u8{ 0x02, 0x00, 0x01, 0x00, 0x02, 0x00 };
    const msg = try decode(&data);
    try std.testing.expectEqual(msg.mouse_down.x, 256);
    try std.testing.expectEqual(msg.mouse_down.y, 512);
    try std.testing.expectEqual(msg.mouse_down.button, .left);
}

test "decode mouse_up right" {
    const data = [_]u8{ 0x03, 0x0A, 0x00, 0x14, 0x00, 0x01 };
    const msg = try decode(&data);
    try std.testing.expectEqual(msg.mouse_up.x, 10);
    try std.testing.expectEqual(msg.mouse_up.y, 20);
    try std.testing.expectEqual(msg.mouse_up.button, .right);
}

test "decode scroll positive" {
    const data = [_]u8{ 0x04, 0x00, 0x01, 0x00, 0x02, 0x78, 0x00 }; // delta=120
    const msg = try decode(&data);
    try std.testing.expectEqual(msg.scroll.delta, 120);
}

test "decode scroll negative" {
    const data = [_]u8{ 0x04, 0x00, 0x01, 0x00, 0x02, 0x88, 0xFF }; // delta=-120
    const msg = try decode(&data);
    try std.testing.expectEqual(msg.scroll.delta, -120);
}

test "decode key_down" {
    const code = "KeyA";
    var data: [6]u8 = undefined;
    data[0] = 0x05;
    data[1] = @intCast(code.len);
    @memcpy(data[2..6], code);
    const msg = try decode(&data);
    try std.testing.expectEqualSlices(u8, "KeyA", msg.key_down.code);
}

test "decode key_up" {
    const code = "Space";
    var data: [7]u8 = undefined;
    data[0] = 0x06;
    data[1] = @intCast(code.len);
    @memcpy(data[2..7], code);
    const msg = try decode(&data);
    try std.testing.expectEqualSlices(u8, "Space", msg.key_up.code);
}

test "decode draw_start" {
    const data = [_]u8{ 0x10, 0x64, 0x00, 0xC8, 0x00 }; // x=100, y=200
    const msg = try decode(&data);
    try std.testing.expectEqual(msg.draw_start.x, 100);
    try std.testing.expectEqual(msg.draw_start.y, 200);
}

test "decode draw_move" {
    const data = [_]u8{ 0x11, 0x65, 0x00, 0xC9, 0x00 };
    const msg = try decode(&data);
    try std.testing.expectEqual(msg.draw_move.x, 101);
    try std.testing.expectEqual(msg.draw_move.y, 201);
}

test "decode draw_end" {
    const data = [_]u8{0x12};
    const msg = try decode(&data);
    try std.testing.expectEqual(std.meta.activeTag(msg), .draw_end);
}

test "decode draw_undo" {
    const data = [_]u8{0x13};
    const msg = try decode(&data);
    try std.testing.expectEqual(std.meta.activeTag(msg), .draw_undo);
}

test "decode draw_clear" {
    const data = [_]u8{0x14};
    const msg = try decode(&data);
    try std.testing.expectEqual(std.meta.activeTag(msg), .draw_clear);
}

test "decode color_assign" {
    const data = [_]u8{ 0xFF, 0x03 };
    const msg = try decode(&data);
    try std.testing.expectEqual(msg.color_assign.color_index, 3);
}

test "decode empty returns error" {
    const data = [_]u8{};
    try std.testing.expectError(error.EmptyMessage, decode(&data));
}

test "decode unknown type returns error" {
    const data = [_]u8{0x99};
    try std.testing.expectError(error.UnknownType, decode(&data));
}

test "decode truncated mouse_move returns error" {
    const data = [_]u8{ 0x01, 0x80 }; // only 2 bytes, need 5
    try std.testing.expectError(error.Truncated, decode(&data));
}

test "decode truncated key_down returns error" {
    const data = [_]u8{ 0x05, 0x04, 'K', 'e' }; // claims 4 bytes, only 2 present
    try std.testing.expectError(error.Truncated, decode(&data));
}

test "decode invalid mouse button returns error" {
    const data = [_]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x05 }; // button=5, invalid
    try std.testing.expectError(error.InvalidButton, decode(&data));
}

test "encodeColorAssign roundtrip" {
    const encoded = encodeColorAssign(7);
    const msg = try decode(&encoded);
    try std.testing.expectEqual(msg.color_assign.color_index, 7);
}

test "encodeViewerLeft roundtrip" {
    const encoded = encodeViewerLeft(3);
    const msg = try decode(&encoded);
    try std.testing.expectEqual(msg.viewer_left.color_index, 3);
}

test "encodeRelay roundtrip" {
    const original = [_]u8{ 0x01, 0x80, 0x07, 0x38, 0x04 }; // mouse_move
    var buf: [64]u8 = undefined;
    const len = encodeRelay(2, &original, &buf).?;
    try std.testing.expectEqual(len, 7);
    const msg = try decode(buf[0..len]);
    try std.testing.expectEqual(msg.relay.color_index, 2);
    try std.testing.expectEqualSlices(u8, &original, msg.relay.payload);
}

test "encodeRelay too small returns null" {
    const original = [_]u8{ 0x01, 0x80, 0x07, 0x38, 0x04 };
    var buf: [3]u8 = undefined;
    try std.testing.expect(encodeRelay(0, &original, &buf) == null);
}
