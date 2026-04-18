const std = @import("std");
const keymap = @import("keymap");
const InputHandler = @import("session").InputHandler;

const log = std.log.scoped(.cgevent);

const cg = @cImport({
    @cInclude("CoreGraphics/CoreGraphics.h");
    @cInclude("ApplicationServices/ApplicationServices.h");
    @cInclude("screen_capture.h");
});

/// Input injection via CGEvent on macOS.
/// Posts mouse and keyboard events to a specific app process.
/// Requires Accessibility permission (AXIsProcessTrusted).
pub const CGEventInput = Input;

pub const Input = struct {
    pid: i64,
    /// Window origin in screen coordinates (queried from AXUIElement).
    /// Mouse events are offset by this to convert from window-relative
    /// coordinates (sent by the viewer) to absolute screen coordinates
    /// (required by CGEvent).
    win_x: f64,
    win_y: f64,
    /// Last absolute screen position from moveMouse — used by injectMouseButton
    /// so clicks land at the cursor, not the window origin.
    last_abs_x: f64,
    last_abs_y: f64,

    pub fn init(pid: i64) !Input {
        // Check Accessibility permission — show system prompt if not granted
        if (cg.AXIsProcessTrusted() == 0) {
            log.info("Requesting Accessibility permission...", .{});
            _ = cg.sc_request_accessibility_permission();
            // Don't block — the prompt is shown, user can grant while share runs.
            // Input injection will be disabled until they grant and reshare.
            return error.AccessibilityDenied;
        }

        // Query initial window position
        var win_x: f64 = 0;
        var win_y: f64 = 0;
        if (cg.sc_get_window_position(pid, &win_x, &win_y) != 0) {
            log.warn("cannot query window position for pid {d}, using (0,0)", .{pid});
        }

        log.info("CGEvent input: pid {d}, window at ({d:.0}, {d:.0})", .{ pid, win_x, win_y });

        return .{
            .pid = pid,
            .win_x = win_x,
            .win_y = win_y,
            .last_abs_x = win_x,
            .last_abs_y = win_y,
        };
    }

    /// Refresh the cached window position (call after resize/move).
    pub fn refreshWindowPosition(self: *Input) void {
        var x: f64 = 0;
        var y: f64 = 0;
        if (cg.sc_get_window_position(self.pid, &x, &y) == 0) {
            self.win_x = x;
            self.win_y = y;
        }
    }

    /// Move the pointer to absolute coordinates (window-relative input).
    pub fn moveMouse(self: *Input, abs_x: u16, abs_y: u16) void {
        const screen_x = self.win_x + @as(f64, @floatFromInt(abs_x));
        const screen_y = self.win_y + @as(f64, @floatFromInt(abs_y));
        self.last_abs_x = screen_x;
        self.last_abs_y = screen_y;

        const point = cg.CGPointMake(screen_x, screen_y);
        const event = cg.CGEventCreateMouseEvent(null, cg.kCGEventMouseMoved, point, cg.kCGMouseButtonLeft);
        if (event) |ev| {
            cg.CGEventPostToPid(@intCast(self.pid), ev);
            cg.CFRelease(ev);
        }
    }

    /// Inject a mouse button press (value=1) or release (value=0).
    /// button: 0=left, 1=right, 2=middle (matches input_protocol.MouseButton)
    pub fn injectMouseButton(self: *Input, button: u8, value: i32) void {
        const point = cg.CGPointMake(self.last_abs_x, self.last_abs_y);
        const is_down = value != 0;

        const event_type: u32 = switch (button) {
            0 => if (is_down) cg.kCGEventLeftMouseDown else cg.kCGEventLeftMouseUp,
            1 => if (is_down) cg.kCGEventRightMouseDown else cg.kCGEventRightMouseUp,
            2 => if (is_down) cg.kCGEventOtherMouseDown else cg.kCGEventOtherMouseUp,
            else => return,
        };

        const cg_button: u32 = switch (button) {
            0 => cg.kCGMouseButtonLeft,
            1 => cg.kCGMouseButtonRight,
            2 => cg.kCGMouseButtonCenter,
            else => return,
        };

        const event = cg.CGEventCreateMouseEvent(null, event_type, point, cg_button);
        if (event) |ev| {
            cg.CGEventPostToPid(@intCast(self.pid), ev);
            cg.CFRelease(ev);
        }
    }

    /// Inject scroll events. delta uses the 120-units-per-click convention.
    pub fn injectScroll(self: *Input, delta: i16) void {
        // CGEventCreateScrollWheelEvent uses "line" units (1 line ≈ 1 notch).
        // Input protocol sends ±120 per notch, so divide.
        const lines: i32 = @divTrunc(@as(i32, delta), 120);
        const scroll_amount: i32 = if (lines == 0) (if (delta > 0) @as(i32, 1) else @as(i32, -1)) else lines;

        const event = cg.CGEventCreateScrollWheelEvent(null, cg.kCGScrollEventUnitLine, 1, scroll_amount);
        if (event) |ev| {
            cg.CGEventPostToPid(@intCast(self.pid), ev);
            cg.CFRelease(ev);
        }
    }

    /// Inject a key press (value=1) or release (value=0).
    /// code: KeyboardEvent.code string (e.g. "KeyA", "Space")
    pub fn injectKeyCode(self: *Input, code: []const u8, value: i32) void {
        const mac_keycode = keymap.lookup(code) orelse {
            log.debug("unmapped key: {s}", .{code});
            return;
        };

        const event = cg.CGEventCreateKeyboardEvent(null, mac_keycode, value != 0);
        if (event) |ev| {
            cg.CGEventPostToPid(@intCast(self.pid), ev);
            cg.CFRelease(ev);
        }
    }

    /// Return an InputHandler interface compatible with session.zig.
    pub fn inputHandler(self: *Input) InputHandler {
        return .{
            .ptr = @ptrCast(self),
            .moveFn = @ptrCast(&struct {
                fn f(ptr: *anyopaque, abs_x: u16, abs_y: u16) void {
                    const s: *Input = @alignCast(@ptrCast(ptr));
                    s.moveMouse(abs_x, abs_y);
                }
            }.f),
            .mouseButtonFn = @ptrCast(&struct {
                fn f(ptr: *anyopaque, button: u8, value: i32) void {
                    const s: *Input = @alignCast(@ptrCast(ptr));
                    s.injectMouseButton(button, value);
                }
            }.f),
            .scrollFn = @ptrCast(&struct {
                fn f(ptr: *anyopaque, delta: i16) void {
                    const s: *Input = @alignCast(@ptrCast(ptr));
                    s.injectScroll(delta);
                }
            }.f),
            .keyCodeFn = @ptrCast(&struct {
                fn f(ptr: *anyopaque, code: []const u8, value: i32) void {
                    const s: *Input = @alignCast(@ptrCast(ptr));
                    s.injectKeyCode(code, value);
                }
            }.f),
        };
    }
};
