const std = @import("std");

/// IVF container writer for AV1 bitstreams (AV1 only — HEVC uses raw Annex B).
/// Format: 32-byte file header + (12-byte frame header + OBU data) per frame.
pub const IvfWriter = struct {
    file: std.fs.File,
    frame_count: u32,

    pub fn init(path: []const u8) !IvfWriter {
        return initDir(std.fs.cwd(), path);
    }

    pub fn initDir(dir: std.fs.Dir, name: []const u8) !IvfWriter {
        const file = try dir.createFile(name, .{});
        errdefer file.close();

        // Write 32-byte file header (all fields zero — patched in finalize)
        try file.writeAll(&[_]u8{0} ** 32);

        return .{ .file = file, .frame_count = 0 };
    }

    /// Write the 32-byte IVF file header. Call after all frames are written.
    pub fn finalize(self: *IvfWriter, width: u16, height: u16, fps_num: u32, fps_den: u32) !void {
        var hdr: [32]u8 = undefined;

        // bytes 0-3: "DKIF" magic
        hdr[0] = 'D';
        hdr[1] = 'K';
        hdr[2] = 'I';
        hdr[3] = 'F';

        // bytes 4-5: version = 0
        std.mem.writeInt(u16, hdr[4..6], 0, .little);

        // bytes 6-7: header size = 32
        std.mem.writeInt(u16, hdr[6..8], 32, .little);

        // bytes 8-11: codec FourCC "AV01"
        hdr[8] = 'A';
        hdr[9] = 'V';
        hdr[10] = '0';
        hdr[11] = '1';

        // bytes 12-13: width
        std.mem.writeInt(u16, hdr[12..14], width, .little);

        // bytes 14-15: height
        std.mem.writeInt(u16, hdr[14..16], height, .little);

        // bytes 16-19: frame rate numerator
        std.mem.writeInt(u32, hdr[16..20], fps_num, .little);

        // bytes 20-23: frame rate denominator
        std.mem.writeInt(u32, hdr[20..24], fps_den, .little);

        // bytes 24-27: frame count
        std.mem.writeInt(u32, hdr[24..28], self.frame_count, .little);

        // bytes 28-31: unused
        std.mem.writeInt(u32, hdr[28..32], 0, .little);

        // Seek to start and overwrite
        try self.file.seekTo(0);
        try self.file.writeAll(&hdr);

        // Seek back to end for any further writes
        try self.file.seekFromEnd(0);
    }

    /// Write one encoded frame: 12-byte header + raw AV1 OBU data.
    pub fn writeFrame(self: *IvfWriter, data: []const u8, pts: u64) !void {
        var frame_hdr: [12]u8 = undefined;

        // bytes 0-3: frame size in bytes
        std.mem.writeInt(u32, frame_hdr[0..4], @intCast(data.len), .little);

        // bytes 4-11: presentation timestamp
        std.mem.writeInt(u64, frame_hdr[4..12], pts, .little);

        try self.file.writeAll(&frame_hdr);
        try self.file.writeAll(data);

        self.frame_count += 1;
    }

    pub fn deinit(self: *IvfWriter) void {
        self.file.close();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "IVF file header is 32 bytes with correct magic and codec" {
    const tmp = try std.fs.cwd().createFile("test_ivf_header.ivf", .{ .read = true });
    defer {
        tmp.close();
        std.fs.cwd().deleteFile("test_ivf_header.ivf") catch {};
    }

    var writer = IvfWriter{ .file = tmp, .frame_count = 0 };
    // Write placeholder header
    try tmp.writeAll(&[_]u8{0} ** 32);
    try writer.finalize(1920, 1080, 30, 1);

    // Read back and verify
    try tmp.seekTo(0);
    var buf: [32]u8 = undefined;
    const n = try tmp.readAll(&buf);
    try std.testing.expectEqual(@as(usize, 32), n);

    // Magic "DKIF"
    try std.testing.expectEqualSlices(u8, "DKIF", buf[0..4]);

    // Version = 0
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, buf[4..6], .little));

    // Header size = 32
    try std.testing.expectEqual(@as(u16, 32), std.mem.readInt(u16, buf[6..8], .little));

    // Codec "AV01"
    try std.testing.expectEqualSlices(u8, "AV01", buf[8..12]);

    // Width/height
    try std.testing.expectEqual(@as(u16, 1920), std.mem.readInt(u16, buf[12..14], .little));
    try std.testing.expectEqual(@as(u16, 1080), std.mem.readInt(u16, buf[14..16], .little));

    // FPS
    try std.testing.expectEqual(@as(u32, 30), std.mem.readInt(u32, buf[16..20], .little));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, buf[20..24], .little));
}

test "IVF writeFrame produces correct 12-byte header + data" {
    const tmp = try std.fs.cwd().createFile("test_ivf_frame.ivf", .{ .read = true });
    defer {
        tmp.close();
        std.fs.cwd().deleteFile("test_ivf_frame.ivf") catch {};
    }

    var writer = IvfWriter{ .file = tmp, .frame_count = 0 };

    const payload = "hello AV1";
    try writer.writeFrame(payload, 42);

    try std.testing.expectEqual(@as(u32, 1), writer.frame_count);

    // Read back frame header
    try tmp.seekTo(0);
    var hdr: [12]u8 = undefined;
    _ = try tmp.readAll(&hdr);

    // Frame size
    try std.testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, hdr[0..4], .little));

    // PTS
    try std.testing.expectEqual(@as(u64, 42), std.mem.readInt(u64, hdr[4..12], .little));

    // Payload
    var data: [9]u8 = undefined;
    _ = try tmp.readAll(&data);
    try std.testing.expectEqualSlices(u8, payload, &data);
}

test "IVF finalize patches frame count at byte offset 24" {
    const tmp = try std.fs.cwd().createFile("test_ivf_count.ivf", .{ .read = true });
    defer {
        tmp.close();
        std.fs.cwd().deleteFile("test_ivf_count.ivf") catch {};
    }

    var writer = IvfWriter{ .file = tmp, .frame_count = 0 };
    try tmp.writeAll(&[_]u8{0} ** 32); // placeholder header

    // Write 3 frames
    try writer.writeFrame("aaa", 0);
    try writer.writeFrame("bbb", 1);
    try writer.writeFrame("ccc", 2);

    try std.testing.expectEqual(@as(u32, 3), writer.frame_count);

    try writer.finalize(640, 480, 60, 1);

    // Read frame count from byte 24
    try tmp.seekTo(24);
    var count_buf: [4]u8 = undefined;
    _ = try tmp.readAll(&count_buf);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, &count_buf, .little));
}
