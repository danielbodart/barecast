const std = @import("std");
const posix = std.posix;
const c = @cImport({
    @cInclude("stdlib.h");
});
const Compositor = @import("compositor").Compositor;
const CapturedFrame = @import("compositor").CapturedFrame;
const Encoder = @import("encoder").Encoder;
const FrameSink = @import("encoder").FrameSink;
const EncoderBackend = @import("encoder_backend").EncoderBackend;
const DmaBufAttrs = @import("encoder_backend").DmaBufAttrs;
const session_mod = @import("session");
const BroadcastSession = session_mod.BroadcastSession;
const PEER_ID_LEN = session_mod.PEER_ID_LEN;
const ViewerRegistry = @import("viewer_state").ViewerRegistry;
const generateRoomId = @import("control").generateRoomId;
const SessionRecorder = @import("session_recorder").SessionRecorder;

const log = std.log.scoped(.wayland_app_share);

pub const AppShareConfig = struct {
    command: []const u8,
    width: u32 = 1920,
    height: u32 = 1080,
    fps: u32 = 30,
    room_id: ?[]const u8 = null,
    base_url: []const u8 = "https://zerocast.bodar.com",
    record_dir: ?[]const u8 = null,
    render_device: [*:0]const u8 = "/dev/dri/renderD128",
};

/// Wayland app share session. Starts an embedded compositor (wlroots headless),
/// launches the app as a Wayland client, captures frames via DMA-BUF,
/// and encodes with VA-API (Intel/AMD) for WebRTC streaming.
pub const WaylandAppShare = struct {
    session_id: [16]u8,
    room_id_buf: [16]u8,
    room_id: []const u8,
    room_url_buf: [512]u8,
    share_url_buf: [512]u8,
    share_url: []const u8,
    compositor: *Compositor,
    app_pid: ?posix.pid_t,
    viewer_registry: ViewerRegistry,
    session: BroadcastSession,
    vaapi_backend: EncoderBackend,
    encoder: Encoder,
    recorder: ?SessionRecorder,
    pending_resize: std.atomic.Value(u32),
    pending_resize_slot: std.atomic.Value(u8),
    should_stop: std.atomic.Value(bool),
    start_time: std.time.Timer,
    last_fps: u32,
    last_bitrate: u64,
    config: AppShareConfig,
    command_buf: [512]u8,
    command_len: usize,

    // Frame state: written by compositor frame callback, read by encode loop.
    // NOT a race: compositor.dispatch() is called from the encode loop thread,
    // and the frame callback fires synchronously inside dispatch().
    latest_dmabuf: ?DmaBufAttrs,
    has_new_frame: bool,

    pub fn initInPlace(self: *WaylandAppShare, config: AppShareConfig) !void {
        self.pending_resize = std.atomic.Value(u32).init(0);
        self.pending_resize_slot = std.atomic.Value(u8).init(0xFF);
        self.should_stop = std.atomic.Value(bool).init(false);
        self.config = config;
        self.app_pid = null;
        self.latest_dmabuf = null;
        self.has_new_frame = false;

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

        // Start compositor
        self.compositor = Compositor.init(config.width, config.height) catch |err| {
            log.err("compositor init failed: {}", .{err});
            return error.CompositorFailed;
        };
        errdefer self.compositor.deinit();

        // Register frame callback
        self.compositor.frame_callback = &frameCallback;
        self.compositor.frame_userdata = @ptrCast(self);
        const t_compositor = ts.elapsed(&t);

        const socket = self.compositor.socketName();

        // Launch app with WAYLAND_DISPLAY set
        self.app_pid = self.launchApp(socket) catch |err| {
            log.err("app launch failed: {}", .{err});
            return error.AppLaunchFailed;
        };
        errdefer if (self.app_pid) |pid| {
            posix.kill(pid, posix.SIG.TERM) catch {};
            _ = posix.waitpid(pid, 0);
        };
        const t_app_launch = ts.elapsed(&t);

        // Wait for the app to connect and render a frame
        self.waitForFirstFrame() catch |err| {
            log.err("no frame received from app: {}", .{err});
            return error.NoFrameReceived;
        };
        const t_first_frame = ts.elapsed(&t);

        // Room ID
        if (config.room_id) |id| {
            self.room_id = id;
        } else {
            self.room_id_buf = generateRoomId();
            self.room_id = &self.room_id_buf;
        }

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

        self.viewer_registry = ViewerRegistry.init();

        // VA-API encoder backend
        self.vaapi_backend = EncoderBackend.init(config.render_device, config.width, config.height, config.fps) catch |err| {
            log.err("VA-API encoder init failed: {}", .{err});
            return error.EncoderInitFailed;
        };
        errdefer self.vaapi_backend.vaapi.deinit();
        const t_encoder = ts.elapsed(&t);

        // Broadcast session
        self.session = BroadcastSession.init(signaling_url, self.room_id, &self.session_id, "app", .video) catch |err| {
            log.err("session init failed: {}", .{err});
            return error.SessionInitFailed;
        };
        self.session.viewer_registry = &self.viewer_registry;
        self.session.meta_callback = appMetaCallback;
        self.session.resize_callback = appResizeCallback;
        const t_session = ts.elapsed(&t);

        // Encoder
        self.encoder = Encoder.init(
            self.vaapi_backend.backend(),
            config.width,
            config.height,
            .{ .session = &self.session },
            config.fps,
        ) catch |err| {
            log.err("encoder init failed: {}", .{err});
            self.session.deinit();
            return error.EncoderInitFailed;
        };
        self.session.codec = self.encoder.backend.codec;

        // Recording (optional)
        self.recorder = if (config.record_dir) |dir|
            SessionRecorder.init(dir, self.command_buf[0..self.command_len], config.fps, config.width, config.height, self.encoder.backend.codec)
        else
            null;
        if (self.recorder != null) {
            self.encoder.recorder = &self.recorder.?;
        }

        log.info("startup: compositor={d}ms app_launch={d}ms first_frame={d}ms encoder={d}ms session={d}ms total={d}ms", .{
            t_compositor, t_app_launch, t_first_frame, t_encoder, t_session,
            t_compositor + t_app_launch + t_first_frame + t_encoder + t_session,
        });

        self.last_fps = 0;
        self.last_bitrate = 0;
        self.start_time = std.time.Timer.start() catch return error.TimerUnavailable;
    }

    pub fn start(self: *WaylandAppShare) void {
        self.session.start();
    }

    pub fn runLoop(self: *WaylandAppShare) void {
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
            // Check if app is still running
            if (self.app_pid) |pid| {
                const wr = posix.waitpid(pid, posix.W.NOHANG);
                if (wr.pid != 0) {
                    log.info("app exited", .{});
                    self.app_pid = null;
                    break;
                }
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

            // Check for pending resize
            const resize_val = self.pending_resize.swap(0, .acquire);
            if (resize_val != 0) {
                const new_w: u32 = resize_val >> 16;
                const new_h: u32 = resize_val & 0xFFFF;
                self.handleResize(new_w, new_h);
                self.session.sendHostResizeToOthersSlot(self.pending_resize_slot.load(.acquire), @intCast(new_w), @intCast(new_h));
                frame_timer.reset();
                continue;
            }

            // Frame pacing
            const elapsed_frame_ns = frame_timer.read();
            if (elapsed_frame_ns < frame_interval_ns) {
                std.Thread.sleep(frame_interval_ns - elapsed_frame_ns);
            }
            frame_timer.reset();

            // Dispatch Wayland events (triggers handleFrame callback → updates latest_dmabuf)
            self.compositor.dispatch();

            // Encode the latest frame
            const is_new = self.has_new_frame;
            if (is_new) {
                if (self.latest_dmabuf) |dmabuf| {
                    self.vaapi_backend.pending_dmabuf = dmabuf;
                }
                self.has_new_frame = false;
            }

            self.encoder.processFrame(is_new) catch |err| {
                log.err("encode error: {}", .{err});
                break;
            };
        }

        log.info("wayland app share stopped", .{});
    }

    pub fn viewerCount(self: *WaylandAppShare) u32 {
        var count: u32 = 0;
        for (&self.session.peers) |*peer| {
            if (peer.state.load(.acquire) == .connected) {
                count += 1;
            }
        }
        return count;
    }

    pub fn uptimeSeconds(self: *WaylandAppShare) u64 {
        return self.start_time.read() / std.time.ns_per_s;
    }

    pub fn deinit(self: *WaylandAppShare) void {
        if (self.recorder) |*rec| {
            rec.logEvent("session ended");
            rec.deinit();
            self.recorder = null;
        }
        self.encoder.recorder = null;
        self.encoder.finish() catch {};
        self.encoder.deinit();
        self.session.deinit();

        if (self.app_pid) |pid| {
            posix.kill(pid, posix.SIG.TERM) catch {};
            _ = posix.waitpid(pid, 0);
        }

        self.compositor.deinit();
    }

    // ── Private ─────────────────────────────────────────────────────

    fn waitForFirstFrame(self: *WaylandAppShare) !void {
        // Dispatch until we get a frame or timeout (10s)
        const timeout_ns: u64 = 10 * std.time.ns_per_s;
        var timer = try std.time.Timer.start();
        while (timer.read() < timeout_ns) {
            self.compositor.dispatch();
            if (self.has_new_frame) {
                log.info("first frame received", .{});
                return;
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        return error.Timeout;
    }

    fn handleResize(self: *WaylandAppShare, new_w: u32, new_h: u32) void {
        log.info("resize {d}x{d} — rebuilding pipeline", .{ new_w, new_h });

        // encoder.deinit() calls backend.deinit() which calls vaapi.deinit()
        self.encoder.deinit();
        self.compositor.resize(new_w, new_h);

        self.vaapi_backend = EncoderBackend.init(self.config.render_device, new_w, new_h, self.config.fps) catch |e| {
            log.err("encoder reinit failed, stopping: {}", .{e});
            self.should_stop.store(true, .release);
            return;
        };
        self.encoder = Encoder.init(
            self.vaapi_backend.backend(),
            new_w,
            new_h,
            .{ .session = &self.session },
            self.config.fps,
        ) catch |e| {
            log.err("encoder reinit failed, stopping: {}", .{e});
            self.vaapi_backend.vaapi.deinit();
            self.should_stop.store(true, .release);
            return;
        };
        self.session.codec = self.encoder.backend.codec;
        if (self.recorder) |*rec| {
            self.encoder.recorder = rec;
            rec.updateResolution(new_w, new_h);
        }
        self.sendAppMeta();
    }

    fn launchApp(self: *WaylandAppShare, socket: [*:0]const u8) !posix.pid_t {
        const cmd = self.command_buf[0..self.command_len];

        const pid = posix.fork() catch return error.AppLaunchFailed;
        if (pid == 0) {
            // Child: set WAYLAND_DISPLAY and GDK_BACKEND for the app
            _ = c.setenv("WAYLAND_DISPLAY", socket, 1);
            _ = c.setenv("GDK_BACKEND", "wayland", 1);
            _ = c.setenv("QT_QPA_PLATFORM", "wayland", 1);

            // Redirect stdout/stderr to /dev/null
            const devnull = posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch posix.exit(127);
            posix.dup2(devnull, 1) catch {};
            posix.dup2(devnull, 2) catch {};

            var cmd_z: [513]u8 = undefined;
            @memcpy(cmd_z[0..cmd.len], cmd);
            cmd_z[cmd.len] = 0;

            const argv = [_:null]?[*:0]const u8{
                "/bin/sh",
                "-c",
                @ptrCast(cmd_z[0..cmd.len :0]),
            };
            posix.execveZ("/bin/sh", &argv, @ptrCast(std.c.environ)) catch {};
            posix.exit(127);
        }

        log.info("launched app: {s} (pid {d}) on {s}", .{ cmd, pid, std.mem.span(socket) });
        return pid;
    }

    fn sendAppMeta(self: *WaylandAppShare) void {
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

// ── Callbacks (C-compatible, outside struct) ────────────────────────────

fn frameCallback(frame: *const CapturedFrame, userdata: ?*anyopaque) void {
    const self: *WaylandAppShare = @ptrCast(@alignCast(userdata));
    const dmabuf = &frame.dmabuf;

    {
        const fmt: [4]u8 = @bitCast(dmabuf.format);
        log.debug("DMA-BUF: {d}x{d} format={s}(0x{x}) modifier=0x{x} planes={d} fd={d} stride={d} offset={d}", .{
            frame.width,           frame.height,
            &fmt,                  dmabuf.format,
            dmabuf.modifier,       dmabuf.n_planes,
            dmabuf.fd[0],          dmabuf.stride[0],
            dmabuf.offset[0],
        });
    }

    self.latest_dmabuf = .{
        .format = dmabuf.format,
        .modifier = dmabuf.modifier,
        .width = frame.width,
        .height = frame.height,
        .n_planes = @intCast(dmabuf.n_planes),
        .fd = dmabuf.fd,
        .stride = dmabuf.stride,
        .offset = dmabuf.offset,
    };
    self.has_new_frame = true;
}

fn appMetaCallback(session: *BroadcastSession) void {
    const self: *WaylandAppShare = @alignCast(@fieldParentPtr("session", session));
    self.sendAppMeta();
}

fn appResizeCallback(session: *BroadcastSession, sender_peer_id: *const [PEER_ID_LEN]u8, width: u16, height: u16) void {
    const self: *WaylandAppShare = @alignCast(@fieldParentPtr("session", session));
    if (width < 100 or height < 100) return;
    if (@as(u32, width) == self.compositor.width and @as(u32, height) == self.compositor.height) return;
    log.info("viewer resize requested: {d}x{d}", .{ width, height });
    self.pending_resize_slot.store(session.peerSlotIndex(sender_peer_id), .release);
    self.pending_resize.store((@as(u32, width) << 16) | @as(u32, height), .release);
}
