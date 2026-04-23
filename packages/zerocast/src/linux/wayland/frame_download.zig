//! CPU-side frame ingestion for the software SVT-AV1 encoder backend.
//!
//! Reads the current colour attachment out of a wlroots-owned GL
//! framebuffer via `glReadPixels` (RGBA), then converts to I420 YUV
//! using the shared BT.709 limited-range converter. The result is a
//! stable byte slice the caller hands to `SvtBackend.setPendingYuv`
//! before each `prepare → encode` cycle.
//!
//! Caller semantics are unchanged: the encode loop still delivers a GL
//! surface to the backend each frame — only the hand-off medium
//! differs. The hardware NVENC path consumes an FBO id directly; the
//! software path downloads the FBO to a staging CPU buffer. The public
//! surface exposed to callers is the same `FrameSink` / `EncodeBackend`
//! interface in both cases.
//!
//! Requires an active GL context (same thread that drives the
//! compositor). Safe to call from the encode loop thread; must not be
//! called from a worker thread.

const std = @import("std");
const yuv = @import("yuv");

const log = std.log.scoped(.frame_download);

const c = @cImport({
    @cInclude("GLES2/gl2.h");
});

pub const Error = error{
    OutOfMemory,
    ConversionFailed,
};

/// Owns reusable RGBA staging + I420 output buffers sized for one
/// capture frame. Resize reallocates both; teardown frees both.
pub const FrameDownloader = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    rgba_buf: []u8,
    i420_buf: []u8,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !FrameDownloader {
        const rgba = try allocator.alloc(u8, @as(usize, width) * height * 4);
        errdefer allocator.free(rgba);
        const i420_buf = try allocator.alloc(u8, yuv.i420Size(width, height));
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .rgba_buf = rgba,
            .i420_buf = i420_buf,
        };
    }

    pub fn deinit(self: *FrameDownloader) void {
        self.allocator.free(self.rgba_buf);
        self.allocator.free(self.i420_buf);
    }

    /// Reallocate buffers for a new resolution. Called from the resize
    /// path so the downloader tracks the compositor's current output
    /// size.
    pub fn resize(self: *FrameDownloader, width: u32, height: u32) !void {
        if (self.width == width and self.height == height) return;

        const new_rgba = try self.allocator.alloc(u8, @as(usize, width) * height * 4);
        errdefer self.allocator.free(new_rgba);
        const new_i420 = try self.allocator.alloc(u8, yuv.i420Size(width, height));
        errdefer self.allocator.free(new_i420);

        self.allocator.free(self.rgba_buf);
        self.allocator.free(self.i420_buf);
        self.rgba_buf = new_rgba;
        self.i420_buf = new_i420;
        self.width = width;
        self.height = height;
    }

    /// Download the FBO's colour attachment into the staging RGBA buffer
    /// and convert to I420. Returns a slice covering the tight I420
    /// layout so the caller can pass it straight into
    /// `SvtBackend.setPendingYuv`.
    ///
    /// Must be called on the thread that owns the GL context.
    pub fn downloadFromFbo(self: *FrameDownloader, fbo: u32) Error![]const u8 {
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
        c.glPixelStorei(c.GL_PACK_ALIGNMENT, 1);
        c.glReadPixels(
            0,
            0,
            @intCast(self.width),
            @intCast(self.height),
            c.GL_RGBA,
            c.GL_UNSIGNED_BYTE,
            self.rgba_buf.ptr,
        );
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);

        yuv.rgbaToI420Bt709Limited(self.rgba_buf, self.width, self.height, self.i420_buf) catch |err| {
            log.err("rgbaToI420 failed: {}", .{err});
            return Error.ConversionFailed;
        };

        return self.i420_buf[0..yuv.i420Size(self.width, self.height)];
    }
};
