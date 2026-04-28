//! CPU-side frame ingestion for the macOS SVT-AV1 software backend.
//!
//! Reads a CVPixelBuffer produced by ScreenCaptureKit (BGRA, default
//! kCVPixelFormatType_32BGRA), optionally strips row padding into a
//! tight staging buffer, then converts to BT.709 limited-range I420
//! via the shared `yuv` helper. The result is the I420 slice the
//! encode loop hands to `SvtBackend.setPendingYuv`.
//!
//! Caller semantics mirror the Linux Wayland downloader: the callback
//! holds a CVPixelBuffer pointer; the downloader exposes a single
//! `downloadFromPixelBuffer` entry point that yields an I420 slice.

const std = @import("std");
const yuv = @import("yuv");

const c = @cImport({
    @cInclude("screen_capture.h");
});

const log = std.log.scoped(.frame_download);

pub const Error = error{
    OutOfMemory,
    LockFailed,
    SizeMismatch,
    ConversionFailed,
};

/// Owns reusable tight-packed BGRA + I420 output buffers. The tight
/// buffer is only used when the CVPixelBuffer has stride padding
/// (bytes_per_row != width * 4) — when the source is already
/// tightly packed, the converter reads the buffer in place.
pub const FrameDownloader = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    tight_buf: []u8,
    i420_buf: []u8,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !FrameDownloader {
        const tight = try allocator.alloc(u8, @as(usize, width) * height * 4);
        errdefer allocator.free(tight);
        const i420_buf = try allocator.alloc(u8, yuv.i420Size(width, height));
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .tight_buf = tight,
            .i420_buf = i420_buf,
        };
    }

    pub fn deinit(self: *FrameDownloader) void {
        self.allocator.free(self.tight_buf);
        self.allocator.free(self.i420_buf);
    }

    pub fn resize(self: *FrameDownloader, width: u32, height: u32) !void {
        if (self.width == width and self.height == height) return;

        const new_tight = try self.allocator.alloc(u8, @as(usize, width) * height * 4);
        errdefer self.allocator.free(new_tight);
        const new_i420 = try self.allocator.alloc(u8, yuv.i420Size(width, height));
        errdefer self.allocator.free(new_i420);

        self.allocator.free(self.tight_buf);
        self.allocator.free(self.i420_buf);
        self.tight_buf = new_tight;
        self.i420_buf = new_i420;
        self.width = width;
        self.height = height;
    }

    /// Lock the CVPixelBuffer, convert to I420, unlock. Returns a slice
    /// of the internal I420 output — valid until the next call to this
    /// function.
    pub fn downloadFromPixelBuffer(self: *FrameDownloader, pb: *anyopaque) Error![]const u8 {
        var lock: c.SCPixelBufferLock = undefined;
        if (c.sc_pixel_buffer_lock(pb, &lock) != 0) return Error.LockFailed;
        defer c.sc_pixel_buffer_unlock(pb);

        if (lock.width != self.width or lock.height != self.height) {
            log.err("pixel buffer size {d}x{d} != downloader {d}x{d}", .{
                lock.width, lock.height, self.width, self.height,
            });
            return Error.SizeMismatch;
        }

        const tight_row = @as(usize, self.width) * 4;
        const src_bytes: [*]const u8 = @ptrCast(lock.bytes);

        if (lock.bytes_per_row == tight_row) {
            const tight_len = tight_row * self.height;
            yuv.bgraToI420Bt709Limited(src_bytes[0..tight_len], self.width, self.height, self.i420_buf) catch |err| {
                log.err("bgraToI420 failed: {}", .{err});
                return Error.ConversionFailed;
            };
        } else {
            // Strip stride padding into the tight staging buffer.
            var row: u32 = 0;
            while (row < self.height) : (row += 1) {
                const src_off = @as(usize, row) * lock.bytes_per_row;
                const dst_off = @as(usize, row) * tight_row;
                @memcpy(self.tight_buf[dst_off .. dst_off + tight_row], src_bytes[src_off .. src_off + tight_row]);
            }
            yuv.bgraToI420Bt709Limited(self.tight_buf, self.width, self.height, self.i420_buf) catch |err| {
                log.err("bgraToI420 failed: {}", .{err});
                return Error.ConversionFailed;
            };
        }

        return self.i420_buf[0..yuv.i420Size(self.width, self.height)];
    }
};
