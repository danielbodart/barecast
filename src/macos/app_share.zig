// macOS app share — Phase 1 PoC.
// Captures the main display via ScreenCaptureKit, encodes HEVC via VideoToolbox,
// writes raw Annex B to a file (or streams via WebRTC session in later phases).

const std = @import("std");
const encoder_mod = @import("encoder");
const Encoder = encoder_mod.Encoder;
const FrameSink = encoder_mod.FrameSink;
const VideoToolboxBackend = @import("encoder_videotoolbox").VideoToolboxBackend;

const c = @cImport({
    @cInclude("macos/screen_capture.h");
});

const log = std.log.scoped(.app_share);

pub const AppShareConfig = struct {
    command: []const u8,
    width: u32 = 1920,
    height: u32 = 1080,
    fps: u32 = 30,
    room_id: ?[]const u8 = null,
    base_url: []const u8 = "https://zerocast.bodar.com",
    record_dir: ?[]const u8 = null,
};

pub const AppShare = struct {
    // Fields required by daemon.zig contract
    session_id: [16]u8,
    share_url_buf: [512]u8,
    share_url: []const u8,
    should_stop: std.atomic.Value(bool),

    // macOS-specific
    capture: *c.SCCapture,
    vt_backend: VideoToolboxBackend,
    encoder: Encoder,
    output_file: ?std.fs.File,
    config: AppShareConfig,
    start_time: std.time.Timer,
    frames_written: u64,

    pub fn initInPlace(self: *AppShare, config: AppShareConfig) !void {
        self.should_stop = std.atomic.Value(bool).init(false);
        self.config = config;
        self.output_file = null;
        self.frames_written = 0;

        // Session ID (random)
        std.crypto.random.bytes(&self.session_id);

        // Share URL
        self.share_url = std.fmt.bufPrint(&self.share_url_buf, "{s}/room/{s}", .{
            config.base_url,
            if (config.room_id) |id| id else &self.session_id,
        }) catch "???";

        // Create capture session
        self.capture = c.sc_capture_create_display(0, config.fps) orelse {
            log.err("ScreenCaptureKit init failed — check Screen Recording permission", .{});
            return error.CaptureInitFailed;
        };

        // Start capture to get initial frame dimensions
        if (c.sc_capture_start(self.capture) != 0) {
            log.err("ScreenCaptureKit start failed", .{});
            c.sc_capture_destroy(self.capture);
            return error.CaptureStartFailed;
        }

        // Wait for the first frame (up to 2s)
        var frame: c.SCFrameResult = undefined;
        var attempts: u32 = 0;
        while (attempts < 200) : (attempts += 1) {
            if (c.sc_capture_get_frame(self.capture, &frame) == 0) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        if (attempts >= 200) {
            log.err("no frame received after 2s", .{});
            c.sc_capture_destroy(self.capture);
            return error.NoFrameReceived;
        }

        const width = frame.width;
        const height = frame.height;
        log.info("capture started: {d}x{d} @{d}fps", .{ width, height, config.fps });

        // Create VideoToolbox encoder
        self.vt_backend = VideoToolboxBackend.init(width, height, config.fps) catch |err| {
            log.err("VideoToolbox init failed: {}", .{err});
            c.sc_capture_destroy(self.capture);
            return error.EncoderInitFailed;
        };

        // Open output file (raw Annex B HEVC — .hevc extension)
        if (config.record_dir) |dir| {
            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/capture.hevc", .{dir}) catch return error.PathTooLong;
            self.output_file = std.fs.cwd().createFile(path[0..path.len], .{}) catch |err| {
                log.err("failed to create output file: {}", .{err});
                return error.OutputFileFailed;
            };
        }

        // Initialize encoder orchestrator (PoC writes directly, not through FrameSink)
        self.encoder = Encoder.init(
            self.vt_backend.backend(),
            width,
            height,
            .none,
            config.fps,
        ) catch |err| {
            log.err("encoder init failed: {}", .{err});
            c.sc_capture_destroy(self.capture);
            return error.EncoderInitFailed;
        };

        self.start_time = std.time.Timer.start() catch return error.TimerUnavailable;
    }

    pub fn start(self: *AppShare) void {
        _ = self;
        // No WebRTC session to start in PoC
    }

    pub fn runLoop(self: *AppShare) void {
        const frame_interval_ns: u64 = std.time.ns_per_s / self.config.fps;
        var frame_timer = std.time.Timer.start() catch return;

        while (!self.should_stop.load(.acquire)) {
            var frame: c.SCFrameResult = undefined;
            if (c.sc_capture_get_frame(self.capture, &frame) != 0) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            }

            // Set the pixel buffer on the backend for encoding
            const pb = frame.pixel_buffer orelse continue;
            self.vt_backend.setPixelBuffer(pb);

            // Encode and write directly to file
            const force_key = self.frames_written == 0;
            const maybe_encoded = self.vt_backend.backend().encode(force_key) catch |err| {
                log.err("encode error: {}", .{err});
                c.sc_capture_release_frame(pb);
                break;
            };

            if (maybe_encoded) |encoded| {
                if (self.output_file) |file| {
                    file.writeAll(encoded.data) catch |err| {
                        log.err("write error: {}", .{err});
                        break;
                    };
                }
                self.frames_written += 1;

                if (self.frames_written % self.config.fps == 0) {
                    const elapsed_s = self.start_time.read() / std.time.ns_per_s;
                    log.info("encoded {d} frames ({d}s elapsed)", .{
                        self.frames_written, elapsed_s,
                    });
                }
            }

            // Release the retained pixel buffer now that encoding is done
            c.sc_capture_release_frame(pb);

            // Frame pacing
            const elapsed_frame_ns = frame_timer.read();
            if (elapsed_frame_ns < frame_interval_ns) {
                std.Thread.sleep(frame_interval_ns - elapsed_frame_ns);
            }
            frame_timer.reset();
        }

        log.info("capture stopped: {d} frames written", .{self.frames_written});
    }

    pub fn viewerCount(self: *AppShare) u32 {
        _ = self;
        return 0;
    }

    pub fn uptimeSeconds(self: *AppShare) u64 {
        return self.start_time.read() / std.time.ns_per_s;
    }

    pub fn deinit(self: *AppShare) void {
        if (self.output_file) |file| file.close();
        self.vt_backend.backend().deinit();
        c.sc_capture_destroy(self.capture);
    }
};
