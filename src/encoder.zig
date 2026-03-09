const std = @import("std");
const nvfbc = @import("nvfbc");
const Cuda = @import("cuda").Cuda;
const NvencEncoder = @import("nvenc").Nvenc;
const IvfWriter = @import("ivf").IvfWriter;
const BroadcastSession = @import("session").BroadcastSession;
const SessionRecorder = @import("session_recorder").SessionRecorder;

const log = std.log.scoped(.encoder);

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

/// Rolling averages for pipeline stage durations (microseconds).
const PipelineTimings = struct {
    cuda_copy_us: u64 = 0,
    encode_us: u64 = 0,
    send_us: u64 = 0,
    total_us: u64 = 0,
    max_cuda_copy_us: u64 = 0,
    max_encode_us: u64 = 0,
    max_send_us: u64 = 0,
    max_total_us: u64 = 0,
    samples: u64 = 0,

    fn accumulate(self: *PipelineTimings, cuda_copy: u64, encode: u64, send: u64) void {
        self.cuda_copy_us += cuda_copy;
        self.encode_us += encode;
        self.send_us += send;
        const total = cuda_copy + encode + send;
        self.total_us += total;
        self.max_cuda_copy_us = @max(self.max_cuda_copy_us, cuda_copy);
        self.max_encode_us = @max(self.max_encode_us, encode);
        self.max_send_us = @max(self.max_send_us, send);
        self.max_total_us = @max(self.max_total_us, total);
        self.samples += 1;
    }

    fn reset(self: *PipelineTimings) void {
        self.* = .{};
    }
};

pub const Encoder = struct {
    cuda_ctx: Cuda,
    nvenc: NvencEncoder,
    sink: FrameSink,
    stats: Stats,
    timer: std.time.Timer,
    timings: PipelineTimings,
    width: u32,
    height: u32,
    fps: u32,
    recorder: ?*SessionRecorder = null,
    consecutive_skips: u64 = 0,
    idle_logged: bool = false,
    idle_keyframe_sent: bool = false,
    force_next_keyframe: bool = false,

    pub fn init(
        fbc: *nvfbc.NvFbc,
        first_frame: nvfbc.FrameResult,
        sink: FrameSink,
        fps: u32,
    ) !Encoder {
        var cu = try Cuda.init(first_frame.texture_id, first_frame.width, first_frame.height);
        errdefer cu.deinit();

        var enc = try NvencEncoder.init(&cu, fps);
        errdefer enc.deinit();

        _ = fbc; // NvFBC reference retained for future use (e.g. texture slot management)

        return .{
            .cuda_ctx = cu,
            .nvenc = enc,
            .sink = sink,
            .stats = .{},
            .timer = try std.time.Timer.start(),
            .timings = .{},
            .width = first_frame.width,
            .height = first_frame.height,
            .fps = fps,
        };
    }

    /// Process one captured frame: CUDA copy → NVENC encode → sink dispatch.
    pub fn processFrame(self: *Encoder, frame: nvfbc.FrameResult) !void {
        // Even when idle, the first PLI (viewer join) must be serviced — encode
        // the last captured texture as a keyframe so new viewers can start decoding.
        // Subsequent PLIs while still idle are ignored to avoid periodic keyframe bursts.
        const pli_raw = switch (self.sink) {
            .session => |s| s.shouldForceKeyframe(),
            .ivf => false,
        };
        const pli_pending = pli_raw and !self.idle_keyframe_sent;

        if (!frame.is_new and !pli_pending) {
            self.stats.frames_skipped += 1;
            self.consecutive_skips += 1;
            // Log idle state once after ~1s of no changes
            if (!self.idle_logged and self.consecutive_skips >= self.fps) {
                log.info("idle — screen unchanged for {d} frames, suspending encode", .{self.consecutive_skips});
                self.idle_logged = true;
            }
            return;
        }

        if (pli_pending and !frame.is_new) {
            // Idle PLI — send one keyframe but stay in idle state
            log.info("idle PLI — sending keyframe after {d} skipped frames", .{self.consecutive_skips});
            self.idle_keyframe_sent = true;
        } else if (frame.is_new) {
            // Real content change — reset idle tracking
            if (self.idle_logged) {
                log.info("resuming encode after {d} skipped frames", .{self.consecutive_skips});
            }
            self.consecutive_skips = 0;
            self.idle_logged = false;
            self.idle_keyframe_sent = false;
        }

        // Real wall clock PTS in milliseconds
        const pts_ms = self.timer.read() / std.time.ns_per_ms;

        // NTP capture timestamp for abs-capture-time RTP extension.
        // CLOCK_REALTIME → NTP epoch (Jan 1, 1900) in UQ32.32 fixed-point.
        const capture_ntp = blk: {
            const ntp_epoch_offset: u64 = 2_208_988_800; // seconds between 1900 and 1970
            const realtime_ns: u128 = @bitCast(std.time.nanoTimestamp());
            const secs: u64 = @intCast(realtime_ns / std.time.ns_per_s);
            const frac_ns: u64 = @intCast(realtime_ns % std.time.ns_per_s);
            const ntp_secs: u64 = secs + ntp_epoch_offset;
            const ntp_frac: u64 = (frac_ns << 32) / std.time.ns_per_s;
            break :blk (ntp_secs << 32) | ntp_frac;
        };

        // ── Stage timing ──────────────────────────────────────────
        const t0 = std.time.Instant.now() catch null;

        // Copy GL texture to linear CUDA device memory
        try self.cuda_ctx.copyGlTexture();

        const t1 = std.time.Instant.now() catch null;

        // Encode — force keyframe on PLI, first frame, or after pipeline reinit
        const force_key = pli_pending or self.force_next_keyframe;
        if (self.force_next_keyframe) self.force_next_keyframe = false;
        const maybe_encoded = try self.nvenc.encodeFrame(force_key);

        const t2 = std.time.Instant.now() catch null;

        if (maybe_encoded) |encoded| {
            defer self.nvenc.unlockBitstream();

            switch (self.sink) {
                .ivf => |*ivf| try ivf.writeFrame(encoded.data, pts_ms),
                .session => |s| s.sendFrame(encoded.data, pts_ms, capture_ntp),
            }
            if (self.recorder) |rec| {
                rec.writeFrame(encoded.data, pts_ms, &self.timer);
            }
            self.stats.total_bytes += encoded.data.len;
            if (encoded.is_key) self.stats.keyframes += 1;
        }

        const t3 = std.time.Instant.now() catch null;

        // ── Accumulate timing ─────────────────────────────────────
        if (t0 != null and t1 != null and t2 != null and t3 != null) {
            const cuda_us = t1.?.since(t0.?) / std.time.ns_per_us;
            const encode_us = t2.?.since(t1.?) / std.time.ns_per_us;
            const send_us = t3.?.since(t2.?) / std.time.ns_per_us;

            log.debug("frame {d}: cuda={d}us encode={d}us send={d}us pts={d}ms", .{
                self.stats.frames_encoded, cuda_us, encode_us, send_us, pts_ms,
            });

            self.timings.accumulate(cuda_us, encode_us, send_us);
        }

        self.stats.frames_encoded += 1;

        // Periodic summary (every ~5s at 30fps)
        const summary_interval = @as(u64, self.fps) * 5;
        if (summary_interval > 0 and self.timings.samples >= summary_interval) {
            const n = self.timings.samples;
            log.info(
                "pipeline avg: cuda={d}us encode={d}us send={d}us total={d}us | max: cuda={d}us encode={d}us send={d}us total={d}us ({d} frames, {d} skipped, {d} keyframes)",
                .{
                    self.timings.cuda_copy_us / n,
                    self.timings.encode_us / n,
                    self.timings.send_us / n,
                    self.timings.total_us / n,
                    self.timings.max_cuda_copy_us,
                    self.timings.max_encode_us,
                    self.timings.max_send_us,
                    self.timings.max_total_us,
                    n,
                    self.stats.frames_skipped,
                    self.stats.keyframes,
                },
            );
            if (self.recorder) |rec| {
                rec.logTimings(
                    self.timings.cuda_copy_us / n,
                    self.timings.encode_us / n,
                    self.timings.send_us / n,
                    self.timings.total_us / n,
                    n,
                    self.stats.frames_skipped,
                );
            }
            self.timings.reset();
        }
    }

    /// Finalize output. Only meaningful for IVF sink.
    pub fn finish(self: *Encoder) !void {
        switch (self.sink) {
            .ivf => |*ivf| try ivf.finalize(
                @intCast(self.width),
                @intCast(self.height),
                self.fps,
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
