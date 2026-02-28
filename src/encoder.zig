const std = @import("std");
const nvfbc = @import("nvfbc");
const Cuda = @import("cuda").Cuda;
const NvencEncoder = @import("nvenc").Nvenc;
const IvfWriter = @import("ivf").IvfWriter;
const BroadcastSession = @import("session").BroadcastSession;

pub const FrameSink = union(enum) {
    ivf: IvfWriter,
    session: *BroadcastSession,
};

pub const Stats = struct {
    frames_encoded: u64 = 0,
    frames_skipped: u64 = 0,
    keyframes: u64 = 0,
    total_bytes: u64 = 0,
};

pub const Encoder = struct {
    cuda_ctx: Cuda,
    nvenc: NvencEncoder,
    sink: FrameSink,
    stats: Stats,
    timer: std.time.Timer,
    width: u32,
    height: u32,
    keyframe_interval: u32,

    pub fn init(
        fbc: *nvfbc.NvFbc,
        first_frame: nvfbc.FrameResult,
        sink: FrameSink,
    ) !Encoder {
        var cu = try Cuda.init(first_frame.texture_id, first_frame.width, first_frame.height);
        errdefer cu.deinit();

        var enc = try NvencEncoder.init(&cu);
        errdefer enc.deinit();

        _ = fbc; // NvFBC reference retained for future use (e.g. texture slot management)

        return .{
            .cuda_ctx = cu,
            .nvenc = enc,
            .sink = sink,
            .stats = .{},
            .timer = try std.time.Timer.start(),
            .width = first_frame.width,
            .height = first_frame.height,
            .keyframe_interval = 120,
        };
    }

    /// Process one captured frame: CUDA copy → NVENC encode → sink dispatch.
    pub fn processFrame(self: *Encoder, frame: nvfbc.FrameResult) !void {
        if (!frame.is_new) {
            self.stats.frames_skipped += 1;
            return;
        }

        // Real wall clock PTS in milliseconds
        const pts_ms = self.timer.read() / std.time.ns_per_ms;
        if (self.stats.frames_encoded % 30 == 0) {
            std.debug.print("  pts_ms={}\n", .{pts_ms});
        }

        // Copy GL texture to linear CUDA device memory
        try self.cuda_ctx.copyGlTexture();

        // Encode — check PLI-triggered keyframe for WebRTC, plus periodic interval
        const pli_key = switch (self.sink) {
            .session => |s| s.shouldForceKeyframe(),
            .ivf => false,
        };
        const force_key = pli_key or (self.stats.frames_encoded % self.keyframe_interval == 0);
        const maybe_encoded = try self.nvenc.encodeFrame(force_key);

        if (maybe_encoded) |encoded| {
            defer self.nvenc.unlockBitstream();

            switch (self.sink) {
                .ivf => |*ivf| try ivf.writeFrame(encoded.data, pts_ms),
                .session => |s| s.sendFrame(encoded.data, pts_ms),
            }
            self.stats.total_bytes += encoded.data.len;
            if (encoded.is_key) self.stats.keyframes += 1;
        }

        self.stats.frames_encoded += 1;
    }

    /// Finalize output. Only meaningful for IVF sink.
    pub fn finish(self: *Encoder) !void {
        switch (self.sink) {
            .ivf => |*ivf| try ivf.finalize(
                @intCast(self.width),
                @intCast(self.height),
                1000,
                1,
            ),
            .session => {},
        }
    }

    pub fn deinit(self: *Encoder) void {
        self.nvenc.deinit();
        self.cuda_ctx.deinit();
        switch (self.sink) {
            .ivf => |*ivf| ivf.deinit(),
            .session => {}, // session lifetime managed by main
        }
    }
};
