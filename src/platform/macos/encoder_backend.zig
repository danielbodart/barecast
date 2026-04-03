const std = @import("std");
const encoder = @import("encoder");

const c = @cImport({
    @cInclude("videotoolbox.h");
});

const log = std.log.scoped(.videotoolbox);

/// VideoToolbox HEVC encoder backend for macOS.
/// Wraps the ObjC VTCompressionSession via C API.
pub const VideoToolboxBackend = EncoderBackend;

pub const EncoderBackend = struct {
    vt: *c.VTEncoder,
    pixel_buffer: ?*anyopaque,

    pub fn init(width: u32, height: u32, fps: u32) !EncoderBackend {
        const vt = c.vt_encoder_create(width, height, fps) orelse {
            log.err("VTCompressionSession creation failed", .{});
            return error.VideoToolboxInitFailed;
        };
        return .{
            .vt = vt,
            .pixel_buffer = null,
        };
    }

    /// Set the pixel buffer to encode on the next prepare+encode cycle.
    /// The caller retains ownership; the buffer must remain valid until
    /// after encode() returns.
    pub fn setPixelBuffer(self: *EncoderBackend, pb: *anyopaque) void {
        self.pixel_buffer = pb;
    }

    /// Return an EncodeBackend vtable pointing to this instance.
    pub fn backend(self: *EncoderBackend) encoder.EncodeBackend {
        return .{
            .ptr = @ptrCast(self),
            .codec = .hevc,
            .prepareFn = @ptrCast(&prepareFn),
            .encodeFn = @ptrCast(&encodeFn),
            .unlockFn = @ptrCast(&unlockFn),
            .deinitFn = @ptrCast(&deinitFn),
        };
    }

    fn prepareFn(_: *EncoderBackend) !void {
        // No-op: pixel buffer is set by the capture layer via setPixelBuffer.
        // On Linux, this is where CUDA copies the GL texture.
    }

    fn encodeFn(self: *EncoderBackend, force_key: bool) !?encoder.EncodedFrame {
        const pb = self.pixel_buffer orelse return error.NoPixelBuffer;

        const result = c.vt_encoder_encode(self.vt, pb, @intFromBool(force_key));
        if (result != 0) {
            log.err("VTCompressionSession encode failed: {d}", .{result});
            return error.VideoToolboxEncodeFailed;
        }

        var out_len: usize = 0;
        var out_is_key: c_int = 0;
        const data_ptr = c.vt_encoder_get_output(self.vt, &out_len, &out_is_key);
        if (data_ptr == null or out_len == 0) return null;

        return .{
            .data = data_ptr[0..out_len],
            .is_key = out_is_key != 0,
            .pts = 0, // PTS managed by Encoder orchestrator
        };
    }

    fn unlockFn(_: *EncoderBackend) void {
        // No-op: the output buffer is a global in videotoolbox.m,
        // valid until the next encode call.
    }

    fn deinitFn(self: *EncoderBackend) void {
        c.vt_encoder_destroy(self.vt);
        c.vt_encoder_cleanup_globals();
    }
};
