const std = @import("std");
const Cuda = @import("cuda").Cuda;
const NvencEncoder = @import("nvenc").Nvenc;
const NvencEncodedFrame = @import("nvenc").EncodedFrame;
const Codec = @import("codec").Codec;
const encoder = @import("encoder");

/// NVIDIA CUDA + NVENC encoder backend.
/// Manages the CUDA GL-texture copy and NVENC hardware encoder.
pub const NvencBackend = struct {
    cuda_ctx: Cuda,
    nvenc: NvencEncoder,

    pub fn init(texture_id: u32, width: u32, height: u32, fps: u32) !NvencBackend {
        var cu = try Cuda.init(texture_id, width, height);
        errdefer cu.deinit();

        var enc = try NvencEncoder.init(&cu, fps);
        errdefer enc.deinit();

        return .{
            .cuda_ctx = cu,
            .nvenc = enc,
        };
    }

    /// Return the codec detected by NVENC (AV1 or HEVC).
    pub fn codec(self: *const NvencBackend) Codec {
        return self.nvenc.codec;
    }

    /// Return an EncodeBackend vtable pointing to this instance.
    /// The NvencBackend must be at a stable memory address.
    pub fn backend(self: *NvencBackend) encoder.EncodeBackend {
        return .{
            .ptr = @ptrCast(self),
            .prepareFn = @ptrCast(&prepareFn),
            .encodeFn = @ptrCast(&encodeFn),
            .unlockFn = @ptrCast(&unlockFn),
            .deinitFn = @ptrCast(&deinitFn),
        };
    }

    fn prepareFn(self: *NvencBackend) !void {
        try self.cuda_ctx.copyGlTexture();
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
