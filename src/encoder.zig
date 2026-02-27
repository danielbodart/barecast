const std = @import("std");
const nvfbc = @import("nvfbc");
const Cuda = @import("cuda").Cuda;
const NvencEncoder = @import("nvenc").Nvenc;
const IvfWriter = @import("ivf").IvfWriter;

const fps_num: u32 = 30;
const fps_den: u32 = 1;

pub const Stats = struct {
    frames_encoded: u64 = 0,
    frames_skipped: u64 = 0,
    keyframes: u64 = 0,
    total_bytes: u64 = 0,
};

pub const Encoder = struct {
    cuda_ctx: Cuda,
    nvenc: NvencEncoder,
    ivf: IvfWriter,
    stats: Stats,
    width: u32,
    height: u32,
    keyframe_interval: u32,

    pub fn init(
        fbc: *nvfbc.NvFbc,
        first_frame: nvfbc.FrameResult,
        output_path: []const u8,
    ) !Encoder {
        var cu = try Cuda.init(first_frame.texture_id, first_frame.width, first_frame.height);
        errdefer cu.deinit();

        var enc = try NvencEncoder.init(&cu);
        errdefer enc.deinit();

        var ivf = try IvfWriter.init(output_path);
        errdefer ivf.deinit();

        _ = fbc; // NvFBC reference retained for future use (e.g. texture slot management)

        return .{
            .cuda_ctx = cu,
            .nvenc = enc,
            .ivf = ivf,
            .stats = .{},
            .width = first_frame.width,
            .height = first_frame.height,
            .keyframe_interval = 120,
        };
    }

    /// Process one captured frame: CUDA copy → NVENC encode → IVF write.
    pub fn processFrame(self: *Encoder, frame: nvfbc.FrameResult) !void {
        if (!frame.is_new) {
            self.stats.frames_skipped += 1;
            return;
        }

        // Copy GL texture to linear CUDA device memory
        try self.cuda_ctx.copyGlTexture();

        // Encode
        const force_key = self.stats.frames_encoded % self.keyframe_interval == 0;
        const maybe_encoded = try self.nvenc.encodeFrame(force_key);

        if (maybe_encoded) |encoded| {
            defer self.nvenc.unlockBitstream();

            try self.ivf.writeFrame(encoded.data, encoded.pts);
            self.stats.total_bytes += encoded.data.len;
            if (encoded.is_key) self.stats.keyframes += 1;
        }

        self.stats.frames_encoded += 1;
    }

    /// Flush encoder, drain buffered frames, and finalize IVF file.
    pub fn finish(self: *Encoder) !void {
        try self.nvenc.flush();

        // Drain any trailing frames
        while (try self.nvenc.drainFrame()) |frame| {
            defer self.nvenc.unlockBitstream();
            try self.ivf.writeFrame(frame.data, frame.pts);
            self.stats.total_bytes += frame.data.len;
            if (frame.is_key) self.stats.keyframes += 1;
        }

        try self.ivf.finalize(
            @intCast(self.width),
            @intCast(self.height),
            fps_num,
            fps_den,
        );
    }

    pub fn deinit(self: *Encoder) void {
        self.nvenc.deinit();
        self.cuda_ctx.deinit();
        self.ivf.deinit();
    }
};
