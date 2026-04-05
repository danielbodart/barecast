const std = @import("std");
const VaapiEncoder = @import("vaapi").Vaapi;
const Codec = @import("codec").Codec;
const encoder = @import("encoder");

/// VA-API hardware encoder backend (Intel QSV / AMD VCN).
/// Manages the VA-API encode session and implements the EncodeBackend vtable.
pub const VaapiBackend = EncoderBackend;

pub const EncoderBackend = struct {
    vaapi: VaapiEncoder,

    pub fn init(render_path: [*:0]const u8, width: u32, height: u32, fps: u32) !EncoderBackend {
        var enc = try VaapiEncoder.init(render_path, width, height, fps);
        errdefer enc.deinit();

        return .{ .vaapi = enc };
    }

    /// Return the codec detected by VA-API (AV1 or HEVC).
    pub fn codec(self: *const EncoderBackend) Codec {
        return self.vaapi.codec;
    }

    /// Export the encode surface for EGL interop (double DMA-BUF trick).
    pub fn exportSurface(self: *EncoderBackend) !@import("vaapi").ExportedSurface {
        return self.vaapi.exportSurface();
    }

    /// Return an EncodeBackend vtable pointing to this instance.
    /// The VaapiBackend must be at a stable memory address.
    pub fn backend(self: *EncoderBackend) encoder.EncodeBackend {
        return .{
            .ptr = @ptrCast(self),
            .codec = self.vaapi.codec,
            .prepareFn = @ptrCast(&prepareFn),
            .encodeFn = @ptrCast(&encodeFn),
            .unlockFn = @ptrCast(&unlockFn),
            .deinitFn = @ptrCast(&deinitFn),
        };
    }

    fn prepareFn(_: *EncoderBackend) !void {
        // No-op: the EGL color conversion shader writes directly into
        // the VA-API surface via the exported DMA-BUF. By the time
        // prepareFn is called, the surface already contains the frame.
    }

    fn encodeFn(self: *EncoderBackend, force_key: bool) !?encoder.EncodedFrame {
        const result = try self.vaapi.encodeFrame(force_key);
        if (result) |frame| {
            return .{
                .data = frame.data,
                .is_key = frame.is_key,
                .pts = frame.pts,
            };
        }
        return null;
    }

    fn unlockFn(self: *EncoderBackend) void {
        self.vaapi.unlockBitstream();
    }

    fn deinitFn(self: *EncoderBackend) void {
        self.vaapi.deinit();
    }
};
