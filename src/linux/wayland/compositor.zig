const std = @import("std");

const log = std.log.scoped(.compositor);

const c = @cImport({
    @cDefine("WLR_USE_UNSTABLE", "");
    @cInclude("wayland-server-core.h");
    @cInclude("wlr/backend.h");
    @cInclude("wlr/backend/headless.h");
    @cInclude("wlr/render/allocator.h");
    @cInclude("wlr/render/wlr_renderer.h");
    @cInclude("wlr/render/gles2.h");
    @cInclude("wlr/render/egl.h");
    @cInclude("wlr/types/wlr_compositor.h");
    @cInclude("wlr/types/wlr_output.h");
    @cInclude("wlr/types/wlr_output_layout.h");
    @cInclude("wlr/types/wlr_scene.h");
    @cInclude("wlr/types/wlr_subcompositor.h");
    @cInclude("wlr/types/wlr_xdg_shell.h");
    @cInclude("wlr/types/wlr_seat.h");
    @cInclude("wlr/types/wlr_data_device.h");
    @cInclude("wlr/render/dmabuf.h");
    @cInclude("wlr/util/log.h");
    @cInclude("gles2_helper.h");
    @cInclude("time.h");
});

/// A captured frame from the compositor, backed by a DMA-BUF.
pub const CapturedFrame = struct {
    dmabuf: c.wlr_dmabuf_attributes,
    buffer: *c.wlr_buffer,
    width: u32,
    height: u32,
    is_new: bool,
    /// GL renderbuffer ID (from wlroots GLES2 renderer). 0 if unavailable.
    rbo: u32 = 0,
    /// GL framebuffer object ID (from wlroots GLES2 renderer). 0 if unavailable.
    fbo: u32 = 0,
};

/// Minimal embedded Wayland compositor for headless app sharing.
/// Uses wlroots headless backend — no physical display, arbitrary resolution.
/// Apps connect as Wayland clients, render on the GPU, and we capture
/// each frame directly from the scene graph output buffer.
pub const Compositor = struct {
    display: *c.wl_display,
    backend: *c.wlr_backend,
    renderer: *c.wlr_renderer,
    allocator: *c.wlr_allocator,
    scene: *c.wlr_scene,
    scene_layout: *c.wlr_scene_output_layout,
    output_layout: *c.wlr_output_layout,
    output: *c.wlr_output,
    scene_output: *c.wlr_scene_output,
    xdg_shell: *c.wlr_xdg_shell,
    seat: *c.wlr_seat,
    socket_buf: [32]u8,
    socket_len: u8,
    width: u32,
    height: u32,
    fps: u32,
    last_surface_seq: u32,

    // Tracked toplevel (the app's main window)
    toplevel: ?*c.wlr_xdg_toplevel = null,
    toplevel_surface: ?*c.wlr_xdg_surface = null,

    // Listeners
    new_toplevel: c.wl_listener,
    output_frame: c.wl_listener,
    toplevel_map: c.wl_listener,
    toplevel_commit: c.wl_listener,

    // Frame callback — called with DMA-BUF of the rendered frame
    frame_callback: ?*const fn (frame: *const CapturedFrame, userdata: ?*anyopaque) void,
    frame_userdata: ?*anyopaque,

    // Resize callback — notifies app_share when the app's initial size is known
    resize_callback: ?*const fn (width: u32, height: u32, userdata: ?*anyopaque) void = null,
    resize_userdata: ?*anyopaque = null,

    // Toplevel map callback — notifies app_share when the app's surface is ready for input focus.
    // geo_x/geo_y: XDG geometry offset (CSD header bar) — input coords must add this.
    map_callback: ?*const fn (surface: *anyopaque, geo_x: i32, geo_y: i32, userdata: ?*anyopaque) void = null,
    map_userdata: ?*anyopaque = null,

    pub fn init(width: u32, height: u32, fps: u32, render_device: ?[*:0]const u8) !*Compositor {
        const allocator = std.heap.c_allocator;
        const self = try allocator.create(Compositor);
        errdefer allocator.destroy(self);

        c.wlr_log_init(c.WLR_INFO, null);

        // Create Wayland display
        self.display = c.wl_display_create() orelse {
            log.err("wl_display_create failed", .{});
            return error.CompositorInitFailed;
        };

        const setenv = @extern(*const fn ([*:0]const u8, [*:0]const u8, c_int) callconv(.c) c_int, .{ .name = "setenv" });

        // Force wlroots to use the same GPU as VA-API encode (e.g. Intel iGPU)
        if (render_device) |dev| {
            _ = setenv("WLR_RENDER_DRM_DEVICE", dev, 1);
        }

        // Disable direct scanout so the scene graph always composites into the
        // swapchain buffer. Without this, wlroots passes the client's buffer through
        // directly — which may use CCS compression that VA-API cannot import.
        _ = setenv("WLR_SCENE_DISABLE_DIRECT_SCANOUT", "1", 1);

        // Create headless backend (no physical display needed)
        self.backend = c.wlr_headless_backend_create(self.display) orelse {
            log.err("headless backend creation failed", .{});
            return error.CompositorInitFailed;
        };

        // Create renderer (EGL/GLES2 — uses the GPU for compositing)
        self.renderer = c.wlr_renderer_autocreate(self.backend) orelse {
            log.err("renderer creation failed", .{});
            return error.CompositorInitFailed;
        };

        _ = c.wlr_renderer_init_wl_display(self.renderer, self.display);

        // Create allocator (GBM — allocates GPU buffers)
        self.allocator = c.wlr_allocator_autocreate(self.backend, self.renderer) orelse {
            log.err("allocator creation failed", .{});
            return error.CompositorInitFailed;
        };

        // Compositor + subcompositor (required Wayland globals)
        _ = c.wlr_compositor_create(self.display, 5, self.renderer) orelse {
            log.err("wlr_compositor_create failed", .{});
            return error.CompositorInitFailed;
        };
        _ = c.wlr_subcompositor_create(self.display);

        // Data device manager (clipboard — required by many apps)
        _ = c.wlr_data_device_manager_create(self.display);

        // Scene graph (wlroots' built-in scene manager — handles rendering)
        self.scene = c.wlr_scene_create() orelse {
            log.err("scene creation failed", .{});
            return error.CompositorInitFailed;
        };

        // Output layout
        self.output_layout = c.wlr_output_layout_create() orelse {
            log.err("output layout creation failed", .{});
            return error.CompositorInitFailed;
        };

        self.scene_layout = c.wlr_scene_attach_output_layout(self.scene, self.output_layout) orelse {
            log.err("scene output layout creation failed", .{});
            return error.CompositorInitFailed;
        };

        // XDG shell (window management protocol for Wayland apps)
        self.xdg_shell = c.wlr_xdg_shell_create(self.display, 3) orelse {
            log.err("xdg_shell creation failed", .{});
            return error.CompositorInitFailed;
        };

        // Listen for new xdg surfaces (wlroots 0.17: new_surface, 0.20: new_toplevel)
        self.new_toplevel = std.mem.zeroes(c.wl_listener);
        self.new_toplevel.notify = @ptrCast(&handleNewToplevel);
        c.wl_signal_add(&self.xdg_shell.events.new_surface, &self.new_toplevel);

        // Seat (input handling — needed even headless for focus)
        self.seat = c.wlr_seat_create(self.display, "seat0") orelse {
            log.err("seat creation failed", .{});
            return error.CompositorInitFailed;
        };

        // Start the backend
        if (!c.wlr_backend_start(self.backend)) {
            log.err("backend start failed", .{});
            return error.CompositorInitFailed;
        }

        // Create headless output at the requested resolution
        self.output = c.wlr_headless_add_output(self.backend, width, height) orelse {
            log.err("headless output creation failed", .{});
            return error.CompositorInitFailed;
        };

        // Initialize output rendering (connects allocator + renderer to the output)
        if (!c.wlr_output_init_render(self.output, self.allocator, self.renderer)) {
            log.err("output render init failed", .{});
            return error.CompositorInitFailed;
        }
        self.width = width;
        self.height = height;
        self.fps = fps;
        self.last_surface_seq = 0;

        // Add output to layout and scene
        const layout_output = c.wlr_output_layout_add_auto(self.output_layout, self.output) orelse {
            log.err("output layout add failed", .{});
            return error.CompositorInitFailed;
        };

        self.scene_output = c.wlr_scene_output_create(self.scene, self.output) orelse {
            log.err("scene output creation failed", .{});
            return error.CompositorInitFailed;
        };
        c.wlr_scene_output_layout_add_output(self.scene_layout, layout_output, self.scene_output);

        // Listen for frame events (called each time the output renders)
        self.output_frame = std.mem.zeroes(c.wl_listener);
        self.output_frame.notify = @ptrCast(&handleFrame);
        c.wl_signal_add(&self.output.events.frame, &self.output_frame);

        self.frame_callback = null;
        self.frame_userdata = null;
        self.toplevel = null;
        self.toplevel_surface = null;
        self.toplevel_map = std.mem.zeroes(c.wl_listener);
        self.toplevel_commit = std.mem.zeroes(c.wl_listener);

        // Enable the output with target refresh rate (drives the single frame loop)
        {
            var out_state: c.wlr_output_state = undefined;
            c.wlr_output_state_init(&out_state);
            c.wlr_output_state_set_enabled(&out_state, true);
            c.wlr_output_state_set_custom_mode(&out_state, @intCast(width), @intCast(height), @intCast(fps * 1000));
            _ = c.wlr_output_commit_state(self.output, &out_state);
            c.wlr_output_state_finish(&out_state);
        }

        // Create Wayland socket with explicit name (prevents other apps from
        // discovering it — only our child process has WAYLAND_DISPLAY set to this)
        const socket_name = "zerocast-0";
        if (c.wl_display_add_socket(self.display, socket_name) != 0) {
            log.err("failed to create Wayland socket '{s}'", .{socket_name});
            return error.CompositorInitFailed;
        }
        @memcpy(self.socket_buf[0..socket_name.len], socket_name);
        self.socket_buf[socket_name.len] = 0;
        self.socket_len = socket_name.len;

        log.info("compositor ready: {d}x{d} on {s}", .{ width, height, socket_name });

        return self;
    }

    /// Run the compositor event loop (blocks).
    pub fn run(self: *Compositor) void {
        log.info("running compositor event loop", .{});
        c.wl_display_run(self.display);
    }

    /// Dispatch events, blocking up to timeout_ms for the next frame event.
    /// Pass 0 for non-blocking, -1 for indefinite.
    pub fn dispatch(self: *Compositor, timeout_ms: c_int) void {
        _ = c.wl_display_flush_clients(self.display);
        _ = c.wl_event_loop_dispatch(c.wl_display_get_event_loop(self.display), timeout_ms);
    }

    /// Resize the headless output and the app's toplevel window.
    pub fn resize(self: *Compositor, width: u32, height: u32) void {
        self.width = width;
        self.height = height;

        // Resize compositor output (preserve fps refresh rate)
        var state: c.wlr_output_state = undefined;
        c.wlr_output_state_init(&state);
        c.wlr_output_state_set_custom_mode(&state, @intCast(width), @intCast(height), @intCast(self.fps * 1000));
        _ = c.wlr_output_commit_state(self.output, &state);
        c.wlr_output_state_finish(&state);

        // Then resize the app's toplevel to fill the new output
        if (self.toplevel) |tl| {
            _ = c.wlr_xdg_toplevel_set_size(tl, @intCast(width), @intCast(height));
        }

        log.info("resized to {d}x{d}", .{ width, height });
    }

    /// Get the toplevel's wlr_surface as opaque pointer (for cross-module input focus).
    pub fn getToplevelSurface(self: *const Compositor) ?*anyopaque {
        if (self.toplevel_surface) |xdg| return @ptrCast(xdg.surface);
        return null;
    }

    /// Get the XDG geometry offset (CSD header bar). Input coordinates from
    /// the video must add this offset to become surface-local coordinates.
    pub fn getGeometryOffset(self: *const Compositor) struct { x: i32, y: i32 } {
        if (self.toplevel_surface) |xdg| {
            var box: c.wlr_box = undefined;
            c.wlr_xdg_surface_get_geometry(xdg, &box);
            return .{ .x = box.x, .y = box.y };
        }
        return .{ .x = 0, .y = 0 };
    }

    /// Get the Wayland socket name for client connections.
    pub fn socketName(self: *const Compositor) [*:0]const u8 {
        return @ptrCast(self.socket_buf[0..self.socket_len]);
    }

    pub fn deinit(self: *Compositor) void {
        c.wlr_backend_destroy(self.backend);
        c.wl_display_destroy(self.display);
        std.heap.c_allocator.destroy(self);
        log.info("compositor destroyed", .{});
    }

    // ── Callbacks ────────────────────────────────────────────────────────

    fn handleNewToplevel(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Compositor = @ptrCast(@alignCast(@as([*]u8, @ptrCast(listener)) - @offsetOf(Compositor, "new_toplevel")));
        const xdg_surface: *c.wlr_xdg_surface = @ptrCast(@alignCast(data));

        // Only handle toplevel surfaces (not popups)
        if (xdg_surface.role != c.WLR_XDG_SURFACE_ROLE_TOPLEVEL) return;

        const toplevel = xdg_surface.*.unnamed_0.toplevel;

        log.info("new toplevel: {s}", .{
            if (toplevel.*.title) |t| std.mem.span(t) else "(untitled)",
        });

        // Add the surface to the scene graph
        _ = c.wlr_scene_xdg_surface_create(
            &self.scene.tree,
            xdg_surface,
        );

        // Track this toplevel for resize
        self.toplevel = toplevel;
        self.toplevel_surface = xdg_surface;

        // Activate (give keyboard focus)
        _ = c.wlr_xdg_toplevel_set_activated(toplevel, true);

        // Listen for map (surface has content, geometry is known)
        self.toplevel_map = std.mem.zeroes(c.wl_listener);
        self.toplevel_map.notify = @ptrCast(&handleToplevelMap);
        c.wl_signal_add(&xdg_surface.surface.*.events.map, &self.toplevel_map);

        // Listen for commits (geometry changes after initial map)
        self.toplevel_commit = std.mem.zeroes(c.wl_listener);
        self.toplevel_commit.notify = @ptrCast(&handleToplevelCommit);
        c.wl_signal_add(&xdg_surface.surface.*.events.commit, &self.toplevel_commit);
    }

    fn handleToplevelMap(listener: [*c]c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Compositor = @ptrCast(@alignCast(@as([*]u8, @ptrCast(listener)) - @offsetOf(Compositor, "toplevel_map")));

        const xdg_surface = self.toplevel_surface orelse return;
        var box: c.wlr_box = undefined;
        c.wlr_xdg_surface_get_geometry(xdg_surface, &box);

        if (box.width > 0 and box.height > 0) {
            log.info("toplevel mapped: {d}x{d} geometry_offset=({d},{d})", .{ box.width, box.height, box.x, box.y });
        }

        // Notify app_share so input can be focused on this surface.
        // Pass the geometry offset (CSD header bar) so input coords can be corrected.
        if (self.map_callback) |cb| {
            cb(@ptrCast(xdg_surface.surface), box.x, box.y, self.map_userdata);
        }
    }

    var last_committed_w: u32 = 0;
    var last_committed_h: u32 = 0;

    fn handleToplevelCommit(listener: [*c]c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Compositor = @ptrCast(@alignCast(@as([*]u8, @ptrCast(listener)) - @offsetOf(Compositor, "toplevel_commit")));

        const xdg_surface = self.toplevel_surface orelse return;

        // Get the xdg geometry (excludes shadows/borders, just the content area)
        var box: c.wlr_box = undefined;
        c.wlr_xdg_surface_get_geometry(xdg_surface, &box);

        const w: u32 = if (box.width > 0) @intCast(box.width) else return;
        const h: u32 = if (box.height > 0) @intCast(box.height) else return;

        // Only act if the app's size changed
        if (w == last_committed_w and h == last_committed_h) return;
        last_committed_w = w;
        last_committed_h = h;

        // Resize the compositor output to match the app
        if (w != self.width or h != self.height) {
            log.info("app resized to {d}x{d} — resizing compositor", .{ w, h });
            self.width = w;
            self.height = h;
            var state: c.wlr_output_state = undefined;
            c.wlr_output_state_init(&state);
            c.wlr_output_state_set_custom_mode(&state, @intCast(w), @intCast(h), @intCast(self.fps * 1000));
            _ = c.wlr_output_commit_state(self.output, &state);
            c.wlr_output_state_finish(&state);

            // Notify app_share so the encoder can rebuild at the new size
            if (self.resize_callback) |cb| {
                cb(w, h, self.resize_userdata);
            }
        }
    }

    var frame_counter: u64 = 0;

    fn handleFrame(listener: [*c]c.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const self: *Compositor = @ptrCast(@alignCast(@as([*]u8, @ptrCast(listener)) - @offsetOf(Compositor, "output_frame")));

        frame_counter += 1;
        if (frame_counter == 1 or frame_counter % 60 == 0) {
            log.info("frame {d}", .{frame_counter});
        }

        // Check if the app committed new content since last frame
        const is_new = if (self.toplevel_surface) |xdg| blk: {
            const seq = xdg.surface.*.current.seq;
            if (seq == self.last_surface_seq) break :blk false;
            self.last_surface_seq = seq;
            break :blk true;
        } else false;

        // Build output state (renders scene into a buffer without committing)
        var state: c.wlr_output_state = undefined;
        c.wlr_output_state_init(&state);

        if (!c.wlr_scene_output_build_state(self.scene_output, &state, null)) {
            c.wlr_output_state_finish(&state);
            sendFrameDone(self);
            return;
        }

        // Extract DMA-BUF from the rendered buffer and notify callback
        if (self.frame_callback) |cb| {
            if (state.committed & c.WLR_OUTPUT_STATE_BUFFER != 0) {
                const buf = state.buffer;
                _ = c.wlr_buffer_lock(buf);
                var attribs: c.wlr_dmabuf_attributes = undefined;
                if (c.wlr_buffer_get_dmabuf(buf, &attribs)) {
                    var frame = CapturedFrame{
                        .dmabuf = attribs,
                        .buffer = buf,
                        .width = self.width,
                        .height = self.height,
                        .is_new = is_new,
                        .rbo = c.gles2_get_buffer_rbo(self.renderer, buf),
                        .fbo = c.gles2_get_buffer_fbo(self.renderer, buf),
                    };
                    cb(&frame, self.frame_userdata);
                }
                c.wlr_buffer_unlock(buf);
            }
        }

        // Commit the rendered state to the output
        _ = c.wlr_output_commit_state(self.output, &state);
        c.wlr_output_state_finish(&state);

        sendFrameDone(self);
    }

    fn sendFrameDone(self: *Compositor) void {
        var now: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &now);
        c.wlr_scene_output_send_frame_done(self.scene_output, &now);
    }
};
