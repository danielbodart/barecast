const std = @import("std");

const log = std.log.scoped(.control);

// ── Request types ────────────────────────────────────────────────────────

pub const ShareType = enum {
    terminal,
    app,
};

pub const Request = union(enum) {
    share: ShareRequest,
    unshare: UnshareRequest,
    join: JoinRequest,
    leave,
    status,
    shutdown,
};

pub const GpuBackend = enum { auto, nvidia, intel };

pub const ShareRequest = struct {
    type: ShareType = .app,
    fps: u32 = 30,
    record: bool = false,
    command: ?[]const u8 = null,
    gpu: GpuBackend = .auto,
    qp: u32 = 20,
};

pub const JoinRequest = struct {
    room: ?[]const u8 = null, // null = auto-generate
};

pub const UnshareRequest = struct {
    session_id: ?[]const u8 = null,
    type: ?ShareType = null,
};

// ── Response types ───────────────────────────────────────────────────────

pub const Response = union(enum) {
    ok: OkResponse,
    status: StatusResponse,
    err: []const u8,
};

pub const SessionInfo = struct {
    id: []const u8,
    type: ShareType,
    room: []const u8,
    viewers: u32,
    recording: bool,
    uptime_s: u64,
    title: []const u8 = "",
};

pub const OkResponse = struct {
    session_id: []const u8,
    room: []const u8,
};

pub const StatusResponse = struct {
    sessions: []const SessionInfo,
    room: ?[]const u8 = null,
};

// ── JSON serialization (stack-allocated, no heap) ────────────────────────

/// Parse a newline-delimited JSON request from raw bytes.
/// Returns the parsed request or null if malformed.
pub fn parseRequest(msg: []const u8) ?Request {
    const cmd = jsonExtract(msg, "cmd") orelse return null;

    if (std.mem.eql(u8, cmd, "share")) {
        var req = ShareRequest{};

        if (jsonExtract(msg, "type")) |t| {
            if (std.mem.eql(u8, t, "terminal")) {
                req.type = .terminal;
            } else if (std.mem.eql(u8, t, "app")) {
                req.type = .app;
            }
        }

        req.command = jsonExtract(msg, "command");

        if (jsonExtractInt(msg, "fps")) |f| {
            if (f >= 1 and f <= 144) req.fps = @intCast(f);
        }

        req.record = jsonExtractBool(msg, "record");

        if (jsonExtract(msg, "gpu")) |g| {
            if (std.mem.eql(u8, g, "nvidia")) {
                req.gpu = .nvidia;
            } else if (std.mem.eql(u8, g, "intel")) {
                req.gpu = .intel;
            }
        }

        if (jsonExtractInt(msg, "qp")) |q| {
            if (q >= 0 and q <= 51) req.qp = @intCast(q);
        }

        return .{ .share = req };
    } else if (std.mem.eql(u8, cmd, "join")) {
        return .{ .join = .{ .room = jsonExtract(msg, "room") } };
    } else if (std.mem.eql(u8, cmd, "leave")) {
        return .leave;
    } else if (std.mem.eql(u8, cmd, "unshare")) {
        var req = UnshareRequest{};
        req.session_id = jsonExtract(msg, "session_id");

        if (jsonExtract(msg, "type")) |t| {
            if (std.mem.eql(u8, t, "terminal")) {
                req.type = .terminal;
            } else if (std.mem.eql(u8, t, "app")) {
                req.type = .app;
            }
        }

        return .{ .unshare = req };
    } else if (std.mem.eql(u8, cmd, "status")) {
        return .status;
    } else if (std.mem.eql(u8, cmd, "shutdown")) {
        return .shutdown;
    }

    return null;
}

/// Write a JSON success response: {"ok":true,"session_id":"...","room":"..."}
pub fn writeOkResponse(buf: []u8, session_id: []const u8, room_url: []const u8) ?[]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    w.writeAll("{\"ok\":true,\"session_id\":\"") catch return null;
    writeJsonEscaped(w, session_id) catch return null;
    w.writeAll("\",\"room\":\"") catch return null;
    writeJsonEscaped(w, room_url) catch return null;
    w.writeAll("\"}\n") catch return null;
    return fbs.getWritten();
}

/// Write a JSON join response: {"ok":true,"room":"..."}
pub fn writeJoinResponse(buf: []u8, room_url: []const u8) ?[]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    w.writeAll("{\"ok\":true,\"room\":\"") catch return null;
    writeJsonEscaped(w, room_url) catch return null;
    w.writeAll("\"}\n") catch return null;
    return fbs.getWritten();
}

/// Write a JSON error response: {"ok":false,"error":"..."}
pub fn writeErrorResponse(buf: []u8, err_msg: []const u8) ?[]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    w.writeAll("{\"ok\":false,\"error\":\"") catch return null;
    writeJsonEscaped(w, err_msg) catch return null;
    w.writeAll("\"}\n") catch return null;
    return fbs.getWritten();
}

/// Write a JSON status response with session array and current room.
pub fn writeStatusResponse(buf: []u8, sessions: []const SessionInfo, room: ?[]const u8) ?[]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    w.writeAll("{\"ok\":true") catch return null;
    if (room) |r| {
        w.writeAll(",\"room\":\"") catch return null;
        writeJsonEscaped(w, r) catch return null;
        w.writeByte('"') catch return null;
    }
    w.writeAll(",\"sessions\":[") catch return null;
    for (sessions, 0..) |s, i| {
        if (i > 0) w.writeByte(',') catch return null;
        w.writeAll("{\"id\":\"") catch return null;
        writeJsonEscaped(w, s.id) catch return null;
        w.writeAll("\",\"type\":\"") catch return null;
        w.writeAll(@tagName(s.type)) catch return null;
        w.writeAll("\",\"room\":\"") catch return null;
        writeJsonEscaped(w, s.room) catch return null;
        w.writeAll("\",\"viewers\":") catch return null;
        std.fmt.format(w, "{d}", .{s.viewers}) catch return null;
        w.writeAll(",\"recording\":") catch return null;
        w.writeAll(if (s.recording) "true" else "false") catch return null;
        w.writeAll(",\"uptime_s\":") catch return null;
        std.fmt.format(w, "{d}", .{s.uptime_s}) catch return null;
        if (s.title.len > 0) {
            w.writeAll(",\"title\":\"") catch return null;
            writeJsonEscaped(w, s.title) catch return null;
            w.writeByte('"') catch return null;
        }
        w.writeByte('}') catch return null;
    }
    w.writeAll("]}\n") catch return null;
    return fbs.getWritten();
}

/// Write a simple {"ok":true} response (for unshare, shutdown).
pub fn writeSimpleOk(buf: []u8) ?[]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    w.writeAll("{\"ok\":true}\n") catch return null;
    return fbs.getWritten();
}

// ── Socket path ──────────────────────────────────────────────────────────

pub fn getSocketPath(buf: *[256]u8) ?[]const u8 {
    // XDG_RUNTIME_DIR is /run/user/$UID on systemd systems (Linux).
    // On macOS, falls back to /tmp/zerocast-$UID.sock.
    const runtime_dir = std.process.getEnvVarOwned(std.heap.c_allocator, "XDG_RUNTIME_DIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            const uid = std.posix.getuid();
            const path = std.fmt.bufPrint(buf, "/tmp/zerocast-{d}.sock", .{uid}) catch return null;
            return path;
        },
        else => return null,
    };
    defer std.heap.c_allocator.free(runtime_dir);

    const path = std.fmt.bufPrint(buf, "{s}/zerocast.sock", .{runtime_dir}) catch return null;
    return path;
}

// ── JSON helpers (same style as session.zig) ─────────────────────────────

/// Extract a JSON string value for a given key.
pub fn jsonExtract(json: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + key.len + 4 < json.len) : (i += 1) {
        if (json[i] == '"' and
            i + 1 + key.len + 3 <= json.len and
            std.mem.eql(u8, json[i + 1 .. i + 1 + key.len], key) and
            json[i + 1 + key.len] == '"' and
            json[i + 1 + key.len + 1] == ':' and
            json[i + 1 + key.len + 2] == '"')
        {
            const val_start = i + 1 + key.len + 3;
            var j = val_start;
            while (j < json.len) : (j += 1) {
                if (json[j] == '\\') {
                    j += 1;
                    continue;
                }
                if (json[j] == '"') {
                    return json[val_start..j];
                }
            }
        }
    }
    return null;
}

/// Extract a JSON integer value for a given key.
fn jsonExtractInt(json: []const u8, key: []const u8) ?i64 {
    // Look for "key":NUMBER pattern
    var i: usize = 0;
    while (i + key.len + 3 < json.len) : (i += 1) {
        if (json[i] == '"' and
            i + 1 + key.len + 2 <= json.len and
            std.mem.eql(u8, json[i + 1 .. i + 1 + key.len], key) and
            json[i + 1 + key.len] == '"' and
            json[i + 1 + key.len + 1] == ':')
        {
            const val_start = i + 1 + key.len + 2;
            var j = val_start;
            while (j < json.len and (json[j] >= '0' and json[j] <= '9')) : (j += 1) {}
            if (j > val_start) {
                return std.fmt.parseInt(i64, json[val_start..j], 10) catch null;
            }
        }
    }
    return null;
}

/// Extract a JSON boolean value for a given key.
fn jsonExtractBool(json: []const u8, key: []const u8) bool {
    // Look for "key":true pattern
    var i: usize = 0;
    while (i + key.len + 3 < json.len) : (i += 1) {
        if (json[i] == '"' and
            i + 1 + key.len + 2 <= json.len and
            std.mem.eql(u8, json[i + 1 .. i + 1 + key.len], key) and
            json[i + 1 + key.len] == '"' and
            json[i + 1 + key.len + 1] == ':')
        {
            const val_start = i + 1 + key.len + 2;
            if (val_start + 4 <= json.len and std.mem.eql(u8, json[val_start .. val_start + 4], "true")) {
                return true;
            }
        }
    }
    return false;
}

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(ch),
        }
    }
}

// ── Room ID generation ───────────────────────────────────────────────────

pub fn generateRoomId() [16]u8 {
    var bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    var hex: [16]u8 = undefined;
    const charset = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        hex[i * 2] = charset[b >> 4];
        hex[i * 2 + 1] = charset[b & 0x0f];
    }
    return hex;
}

// ── Tests ────────────────────────────────────────────────────────────────

test "parseRequest share app" {
    const msg =
        \\{"cmd":"share","type":"app","command":"glxgears","fps":30}
    ;
    const req = parseRequest(msg).?;
    switch (req) {
        .share => |s| {
            try std.testing.expectEqual(ShareType.app, s.type);
            try std.testing.expectEqualSlices(u8, "glxgears", s.command.?);
            try std.testing.expectEqual(@as(u32, 30), s.fps);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseRequest join with room" {
    const msg =
        \\{"cmd":"join","room":"my-room"}
    ;
    const req = parseRequest(msg).?;
    switch (req) {
        .join => |j| {
            try std.testing.expectEqualSlices(u8, "my-room", j.room.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseRequest join without room" {
    const msg =
        \\{"cmd":"join"}
    ;
    const req = parseRequest(msg).?;
    switch (req) {
        .join => |j| {
            try std.testing.expect(j.room == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseRequest leave" {
    const msg =
        \\{"cmd":"leave"}
    ;
    const req = parseRequest(msg).?;
    try std.testing.expect(req == .leave);
}

test "parseRequest share terminal" {
    const msg =
        \\{"cmd":"share","type":"terminal","command":"htop","record":false}
    ;
    const req = parseRequest(msg).?;
    switch (req) {
        .share => |s| {
            try std.testing.expectEqual(ShareType.terminal, s.type);
            try std.testing.expectEqualSlices(u8, "htop", s.command.?);
            try std.testing.expect(!s.record);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseRequest unshare all" {
    const msg =
        \\{"cmd":"unshare"}
    ;
    const req = parseRequest(msg).?;
    switch (req) {
        .unshare => |u| {
            try std.testing.expect(u.session_id == null);
            try std.testing.expect(u.type == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseRequest unshare by id" {
    const msg =
        \\{"cmd":"unshare","session_id":"a3f9c12d"}
    ;
    const req = parseRequest(msg).?;
    switch (req) {
        .unshare => |u| {
            try std.testing.expectEqualSlices(u8, "a3f9c12d", u.session_id.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseRequest unshare by type" {
    const msg =
        \\{"cmd":"unshare","type":"app"}
    ;
    const req = parseRequest(msg).?;
    switch (req) {
        .unshare => |u| {
            try std.testing.expectEqual(ShareType.app, u.type.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseRequest status" {
    const msg =
        \\{"cmd":"status"}
    ;
    const req = parseRequest(msg).?;
    try std.testing.expect(req == .status);
}

test "parseRequest shutdown" {
    const msg =
        \\{"cmd":"shutdown"}
    ;
    const req = parseRequest(msg).?;
    try std.testing.expect(req == .shutdown);
}

test "parseRequest malformed" {
    try std.testing.expect(parseRequest("not json") == null);
    try std.testing.expect(parseRequest("{}") == null);
    try std.testing.expect(parseRequest("{\"cmd\":\"bogus\"}") == null);
}

test "writeOkResponse roundtrip" {
    var buf: [512]u8 = undefined;
    const resp = writeOkResponse(&buf, "a3f9c12d", "https://zerocast.bodar.com/room/a3f9c12d").?;
    try std.testing.expect(jsonExtract(resp, "session_id") != null);
    try std.testing.expectEqualSlices(u8, "a3f9c12d", jsonExtract(resp, "session_id").?);
}

test "writeErrorResponse roundtrip" {
    var buf: [512]u8 = undefined;
    const resp = writeErrorResponse(&buf, "no session with that ID").?;
    try std.testing.expect(jsonExtract(resp, "error") != null);
    try std.testing.expectEqualSlices(u8, "no session with that ID", jsonExtract(resp, "error").?);
}

test "writeStatusResponse empty" {
    var buf: [512]u8 = undefined;
    const resp = writeStatusResponse(&buf, &.{}, null).?;
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"sessions\":[]") != null);
}

test "writeStatusResponse with room" {
    var buf: [512]u8 = undefined;
    const resp = writeStatusResponse(&buf, &.{}, "my-room").?;
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"room\":\"my-room\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"sessions\":[]") != null);
}

test "writeStatusResponse with session" {
    var buf: [1024]u8 = undefined;
    const sessions = [_]SessionInfo{.{
        .id = "abc123",
        .type = .app,
        .room = "https://example.com/room/abc123",
        .viewers = 2,
        .recording = true,
        .uptime_s = 3600,
    }};
    const resp = writeStatusResponse(&buf, &sessions, null).?;
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"abc123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"viewers\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"recording\":true") != null);
}

test "writeSimpleOk" {
    var buf: [64]u8 = undefined;
    const resp = writeSimpleOk(&buf).?;
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":true") != null);
}

test "jsonExtract matches session.zig behavior" {
    const json = "{\"type\":\"answer\",\"sdp\":\"v=0\\r\\n\"}";
    try std.testing.expectEqualSlices(u8, "answer", jsonExtract(json, "type").?);
    try std.testing.expectEqualSlices(u8, "v=0\\r\\n", jsonExtract(json, "sdp").?);
    try std.testing.expect(jsonExtract(json, "missing") == null);
}

test "jsonExtractInt" {
    const json = "{\"cmd\":\"share\",\"fps\":60,\"record\":true}";
    try std.testing.expectEqual(@as(i64, 60), jsonExtractInt(json, "fps").?);
    try std.testing.expect(jsonExtractInt(json, "missing") == null);
}

test "jsonExtractBool" {
    const json = "{\"cmd\":\"share\",\"record\":true,\"other\":false}";
    try std.testing.expect(jsonExtractBool(json, "record"));
    try std.testing.expect(!jsonExtractBool(json, "other"));
    try std.testing.expect(!jsonExtractBool(json, "missing"));
}

test "generateRoomId produces 16 hex chars" {
    const id = generateRoomId();
    try std.testing.expectEqual(@as(usize, 16), id.len);
    for (id) |ch| {
        try std.testing.expect((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'));
    }
}

test "generateRoomId produces unique values" {
    const a = generateRoomId();
    const b = generateRoomId();
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "getSocketPath returns valid path" {
    var buf: [256]u8 = undefined;
    const path = getSocketPath(&buf);
    try std.testing.expect(path != null);
    try std.testing.expect(path.?.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, path.?, ".sock"));
}

test "writeJsonEscaped handles special characters" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    writeJsonEscaped(w, "hello \"world\"\nfoo\\bar\t") catch unreachable;
    const result = fbs.getWritten();
    try std.testing.expectEqualSlices(u8, "hello \\\"world\\\"\\nfoo\\\\bar\\t", result);
}

test "writeJsonEscaped empty string" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    writeJsonEscaped(w, "") catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), fbs.getWritten().len);
}

test "jsonExtract with escaped quote in value" {
    const json = "{\"key\":\"value with \\\"quotes\\\"\"}";
    const result = jsonExtract(json, "key");
    try std.testing.expect(result != null);
    try std.testing.expectEqualSlices(u8, "value with \\\"quotes\\\"", result.?);
}

test "parseRequest share with qp" {
    const msg =
        \\{"cmd":"share","type":"app","command":"glxgears","qp":24}
    ;
    const req = parseRequest(msg).?;
    switch (req) {
        .share => |s| {
            try std.testing.expectEqual(@as(u32, 24), s.qp);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseRequest share with gpu nvidia" {
    const msg =
        \\{"cmd":"share","type":"app","command":"code","gpu":"nvidia"}
    ;
    const req = parseRequest(msg).?;
    switch (req) {
        .share => |s| {
            try std.testing.expectEqual(GpuBackend.nvidia, s.gpu);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseRequest share defaults" {
    const msg =
        \\{"cmd":"share","type":"app","command":"glxgears"}
    ;
    const req = parseRequest(msg).?;
    switch (req) {
        .share => |s| {
            try std.testing.expectEqual(GpuBackend.auto, s.gpu);
            try std.testing.expectEqual(@as(u32, 20), s.qp);
            try std.testing.expectEqual(@as(u32, 30), s.fps);
        },
        else => return error.TestUnexpectedResult,
    }
}
