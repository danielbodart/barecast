const std = @import("std");
const posix = std.posix;
const c = @cImport({
    @cInclude("stdlib.h");
});
const nvfbc = @import("nvfbc");
const NvFbc = nvfbc.NvFbc;
const Box = nvfbc.Box;
const Encoder = @import("encoder").Encoder;
const FrameSink = @import("encoder").FrameSink;
const BroadcastSession = @import("session").BroadcastSession;
const InputHandler = @import("session").InputHandler;
const ViewerRegistry = @import("viewer_state").ViewerRegistry;
const XTestInput = @import("xtest_input").XTestInput;
const HeadlessDisplay = @import("headless_display").HeadlessDisplay;
const WindowManager = @import("window_manager").WindowManager;
const generateRoomId = @import("control").generateRoomId;
const SessionRecorder = @import("session_recorder").SessionRecorder;

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

/// Self-contained app share session. Spawns a headless Xorg display,
/// launches the app, captures via NvFBC, and streams over WebRTC.
///
/// Uses init-in-place pattern (same as ScreenShare / Peer).
pub const AppShare = struct {
    session_id: [16]u8,
    room_id_buf: [16]u8,
    room_id: []const u8,
    room_url_buf: [512]u8,
    share_url_buf: [512]u8,
    share_url: []const u8,
    display: HeadlessDisplay,
    wm: ?WindowManager,
    app_pid: ?posix.pid_t,
    fbc: NvFbc,
    xinput: ?XTestInput,
    viewer_registry: ViewerRegistry,
    session: BroadcastSession,
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
        self.app_pid = null;
        self.xinput = null;
        self.wm = null;

        // Copy command string (config.command may point to stack)
        if (config.command.len > self.command_buf.len) return error.CommandTooLong;
        @memcpy(self.command_buf[0..config.command.len], config.command);
        self.command_len = config.command.len;

        // Start headless display at a minimal size (will resize to app)
        self.display = HeadlessDisplay.start(config.width, config.height) catch |err| {
            log.err("headless display failed: {}", .{err});
            return error.DisplayFailed;
        };
        errdefer self.display.stop();

        const display_env = self.display.displayEnv();
        log.info("headless display :{d} ready", .{self.display.display_num});

        // Start window manager on the headless display
        var display_z: [16]u8 = undefined;
        @memcpy(display_z[0..display_env.len], display_env);
        display_z[display_env.len] = 0;

        self.wm = WindowManager.init(@ptrCast(display_z[0..display_env.len :0])) catch |err| blk: {
            log.warn("window manager init failed: {}", .{err});
            break :blk null;
        };

        // Launch the app on the headless display
        self.app_pid = self.launchApp(display_env) catch |err| {
            log.err("app launch failed: {}", .{err});
            return error.AppLaunchFailed;
        };
        errdefer if (self.app_pid) |pid| {
            posix.kill(pid, posix.SIG.TERM) catch {};
            _ = posix.waitpid(pid, 0);
        };

        // Wait for the app's window and resize display to match
        if (self.wm) |*wm| {
            if (wm.waitForWindow(10)) |size| {
                log.info("app window: {d}x{d}, resizing display", .{ size.w, size.h });
                self.display.resize(size.w, size.h);
            } else |_| {
                log.warn("app window not detected, using default size", .{});
            }
        }

        var fbc = NvFbc.initDisplay(.{}, config.fps, @ptrCast(display_z[0..display_env.len :0])) catch |err| {
            log.err("NvFBC init on headless display failed: {}", .{err});
            return error.NvFbcFailed;
        };
        errdefer fbc.deinit();

        const first_frame = fbc.grabFrame() catch |err| {
            log.err("first frame grab failed: {}", .{err});
            return error.NvFbcFailed;
        };
        log.info("NvFBC: {}x{}, texture={}", .{ first_frame.width, first_frame.height, first_frame.texture_id });

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

        // XTEST input on the headless display
        self.xinput = XTestInput.init(
            @ptrCast(display_z[0..display_env.len :0]),
            config.width,
            config.height,
        ) catch |err| blk: {
            log.warn("XTEST init failed (non-fatal): {}", .{err});
            break :blk null;
        };

        // Broadcast session
        self.session = BroadcastSession.init(signaling_url, self.room_id, &self.session_id, "app", .video) catch |err| {
            log.err("session init failed: {}", .{err});
            return error.SessionInitFailed;
        };
        self.session.viewer_registry = &self.viewer_registry;
        self.session.meta_callback = appMetaCallback;
        self.session.resize_callback = appResizeCallback;
        if (self.xinput) |*xi| {
            self.session.input_handler = xi.inputHandler();
        }

        // Encoder
        self.encoder = Encoder.init(&fbc, first_frame, .{ .session = &self.session }, config.fps) catch |err| {
            log.err("encoder init failed: {}", .{err});
            self.session.deinit();
            return error.EncoderInitFailed;
        };

        // Recording (optional — enabled by ZEROCAST_RECORD_DIR env)
        self.recorder = if (config.record_dir) |dir|
            SessionRecorder.init(dir, self.command_buf[0..self.command_len], config.fps, first_frame.width, first_frame.height)
        else
            null;
        if (self.recorder != null) {
            self.encoder.recorder = &self.recorder.?;
            self.recorder.?.logFmt("session started: {s} {d}x{d} @{d}fps", .{
                self.command_buf[0..self.command_len], first_frame.width, first_frame.height, config.fps,
            });
        }

        self.last_fps = 0;
        self.last_bitrate = 0;
        self.fbc = fbc;
        self.start_time = std.time.Timer.start() catch return error.TimerUnavailable;
    }

    pub fn start(self: *AppShare) void {
        self.session.start();
    }

    pub fn runLoop(self: *AppShare) void {
        const first_frame = self.fbc.grabFrame() catch |err| {
            log.err("first frame grab failed: {}", .{err});
            return;
        };

        self.encoder.processFrame(first_frame) catch |err| {
            log.err("first frame encode error: {}", .{err});
            return;
        };

        // Frame pacing: NvFBC push model doesn't rate-limit captures,
        // so we pace the loop to the target fps.
        const frame_interval_ns: u64 = std.time.ns_per_s / self.config.fps;
        var frame_timer = std.time.Timer.start() catch return;

        const ping_interval_ns: u64 = 30 * std.time.ns_per_s;
        var ping_timer = std.time.Timer.start() catch return;

        const meta_interval_ns: u64 = 5 * std.time.ns_per_s;
        var meta_timer = std.time.Timer.start() catch return;
        var prev_bytes: u64 = 0;
        var prev_frames: u64 = 0;

        self.sendAppMeta();

        loop: while (!self.should_stop.load(.acquire)) {
            // Check if app is still running
            if (self.app_pid) |pid| {
                const wr = posix.waitpid(pid, posix.W.NOHANG);
                if (wr.pid != 0) {
                    log.info("app exited", .{});
                    self.app_pid = null;
                    break;
                }
            }

            // Process X11 window events (ConfigureNotify, MapRequest, etc.)
            if (self.wm) |*wm| wm.processEvents();

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

                // 1. Tear down encoder (NVENC + CUDA)
                self.encoder.deinit();
                const t_encoder_deinit = ts.elapsed(&t);

                // 2. Tear down NvFBC (capture session + GLX)
                self.fbc.deinit();
                const t_fbc_deinit = ts.elapsed(&t);

                // 3. Resize display (xrandr only, no picom restart)
                self.display.resize(new_w, new_h);
                const t_xrandr = ts.elapsed(&t);

                // 4. Resize app window
                if (self.wm) |*wm| wm.resizeApp(new_w, new_h);
                const t_wm = ts.elapsed(&t);

                // 5. Rebuild NvFBC
                const display_env = self.display.displayEnv();
                var display_z: [16]u8 = undefined;
                @memcpy(display_z[0..display_env.len], display_env);
                display_z[display_env.len] = 0;

                self.fbc = NvFbc.initDisplay(.{}, self.config.fps, @ptrCast(display_z[0..display_env.len :0])) catch |e| {
                    log.err("NvFBC reinit failed: {}", .{e});
                    break :loop;
                };
                const t_fbc_init = ts.elapsed(&t);

                // 6. Grab first frame at new resolution
                const new_frame = self.fbc.grabFrame() catch |e| {
                    log.err("post-resize grab failed: {}", .{e});
                    break :loop;
                };
                const t_grab = ts.elapsed(&t);

                // 7. Rebuild encoder
                self.encoder = Encoder.init(&self.fbc, new_frame, .{ .session = &self.session }, self.config.fps) catch |e| {
                    log.err("encoder reinit failed: {}", .{e});
                    break :loop;
                };
                if (self.recorder) |*rec| {
                    self.encoder.recorder = rec;
                    rec.updateResolution(new_frame.width, new_frame.height);
                    rec.logFmt("resize: {d}x{d}", .{ new_w, new_h });
                }
                const t_encoder_init = ts.elapsed(&t);

                log.info("resize done: encoder_deinit={d}us fbc_deinit={d}us xrandr={d}us wm={d}us fbc_init={d}us grab={d}us encoder_init={d}us total={d}us", .{
                    t_encoder_deinit, t_fbc_deinit, t_xrandr, t_wm, t_fbc_init, t_grab, t_encoder_init,
                    t_encoder_deinit + t_fbc_deinit + t_xrandr + t_wm + t_fbc_init + t_grab + t_encoder_init,
                });

                self.sendAppMeta();
                frame_timer.reset();
                continue;
            }

            // Frame pacing — sleep to maintain target fps
            const elapsed_frame_ns = frame_timer.read();
            if (elapsed_frame_ns < frame_interval_ns) {
                std.Thread.sleep(frame_interval_ns - elapsed_frame_ns);
            }
            frame_timer.reset();

            const frame = self.fbc.grabFrame() catch |err| {
                log.err("capture error: {}", .{err});
                break;
            };

            self.encoder.processFrame(frame) catch |err| {
                log.err("encode error: {}", .{err});
                break;
            };
        }

        log.info("app share stopped", .{});
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
        self.session.deinit();
        if (self.xinput) |*xi| xi.deinit();
        if (self.wm) |*wm| wm.deinit();
        self.fbc.deinit();

        // Kill the app if still running
        if (self.app_pid) |pid| {
            posix.kill(pid, posix.SIG.TERM) catch {};
            _ = posix.waitpid(pid, 0);
        }

        // Stop the headless display (kills Xorg + picom)
        self.display.stop();
    }

    fn launchApp(self: *AppShare, display_env: []const u8) !posix.pid_t {
        const cmd = self.command_buf[0..self.command_len];

        const pid = posix.fork() catch return error.AppLaunchFailed;
        if (pid == 0) {
            // Child: set DISPLAY and exec the command via shell
            var display_z: [16]u8 = undefined;
            @memcpy(display_z[0..display_env.len], display_env);
            display_z[display_env.len] = 0;
            _ = c.setenv("DISPLAY", @ptrCast(display_z[0..display_env.len :0]), 1);

            // Cap app frame rate via fpscap.so (LD_PRELOAD glXSwapBuffers hook).
            // Without vsync (UseDisplayDevice "none" has no vblank), GL apps spin at 100% CPU.
            // fpscap.so uses clock_nanosleep to pace frames — no vblank dependency.
            {
                var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
                if (posix.readlinkZ("/proc/self/exe", &exe_buf)) |exe_path| {
                    // Find parent of bin/ dir (exe is at <prefix>/bin/zerocast)
                    var dir_end: usize = 0;
                    for (exe_path, 0..) |ch, i| {
                        if (ch == '/') dir_end = i;
                    }
                    // dir_end points to /bin, find prefix above it
                    var prefix_end: usize = 0;
                    for (exe_path[0..dir_end], 0..) |ch, i| {
                        if (ch == '/') prefix_end = i;
                    }
                    var fpscap_path: [std.fs.max_path_bytes]u8 = undefined;
                    const suffix = "/lib/libfpscap.so";
                    @memcpy(fpscap_path[0..prefix_end], exe_path[0..prefix_end]);
                    @memcpy(fpscap_path[prefix_end..][0..suffix.len], suffix);
                    fpscap_path[prefix_end + suffix.len] = 0;
                    _ = c.setenv("LD_PRELOAD", @ptrCast(fpscap_path[0 .. prefix_end + suffix.len :0]), 1);
                } else |_| {}
                var fps_z: [8]u8 = undefined;
                const fps_str = std.fmt.bufPrint(&fps_z, "{d}", .{self.config.fps}) catch "30";
                fps_z[fps_str.len] = 0;
                _ = c.setenv("FPS", @ptrCast(fps_z[0..fps_str.len :0]), 1);
            }

            // Redirect stdout/stderr to /dev/null
            const devnull = posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch posix.exit(127);
            posix.dup2(devnull, 1) catch {};
            posix.dup2(devnull, 2) catch {};

            // Null-terminate the command for execve
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

        log.info("launched app: {s} (pid {d})", .{ cmd, pid });
        return pid;
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

fn appResizeCallback(session: *BroadcastSession, width: u16, height: u16) void {
    const self: *AppShare = @alignCast(@fieldParentPtr("session", session));
    if (width < 100 or height < 100) return;
    // Skip no-op resizes (viewer often sends back the current video resolution)
    if (@as(u32, width) == self.display.width and @as(u32, height) == self.display.height) return;
    log.info("viewer resize requested: {d}x{d}", .{ width, height });
    self.pending_resize.store((@as(u32, width) << 16) | @as(u32, height), .release);
}
