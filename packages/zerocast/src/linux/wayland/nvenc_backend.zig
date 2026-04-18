const std = @import("std");
const Cuda = @import("cuda").Cuda;
const NvencEncoder = @import("nvenc").Nvenc;
const NvencEncodedFrame = @import("nvenc").EncodedFrame;
const Codec = @import("codec").Codec;
const encoder = @import("encoder");
const log = std.log.scoped(.nvenc);

/// NVIDIA CUDA + NVENC encoder backend for Wayland compositor.
/// Reads frames directly from the compositor's GL renderbuffer via CUDA interop,
/// then encodes with NVENC. Zero-copy GPU path — no DMA-BUF export/import needed.
pub const NvencBackend = struct {
    cuda_ctx: Cuda,
    nvenc: NvencEncoder,

    /// FBO id to blit from (set by app_share before each processFrame)
    pending_fbo: u32 = 0,

    pub fn init(width: u32, height: u32, fps: u32, qp: u32) !NvencBackend {
        var cu = try Cuda.init(width, height);
        errdefer cu.deinit();

        var enc = try NvencEncoder.init(&cu, fps, qp);
        errdefer enc.deinit();

        return .{
            .cuda_ctx = cu,
            .nvenc = enc,
        };
    }

    pub fn codec(self: *const NvencBackend) Codec {
        return self.nvenc.codec;
    }

    /// Return an EncodeBackend vtable pointing to this instance.
    pub fn backend(self: *NvencBackend) encoder.EncodeBackend {
        return .{
            .ptr = @ptrCast(self),
            .codec = self.nvenc.codec,
            .prepareFn = @ptrCast(&prepareFn),
            .encodeFn = @ptrCast(&encodeFn),
            .unlockFn = @ptrCast(&unlockFn),
            .deinitFn = @ptrCast(&deinitFn),
        };
    }

    fn prepareFn(self: *NvencBackend) !void {
        if (self.pending_fbo == 0) {
            log.err("prepareFn: no pending FBO", .{});
            return error.NoFbo;
        }
        try self.cuda_ctx.copyFromFbo(self.pending_fbo);
    }

    fn encodeFn(self: *NvencBackend, force_key: bool) !?encoder.EncodedFrame {
        const result = try self.nvenc.encodeFrame(force_key);
        if (result) |frame| {
            return .{
                .data = frame.data,
                .is_key = frame.is_key,
                .pts = frame.pts,
            };
        }
        return null;
    }

    fn unlockFn(self: *NvencBackend) void {
        self.nvenc.unlockBitstream();
    }

    fn deinitFn(self: *NvencBackend) void {
        self.nvenc.deinit();
        self.cuda_ctx.deinit();
    }
};
