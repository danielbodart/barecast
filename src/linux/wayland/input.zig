const std = @import("std");
const keymap = @import("keymap");
const InputHandler = @import("session").InputHandler;

const log = std.log.scoped(.wayland_input);

const c = @cImport({
    @cDefine("WLR_USE_UNSTABLE", "");
    @cInclude("wayland-server-core.h");
    @cInclude("wlr/types/wlr_seat.h");
    @cInclude("wlr/types/wlr_keyboard.h");
    @cInclude("wlr/types/wlr_pointer.h");
    @cInclude("wlr/interfaces/wlr_keyboard.h");
    @cInclude("wlr/interfaces/wlr_pointer.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("linux/input-event-codes.h");
    @cInclude("time.h");
});

/// Input event types for the cross-thread queue.
const InputEvent = union(enum) {
    mouse_move: struct { x: u16, y: u16 },
    mouse_button: struct { button: u8, value: i32 },
    scroll: struct { delta: i16 },
    key: struct { code: u16, value: i32 },
};

const QUEUE_SIZE = 256;

/// Wayland input injection via wlr_seat.
/// Input events are queued from the network thread and drained
/// on the compositor thread before each dispatch().
pub const WaylandInput = struct {
    seat: *anyopaque,
    keyboard: c.wlr_keyboard,
    pointer: c.wlr_pointer,
    xkb_context: *c.xkb_context,
    surface: ?*anyopaque,
    output_width: u32,
    output_height: u32,
    // XDG geometry offset: video coordinates are relative to the content area,
    // but wlr_seat expects surface-local coords (including CSD header bar).
    geo_offset_x: i32,
    geo_offset_y: i32,

    // Lock-free SPSC ring buffer (single producer = network thread, single consumer = compositor thread)
    queue: [QUEUE_SIZE]InputEvent,
    write_idx: std.atomic.Value(u32),
    read_idx: std.atomic.Value(u32),

    fn seatPtr(self: *WaylandInput) *c.wlr_seat {
        return @ptrCast(@alignCast(self.seat));
    }

    const keyboard_impl: c.wlr_keyboard_impl = .{
        .name = "zerocast-keyboard",
        .led_update = null,
    };

    const pointer_impl: c.wlr_pointer_impl = .{
        .name = "zerocast-pointer",
    };

    pub fn init(seat_opaque: *anyopaque, width: u32, height: u32) !WaylandInput {
        var self: WaylandInput = undefined;
        self.seat = seat_opaque;
        self.surface = null;
        self.output_width = width;
        self.output_height = height;
        self.geo_offset_x = 0;
        self.geo_offset_y = 0;
        self.write_idx = std.atomic.Value(u32).init(0);
        self.read_idx = std.atomic.Value(u32).init(0);

        // Initialize virtual keyboard
        self.keyboard = std.mem.zeroes(c.wlr_keyboard);
        c.wlr_keyboard_init(&self.keyboard, &keyboard_impl, "zerocast-keyboard");

        // Set up xkbcommon keymap (required by Wayland keyboard protocol)
        self.xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse {
            log.err("xkb_context_new failed", .{});
            return error.XkbInitFailed;
        };

        const xkb_keymap = c.xkb_keymap_new_from_names(self.xkb_context, null, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse {
            log.err("xkb_keymap_new_from_names failed", .{});
            c.xkb_context_unref(self.xkb_context);
            return error.XkbInitFailed;
        };
        defer c.xkb_keymap_unref(xkb_keymap);

        if (!c.wlr_keyboard_set_keymap(&self.keyboard, xkb_keymap)) {
            log.err("wlr_keyboard_set_keymap failed", .{});
            c.xkb_context_unref(self.xkb_context);
            return error.XkbInitFailed;
        }

        // Initialize virtual pointer
        self.pointer = std.mem.zeroes(c.wlr_pointer);
        c.wlr_pointer_init(&self.pointer, &pointer_impl, "zerocast-pointer");

        // Set seat capabilities and attach keyboard
        c.wlr_seat_set_capabilities(self.seatPtr(), c.WL_SEAT_CAPABILITY_KEYBOARD | c.WL_SEAT_CAPABILITY_POINTER);
        c.wlr_seat_set_keyboard(self.seatPtr(), &self.keyboard);

        log.info("wayland input initialized ({d}x{d})", .{ width, height });

        return self;
    }

    pub fn deinit(self: *WaylandInput) void {
        c.wlr_keyboard_finish(&self.keyboard);
        c.wlr_pointer_finish(&self.pointer);
        c.xkb_context_unref(self.xkb_context);
    }

    /// Set the focused surface (called when toplevel maps).
    /// Takes *anyopaque because the compositor and input modules have separate cImports.
    pub fn setFocusSurface(self: *WaylandInput, surface_opaque: *anyopaque, geo_x: i32, geo_y: i32) void {
        const surface: ?*c.wlr_surface = @ptrCast(surface_opaque);
        self.surface = surface_opaque;
        self.geo_offset_x = geo_x;
        self.geo_offset_y = geo_y;
        // Enter the surface for both keyboard and pointer
        c.wlr_seat_keyboard_notify_enter(self.seatPtr(), surface, null, 0, null);
        c.wlr_seat_pointer_notify_enter(self.seatPtr(), surface, 0, 0);
        log.info("input focus set, geometry offset=({d},{d})", .{ geo_x, geo_y });
    }

    /// Update output dimensions (called on resize).
    pub fn updateSize(self: *WaylandInput, width: u32, height: u32) void {
        self.output_width = width;
        self.output_height = height;
    }

    // ── Queue: push from network thread ──────────────────────────

    fn enqueue(self: *WaylandInput, event: InputEvent) void {
        const w = self.write_idx.load(.monotonic);
        const r = self.read_idx.load(.acquire);
        const next_w = (w + 1) % QUEUE_SIZE;
        if (next_w == r) return; // full, drop event
        self.queue[w] = event;
        self.write_idx.store(next_w, .release);
    }

    /// Drain queued events on the compositor thread. Call before dispatch().
    pub fn drainEvents(self: *WaylandInput) void {
        var count: u32 = 0;
        while (true) {
            const r = self.read_idx.load(.monotonic);
            const w = self.write_idx.load(.acquire);
            if (r == w) break;
            const event = self.queue[r];
            self.read_idx.store((r + 1) % QUEUE_SIZE, .release);
            self.applyEvent(event);
            count += 1;
        }
        if (count > 0) {
            log.info("drained {d} input events", .{count});
        }
    }

    fn applyEvent(self: *WaylandInput, event: InputEvent) void {
        if (self.surface == null) {
            log.warn("input event dropped: no focused surface", .{});
            return;
        }
        const now = getTimeMs();

        switch (event) {
            .mouse_move => |m| {
                // Video coords are content-area relative; add CSD offset for surface-local
                const sx: f64 = @floatFromInt(@as(i32, m.x) + self.geo_offset_x);
                const sy: f64 = @floatFromInt(@as(i32, m.y) + self.geo_offset_y);
                log.debug("mouse_move ({d},{d}) -> surface ({d},{d})", .{ m.x, m.y, @as(i32, m.x) + self.geo_offset_x, @as(i32, m.y) + self.geo_offset_y });
                c.wlr_seat_pointer_notify_motion(self.seatPtr(), now, sx, sy);
                c.wlr_seat_pointer_notify_frame(self.seatPtr());
            },
            .mouse_button => |b| {
                // input_protocol: 0=left, 1=right, 2=middle
                // Linux: BTN_LEFT=0x110, BTN_RIGHT=0x111, BTN_MIDDLE=0x112
                const linux_button: u32 = switch (b.button) {
                    0 => c.BTN_LEFT,
                    1 => c.BTN_RIGHT,
                    2 => c.BTN_MIDDLE,
                    else => return,
                };
                const state: c_uint = @intCast(if (b.value != 0) c.WL_POINTER_BUTTON_STATE_PRESSED else c.WL_POINTER_BUTTON_STATE_RELEASED);
                log.debug("mouse_button btn={d} state={d}", .{ b.button, b.value });
                _ = c.wlr_seat_pointer_notify_button(self.seatPtr(), now, linux_button, state);
                c.wlr_seat_pointer_notify_frame(self.seatPtr());
            },
            .scroll => |s| {
                // Wayland axis: positive = scroll down, negative = scroll up
                // input_protocol: positive = scroll up, negative = scroll down (matching browser wheelDelta)
                const value: f64 = @as(f64, @floatFromInt(-s.delta)) / 120.0 * 15.0;
                const discrete: i32 = @intCast(@divTrunc(-@as(i32, s.delta), 120));
                c.wlr_seat_pointer_notify_axis(
                    self.seatPtr(),
                    now,
                    c.WLR_AXIS_ORIENTATION_VERTICAL,
                    value,
                    discrete,
                    c.WLR_AXIS_SOURCE_WHEEL,
                );
                c.wlr_seat_pointer_notify_frame(self.seatPtr());
            },
            .key => |k| {
                // Wayland keycodes are evdev codes directly (no offset like X11)
                const state: u32 = if (k.value != 0) c.WL_KEYBOARD_KEY_STATE_PRESSED else c.WL_KEYBOARD_KEY_STATE_RELEASED;
                log.debug("key code={d} state={d}", .{ k.code, k.value });
                c.wlr_seat_keyboard_notify_key(self.seatPtr(), now, k.code, state);
            },
        }
    }

    fn getTimeMs() u32 {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        return @intCast(@as(u64, @intCast(ts.tv_sec)) * 1000 + @as(u64, @intCast(ts.tv_nsec)) / 1_000_000);
    }

    // ── InputHandler vtable (called from network thread) ─────────

    pub fn inputHandler(self: *WaylandInput) InputHandler {
        return .{
            .ptr = @ptrCast(self),
            .moveFn = @ptrCast(&struct {
                fn f(ptr: *anyopaque, x: u16, y: u16) void {
                    const s: *WaylandInput = @alignCast(@ptrCast(ptr));
                    s.enqueue(.{ .mouse_move = .{ .x = x, .y = y } });
                }
            }.f),
            .mouseButtonFn = @ptrCast(&struct {
                fn f(ptr: *anyopaque, button: u8, value: i32) void {
                    const s: *WaylandInput = @alignCast(@ptrCast(ptr));
                    s.enqueue(.{ .mouse_button = .{ .button = button, .value = value } });
                }
            }.f),
            .scrollFn = @ptrCast(&struct {
                fn f(ptr: *anyopaque, delta: i16) void {
                    const s: *WaylandInput = @alignCast(@ptrCast(ptr));
                    s.enqueue(.{ .scroll = .{ .delta = delta } });
                }
            }.f),
            .keyCodeFn = @ptrCast(&struct {
                fn f(ptr: *anyopaque, code: []const u8, value: i32) void {
                    const s: *WaylandInput = @alignCast(@ptrCast(ptr));
                    const evdev_code = keymap.lookup(code) orelse {
                        log.debug("unmapped key: {s}", .{code});
                        return;
                    };
                    s.enqueue(.{ .key = .{ .code = evdev_code, .value = value } });
                }
            }.f),
        };
    }
};
