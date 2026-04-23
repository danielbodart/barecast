// macOS app share — captures a window via ScreenCaptureKit, converts
// BGRA to I420 on the CPU, and encodes AV1 via the shared SVT-AV1
// backend (T-021 migration; the legacy VideoToolbox HEVC path is
// retired).

const std = @import("std");
const encoder_mod = @import("encoder");
const SystemClock = @import("clock").SystemClock;
const Encoder = encoder_mod.Encoder;
const FrameSink = encoder_mod.FrameSink;
const SvtBackend = @import("svt_backend").SvtBackend;
const FrameDownloader = @import("frame_download").FrameDownloader;
const BroadcastSession = @import("session").BroadcastSession;
const ViewerRegistry = @import("viewer_state").ViewerRegistry;
const Input = @import("input").Input;
const generateRoomId = @import("control").generateRoomId;
const SessionRecorder = @import("session_recorder").SessionRecorder;

const c = @cImport({
    @cInclude("screen_capture.h");
    @cInclude("virtual_display.h");
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
    qp: u32 = 32,
};

pub const AppShare = struct {
    session_id: [16]u8,
    room_id_buf: [16]u8,
    room_id: []const u8,
    room_url_buf: [512]u8,
    share_url_buf: [512]u8,
    share_url: []const u8,
    app_pid: i64,
    window_id: u32,
    vd: *c.VirtualDisplay,
    capture: *c.SCCapture,
    cgevent: ?Input,
    viewer_registry: ViewerRegistry,
    session: BroadcastSession,
    svt_backend: SvtBackend,
    downloader: FrameDownloader,
    encoder: Encoder,
    recorder: ?SessionRecorder,
    pending_resize: std.atomic.Value(u32),
    should_stop: std.atomic.Value(bool),
    start_time: std.time.Timer,
    last_fps: u32,
    last_bitrate: u64,
    config: AppShareConfig,
    command_buf: [512]u8,
    command_len: usize,

    pub fn initInPlace(self: *AppShare, config: AppShareConfig) !void {
        self.pending_resize = std.atomic.Value(u32).init(0);
        self.should_stop = std.atomic.Value(bool).init(false);
        self.config = config;
        self.recorder = null;

        // Copy command string (config.command may point to stack)
        if (config.command.len > self.command_buf.len) return error.CommandTooLong;
        @memcpy(self.command_buf[0..config.command.len], config.command);
        self.command_len = config.command.len;

        var t = std.time.Timer.start() catch null;
        const ts = struct {
            fn elapsed(timer: *?std.time.Timer) u64 {
                if (timer.*) |*tt| {
                    const ms = tt.read() / std.time.ns_per_ms;
                    tt.reset();
                    return ms;
                }
                return 0;
            }
        };

        // Create virtual display for app isolation
        const cmd = self.command_buf[0..self.command_len];
        self.command_buf[self.command_len] = 0;
        const cmd_z: [*:0]const u8 = self.command_buf[0..self.command_len :0];

        self.vd = c.vd_create(config.width, config.height, @floatFromInt(config.fps)) orelse {
            log.err("failed to create virtual display", .{});
            return error.VirtualDisplayFailed;
        };
        errdefer c.vd_destroy(self.vd);

        const display_id = c.vd_get_display_id(self.vd);
        var window_id: u32 = 0;
        self.app_pid = c.vd_launch_app(display_id, cmd_z, &window_id);
        if (self.app_pid < 0) {
            log.err("failed to launch app on virtual display: {s}", .{cmd});
            return error.AppLaunchFailed;
        }
        self.window_id = window_id;
        const t_launch = ts.elapsed(&t);

        // Check Screen Recording permission before capture
        if (c.sc_check_screen_recording_permission() == 0) {
            log.err("Screen Recording permission not granted", .{});
            log.err("Grant access in System Settings → Privacy & Security → Screen Recording", .{});
            return error.ScreenRecordingDenied;
        }

        // Create window-level capture
        self.capture = c.sc_capture_create_window(self.window_id, config.fps) orelse {
            log.err("ScreenCaptureKit init failed", .{});
            return error.CaptureInitFailed;
        };
        errdefer c.sc_capture_destroy(self.capture);

        if (c.sc_capture_start(self.capture) != 0) {
            log.err("ScreenCaptureKit start failed", .{});
            return error.CaptureStartFailed;
        }
        const t_capture = ts.elapsed(&t);

        // Wait for the first frame (up to 2s)
        var frame: c.SCFrameResult = undefined;
        var attempts: u32 = 0;
        while (attempts < 200) : (attempts += 1) {
            if (c.sc_capture_get_frame(self.capture, &frame) == 0) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        if (attempts >= 200) {
            log.err("no frame received after 2s", .{});
            return error.NoFrameReceived;
        }

        const width = frame.width;
        const height = frame.height;
        if (frame.pixel_buffer) |pb| c.sc_capture_release_frame(pb);
        const t_frame = ts.elapsed(&t);

        log.info("capture started: {d}x{d} @{d}fps (window {d}, pid {d})", .{
            width, height, config.fps, self.window_id, self.app_pid,
        });

        // Room ID
        if (config.room_id) |id| {
            self.room_id = id;
        } else {
            self.room_id_buf = generateRoomId();
            self.room_id = &self.room_id_buf;
        }

        // Session ID
        self.session_id = generateRoomId();

        // Build URLs
        const base_url = config.base_url;
        const ws_scheme: []const u8 = if (std.mem.startsWith(u8, base_url, "https://")) "wss://" else "ws://";
        const host_start: usize = if (std.mem.startsWith(u8, base_url, "https://"))
            @as(usize, 8)
        else if (std.mem.startsWith(u8, base_url, "http://"))
            @as(usize, 7)
        else
            @as(usize, 0);

        const signaling_url = std.fmt.bufPrint(&self.room_url_buf, "{s}{s}", .{
            ws_scheme, base_url[host_start..],
        }) catch return error.UrlTooLong;

        self.share_url = std.fmt.bufPrint(&self.share_url_buf, "{s}/room/{s}", .{
            base_url, self.room_id,
        }) catch "???";

        log.info("room: {s}", .{self.share_url});

        // Viewer state
        self.viewer_registry = ViewerRegistry.init();

        // Broadcast session
        self.session = BroadcastSession.init(signaling_url, self.room_id, &self.session_id, "app", .video) catch |err| {
            log.err("session init failed: {}", .{err});
            return error.SessionInitFailed;
        };
        self.session.viewer_registry = &self.viewer_registry;
        self.session.meta_callback = appMetaCallback;
        self.session.resize_callback = appResizeCallback;

        // CGEvent input injection (requires Accessibility permission)
        self.cgevent = Input.init(self.app_pid) catch |err| blk: {
            log.warn("CGEvent input init failed (non-fatal): {}", .{err});
            break :blk null;
        };
        if (self.cgevent) |*cge| {
            self.session.input_handler = cge.inputHandler();
        }
        const t_session = ts.elapsed(&t);

        // SVT-AV1 software encoder + CPU-side frame downloader.
        // VideoToolbox HEVC was retired with T-021; AV1 everywhere now.
        self.svt_backend = SvtBackend.init(width, height, config.fps, config.qp) catch |err| {
            log.err("SVT-AV1 init failed: {}", .{err});
            self.session.deinit();
            return error.EncoderInitFailed;
        };
        self.downloader = FrameDownloader.init(std.heap.c_allocator, width, height) catch |err| {
            log.err("frame downloader init failed: {}", .{err});
            self.svt_backend.deinit();
            self.session.deinit();
            return error.EncoderInitFailed;
        };
        self.encoder = Encoder.init(
            self.svt_backend.backend(),
            width,
            height,
            .{ .session = &self.session },
            config.fps,
            SystemClock.clock(),
        ) catch |err| {
            log.err("encoder init failed: {}", .{err});
            self.downloader.deinit();
            self.svt_backend.deinit();
            self.session.deinit();
            return error.EncoderInitFailed;
        };
        // Propagate codec to session (must happen before session.start())
        self.session.codec = self.encoder.backend.codec;
        const t_encoder = ts.elapsed(&t);

        // Recording (optional — enabled by ZEROCAST_RECORD_DIR env)
        self.recorder = if (config.record_dir) |dir|
            SessionRecorder.init(dir, self.command_buf[0..self.command_len], config.fps, width, height, self.encoder.backend.codec)
        else
            null;
        if (self.recorder != null) {
            self.encoder.recorder = &self.recorder.?;
            self.recorder.?.logFmt("session started: {s} {d}x{d} @{d}fps", .{
                self.command_buf[0..self.command_len], width, height, config.fps,
            });
        }

        log.info("startup: launch={d}ms capture={d}ms frame={d}ms session={d}ms encoder={d}ms total={d}ms", .{
            t_launch, t_capture, t_frame, t_session, t_encoder,
            t_launch + t_capture + t_frame + t_session + t_encoder,
        });

        self.last_fps = 0;
        self.last_bitrate = 0;
        self.start_time = std.time.Timer.start() catch return error.TimerUnavailable;
    }

    pub fn start(self: *AppShare) void {
        self.session.start();
    }

    pub fn runLoop(self: *AppShare) void {
        const frame_interval_ns: u64 = std.time.ns_per_s / self.config.fps;
        var frame_timer = std.time.Timer.start() catch return;

        const ping_interval_ns: u64 = 30 * std.time.ns_per_s;
        var ping_timer = std.time.Timer.start() catch return;

        const meta_interval_ns: u64 = 5 * std.time.ns_per_s;
        var meta_timer = std.time.Timer.start() catch return;
        var prev_bytes: u64 = 0;
        var prev_frames: u64 = 0;

        self.sendAppMeta();

        while (!self.should_stop.load(.acquire)) {
            // Check if app is still running (macOS apps aren't child processes,
            // so we use kill(pid, 0) to check existence)
            if (std.c.kill(@intCast(self.app_pid), 0) != 0) {
                log.info("app exited (pid {d})", .{self.app_pid});
                break;
            }

            if (ping_timer.read() >= ping_interval_ns) {
                ping_timer.reset();
                if (!self.session.sendPing()) {
                    self.session.reconnect();
                }
            }

            if (meta_timer.read() >= meta_interval_ns) {
                const elapsed_ns = meta_timer.read();
                meta_timer.reset();

                const cur_bytes = self.session.bytes_sent.load(.monotonic);
                const cur_frames = self.session.frames_sent.load(.monotonic);

                const delta_bytes = cur_bytes - prev_bytes;
                const delta_frames = cur_frames - prev_frames;
                prev_bytes = cur_bytes;
                prev_frames = cur_frames;

                const elapsed_s = elapsed_ns / std.time.ns_per_s;
                if (elapsed_s > 0) {
                    self.last_fps = @intCast(delta_frames / elapsed_s);
                    self.last_bitrate = (delta_bytes * 8) / elapsed_s;
                }

                self.sendAppMeta();
            }

            // Check for pending resize (set by appResizeCallback on data channel thread)
            const resize_val = self.pending_resize.swap(0, .acquire);
            if (resize_val != 0) {
                const new_w: u32 = resize_val >> 16;
                const new_h: u32 = resize_val & 0xFFFF;
                self.handleResize(new_w, new_h);
                frame_timer.reset();
                continue;
            }

            // Frame pacing
            const elapsed_frame_ns = frame_timer.read();
            if (elapsed_frame_ns < frame_interval_ns) {
                std.Thread.sleep(frame_interval_ns - elapsed_frame_ns);
            }
            frame_timer.reset();

            // Capture frame
            var frame: c.SCFrameResult = undefined;
            if (c.sc_capture_get_frame(self.capture, &frame) != 0) {
                continue;
            }

            const pb = frame.pixel_buffer orelse continue;
            defer c.sc_capture_release_frame(pb);

            // CPU download + BGRA→I420 → SvtBackend, then encode.
            const yuv_slice = self.downloader.downloadFromPixelBuffer(pb) catch |err| {
                log.err("frame download failed: {}", .{err});
                continue;
            };
            self.svt_backend.setPendingYuv(yuv_slice);

            self.encoder.processFrame(frame.is_new != 0) catch |err| {
                log.err("encode error: {}", .{err});
                break;
            };
        }

        log.info("app share stopped", .{});
    }

    /// Rebuild the capture+encode pipeline at a new resolution.
    /// On any failure, signals should_stop so the runLoop exits cleanly
    /// rather than using deinitialized resources.
    fn handleResize(self: *AppShare, new_w: u32, new_h: u32) void {
        log.info("resize {d}x{d} — rebuilding pipeline", .{ new_w, new_h });

        var t = std.time.Timer.start() catch null;
        const ts = struct {
            fn elapsed(timer: *?std.time.Timer) u64 {
                if (timer.*) |*tt| {
                    const us = tt.read() / std.time.ns_per_us;
                    tt.reset();
                    return us;
                }
                return 0;
            }
        };

        // 1. Tear down encoder
        self.encoder.deinit();
        const t_encoder_deinit = ts.elapsed(&t);

        // 2. Tear down capture
        c.sc_capture_destroy(self.capture);
        const t_capture_deinit = ts.elapsed(&t);

        // 3. Resize the virtual display (in-place mode switch, no teardown)
        if (c.vd_resize(self.vd, new_w, new_h) != 0) {
            log.warn("virtual display resize failed, continuing with window resize only", .{});
        }

        // 4. Resize the app window to match
        _ = c.sc_resize_window(self.app_pid, new_w, new_h);
        const t_resize = ts.elapsed(&t);

        // 5. Brief delay for WindowServer to process resize
        std.Thread.sleep(100 * std.time.ns_per_ms);

        // 6. Rebuild capture on the (now-resized) window
        self.capture = c.sc_capture_create_window(self.window_id, self.config.fps) orelse {
            log.err("capture reinit failed after resize — stopping", .{});
            self.should_stop.store(true, .release);
            return;
        };
        if (c.sc_capture_start(self.capture) != 0) {
            log.err("capture restart failed after resize — stopping", .{});
            c.sc_capture_destroy(self.capture);
            self.should_stop.store(true, .release);
            return;
        }
        const t_capture_init = ts.elapsed(&t);

        // 7. Wait for first frame at new size
        var frame: c.SCFrameResult = undefined;
        var attempts: u32 = 0;
        while (attempts < 200) : (attempts += 1) {
            if (c.sc_capture_get_frame(self.capture, &frame) == 0) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        if (attempts >= 200) {
            log.err("no frame after resize — stopping", .{});
            self.should_stop.store(true, .release);
            return;
        }
        if (frame.pixel_buffer) |pb| c.sc_capture_release_frame(pb);
        const t_frame = ts.elapsed(&t);

        // 8. Rebuild encoder — SVT-AV1 + matching I420 downloader.
        self.svt_backend = SvtBackend.init(frame.width, frame.height, self.config.fps, self.config.qp) catch |err| {
            log.err("SVT-AV1 reinit failed: {} — stopping", .{err});
            self.should_stop.store(true, .release);
            return;
        };
        self.downloader.resize(frame.width, frame.height) catch |err| {
            log.err("downloader resize failed: {} — stopping", .{err});
            self.svt_backend.deinit();
            self.should_stop.store(true, .release);
            return;
        };
        self.encoder = Encoder.init(
            self.svt_backend.backend(),
            frame.width,
            frame.height,
            .{ .session = &self.session },
            self.config.fps,
            SystemClock.clock(),
        ) catch |err| {
            log.err("encoder reinit failed: {} — stopping", .{err});
            self.should_stop.store(true, .release);
            return;
        };
        self.session.codec = self.encoder.backend.codec;
        if (self.recorder) |*rec| {
            self.encoder.recorder = rec;
            rec.updateResolution(frame.width, frame.height);
            rec.logFmt("resize: {d}x{d}", .{ new_w, new_h });
        }
        const t_encoder_init = ts.elapsed(&t);

        log.info("resize done: encoder_deinit={d}us capture_deinit={d}us resize={d}us capture_init={d}us frame={d}us encoder_init={d}us total={d}us", .{
            t_encoder_deinit, t_capture_deinit, t_resize, t_capture_init, t_frame, t_encoder_init,
            t_encoder_deinit + t_capture_deinit + t_resize + t_capture_init + t_frame + t_encoder_init,
        });

        // Refresh cached window position for input coordinate mapping
        if (self.cgevent) |*cge| cge.refreshWindowPosition();

        self.sendAppMeta();
    }

    pub fn viewerCount(self: *AppShare) u32 {
        var count: u32 = 0;
        for (&self.session.peers) |*peer| {
            if (peer.state.load(.acquire) == .connected) {
                count += 1;
            }
        }
        return count;
    }

    pub fn uptimeSeconds(self: *AppShare) u64 {
        return self.start_time.read() / std.time.ns_per_s;
    }

    pub fn deinit(self: *AppShare) void {
        if (self.recorder) |*rec| {
            rec.logEvent("session ended");
            rec.deinit();
            self.recorder = null;
        }
        self.encoder.recorder = null;
        self.encoder.finish() catch {};
        self.encoder.deinit();
        self.downloader.deinit();
        self.session.deinit();
        c.sc_capture_destroy(self.capture);

        // Terminate the app and destroy the virtual display
        _ = std.c.kill(@intCast(self.app_pid), std.c.SIG.TERM);
        c.vd_destroy(self.vd);
    }

    fn sendAppMeta(self: *AppShare) void {
        const cmd = self.command_buf[0..self.command_len];
        var buf: [512]u8 = undefined;
        const meta = std.fmt.bufPrint(&buf, "{{\"type\":\"set-meta\",\"title\":\"{s}\",\"res\":\"{d}x{d}\",\"fps\":{d},\"bitrate\":{d}}}", .{
            cmd,
            self.encoder.width,
            self.encoder.height,
            self.last_fps,
            self.last_bitrate,
        }) catch return;
        self.session.sendMeta(meta);
    }
};

fn appMetaCallback(session: *BroadcastSession) void {
    const self: *AppShare = @alignCast(@fieldParentPtr("session", session));
    self.sendAppMeta();
}

fn appResizeCallback(session: *BroadcastSession, _: *const [16]u8, width: u16, height: u16) void {
    const self: *AppShare = @alignCast(@fieldParentPtr("session", session));
    if (width < 100 or height < 100) return;
    if (@as(u32, width) == self.encoder.width and @as(u32, height) == self.encoder.height) return;
    log.info("viewer resize requested: {d}x{d}", .{ width, height });
    self.pending_resize.store((@as(u32, width) << 16) | @as(u32, height), .release);
}
