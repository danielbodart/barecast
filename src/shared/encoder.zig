const std = @import("std");
const IvfWriter = @import("ivf").IvfWriter;
const BroadcastSession = @import("session").BroadcastSession;
const SessionRecorder = @import("session_recorder").SessionRecorder;
pub const Codec = @import("codec").Codec;

const log = std.log.scoped(.encoder);

// ── Encoder backend contract ─────────────────────────────────────────────

/// A single encoded frame returned by the backend.
pub const EncodedFrame = struct {
    data: []const u8,
    is_key: bool,
    pts: u64,
};

/// Platform-agnostic encoder backend. Each platform (NVENC, VideoToolbox)
/// provides a struct that can be erased into this vtable.
pub const EncodeBackend = struct {
    ptr: *anyopaque,
    /// The video codec this backend produces.
    codec: Codec,
    /// Prepare the next frame for encoding (e.g. GPU texture copy).
    /// Called once per frame before encodeFn.
    prepareFn: *const fn (*anyopaque) anyerror!void,
    /// Encode one frame. Returns encoded bitstream or null if the encoder
    /// needs more input. Caller must call unlockFn after consuming data.
    encodeFn: *const fn (*anyopaque, force_key: bool) anyerror!?EncodedFrame,
    /// Release the encoded bitstream buffer. Must be called after each
    /// successful encodeFn that returned non-null.
    unlockFn: *const fn (*anyopaque) void,
    deinitFn: *const fn (*anyopaque) void,

    pub fn prepare(self: EncodeBackend) !void {
        return self.prepareFn(self.ptr);
    }

    pub fn encode(self: EncodeBackend, force_key: bool) !?EncodedFrame {
        return self.encodeFn(self.ptr, force_key);
    }

    pub fn unlock(self: EncodeBackend) void {
        self.unlockFn(self.ptr);
    }

    pub fn deinit(self: EncodeBackend) void {
        self.deinitFn(self.ptr);
    }
};

// ── Frame sink ───────────────────────────────────────────────────────────

pub const FrameSink = union(enum) {
    ivf: IvfWriter,
    session: *BroadcastSession,
    none, // No sink — caller writes encoded data directly (e.g. macOS PoC)
};

// ── Encoder (shared orchestration) ───────────────────────────────────────

pub const Stats = struct {
    frames_encoded: u64 = 0,
    frames_skipped: u64 = 0,
    keyframes: u64 = 0,
    total_bytes: u64 = 0,
};

/// Rolling averages for pipeline stage durations (microseconds).
const PipelineTimings = struct {
    prepare_us: u64 = 0,
    encode_us: u64 = 0,
    send_us: u64 = 0,
    total_us: u64 = 0,
    max_prepare_us: u64 = 0,
    max_encode_us: u64 = 0,
    max_send_us: u64 = 0,
    max_total_us: u64 = 0,
    samples: u64 = 0,

    fn accumulate(self: *PipelineTimings, prepare: u64, encode: u64, send: u64) void {
        self.prepare_us += prepare;
        self.encode_us += encode;
        self.send_us += send;
        const total = prepare + encode + send;
        self.total_us += total;
        self.max_prepare_us = @max(self.max_prepare_us, prepare);
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
    backend: EncodeBackend,
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

    pub fn init(backend: EncodeBackend, width: u32, height: u32, sink: FrameSink, fps: u32) !Encoder {
        return .{
            .backend = backend,
            .sink = sink,
            .stats = .{},
            .timer = try std.time.Timer.start(),
            .timings = .{},
            .width = width,
            .height = height,
            .fps = fps,
        };
    }

    /// Process one captured frame: prepare → encode → sink dispatch.
    /// `is_new` indicates whether the frame content changed since last call.
    pub fn processFrame(self: *Encoder, is_new: bool) !void {
        // Honour every PLI — the browser only sends them when it genuinely needs
        // a keyframe (new viewer, packet loss, etc.) and stops once it decodes one.
        const pli_pending = switch (self.sink) {
            .session => |s| s.shouldForceKeyframe(),
            .ivf, .none => false,
        };

        if (!is_new and !pli_pending) {
            self.stats.frames_skipped += 1;
            self.consecutive_skips += 1;
            // Log idle state once after ~1s of no changes
            if (!self.idle_logged and self.consecutive_skips >= self.fps) {
                log.info("idle — screen unchanged for {d} frames, suspending encode", .{self.consecutive_skips});
                self.idle_logged = true;
            }
            return;
        }

        if (pli_pending and !is_new) {
            if (self.idle_keyframe_sent) {
                // Already sent a keyframe for this idle period — suppress.
                // The browser already has the current frame; another identical
                // keyframe is wasteful. A real content change will reset this.
                return;
            }
            // First idle PLI — send one keyframe, then suppress further ones
            log.info("idle PLI — sending keyframe after {d} skipped frames", .{self.consecutive_skips});
            self.idle_keyframe_sent = true;
        } else if (is_new) {
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

        // Prepare frame for encoding (e.g. GPU texture copy)
        try self.backend.prepare();

        const t1 = std.time.Instant.now() catch null;

        // Encode — force keyframe on PLI, first frame, or after pipeline reinit
        const force_key = pli_pending or self.force_next_keyframe;
        if (self.force_next_keyframe) self.force_next_keyframe = false;
        const maybe_encoded = try self.backend.encode(force_key);

        const t2 = std.time.Instant.now() catch null;

        if (maybe_encoded) |encoded| {
            defer self.backend.unlock();

            switch (self.sink) {
                .ivf => |*ivf| try ivf.writeFrame(encoded.data, pts_ms),
                .session => |s| s.sendFrame(encoded.data, pts_ms, capture_ntp),
                .none => {},
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
            const prepare_us = t1.?.since(t0.?) / std.time.ns_per_us;
            const encode_us = t2.?.since(t1.?) / std.time.ns_per_us;
            const send_us = t3.?.since(t2.?) / std.time.ns_per_us;

            log.debug("frame {d}: prepare={d}us encode={d}us send={d}us pts={d}ms", .{
                self.stats.frames_encoded, prepare_us, encode_us, send_us, pts_ms,
            });

            self.timings.accumulate(prepare_us, encode_us, send_us);
        }

        self.stats.frames_encoded += 1;

        // Periodic summary (every ~5s at 30fps)
        const summary_interval = @as(u64, self.fps) * 5;
        if (summary_interval > 0 and self.timings.samples >= summary_interval) {
            const n = self.timings.samples;
            log.info(
                "pipeline avg: prepare={d}us encode={d}us send={d}us total={d}us | max: prepare={d}us encode={d}us send={d}us total={d}us ({d} frames, {d} skipped, {d} keyframes)",
                .{
                    self.timings.prepare_us / n,
                    self.timings.encode_us / n,
                    self.timings.send_us / n,
                    self.timings.total_us / n,
                    self.timings.max_prepare_us,
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
                    self.timings.prepare_us / n,
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
            .session, .none => {},
        }
    }

    pub fn deinit(self: *Encoder) void {
        self.backend.deinit();
        switch (self.sink) {
            .ivf => |*ivf| ivf.deinit(),
            .session, .none => {}, // session lifetime managed by main
        }
    }
};
