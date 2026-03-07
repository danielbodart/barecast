const std = @import("std");
const keymap = @import("keymap");

const log = std.log.scoped(.xtest);

const x = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/extensions/XTest.h");
    @cInclude("X11/keysym.h");
});

/// Input injection via XTEST extension on a specific X11 display.
/// Used for app sharing where input targets the headless Xorg display.
/// On modern X.org with evdev, X11 keycode = evdev keycode + 8.
pub const XTestInput = struct {
    display: *x.Display,
    screen_width: u32,
    screen_height: u32,

    const evdev_offset: u32 = 8;

    pub fn init(display_name: [*:0]const u8, width: u32, height: u32) !XTestInput {
        const dpy = x.XOpenDisplay(display_name) orelse {
            log.err("cannot open display {s}", .{display_name});
            return error.DisplayFailed;
        };

        // Verify XTEST extension is available
        var event_base: c_int = 0;
        var error_base: c_int = 0;
        var major: c_int = 0;
        var minor: c_int = 0;
        if (x.XTestQueryExtension(dpy, &event_base, &error_base, &major, &minor) == 0) {
            log.err("XTEST extension not available", .{});
            _ = x.XCloseDisplay(dpy);
            return error.XTestUnavailable;
        }

        log.info("XTEST input: display {s} ({d}x{d}), XTEST v{d}.{d}", .{
            display_name, width, height, major, minor,
        });

        return .{
            .display = dpy,
            .screen_width = width,
            .screen_height = height,
        };
    }

    pub fn deinit(self: *XTestInput) void {
        _ = x.XCloseDisplay(self.display);
    }

    /// Move the pointer to absolute coordinates.
    pub fn moveMouse(self: *XTestInput, abs_x: u16, abs_y: u16) void {
        _ = x.XTestFakeMotionEvent(
            self.display,
            0, // screen number
            @intCast(abs_x),
            @intCast(abs_y),
            0, // delay (0 = immediate)
        );
        _ = x.XFlush(self.display);
    }

    /// Inject a mouse button press (value=1) or release (value=0).
    /// button: 0=left, 1=right, 2=middle (matches input_protocol.MouseButton)
    pub fn injectMouseButton(self: *XTestInput, button: u8, value: i32) void {
        // X11 buttons: 1=left, 2=middle, 3=right
        const x_button: c_uint = switch (button) {
            0 => 1, // left
            1 => 3, // right
            2 => 2, // middle
            else => return,
        };
        _ = x.XTestFakeButtonEvent(
            self.display,
            x_button,
            if (value != 0) 1 else 0, // is_press
            0,
        );
        _ = x.XFlush(self.display);
    }

    /// Inject scroll events. X11 uses button 4 (up) and 5 (down).
    pub fn injectScroll(self: *XTestInput, delta: i16) void {
        const button: c_uint = if (delta > 0) 4 else 5; // 4=up, 5=down
        const clicks = @abs(delta) / 120;
        for (0..if (clicks == 0) 1 else clicks) |_| {
            _ = x.XTestFakeButtonEvent(self.display, button, 1, 0); // press
            _ = x.XTestFakeButtonEvent(self.display, button, 0, 0); // release
        }
        _ = x.XFlush(self.display);
    }

    /// Inject a key press (value=1) or release (value=0).
    /// code: KeyboardEvent.code string (e.g. "KeyA", "Space")
    pub fn injectKeyCode(self: *XTestInput, code: []const u8, value: i32) void {
        // Reuse the evdev keymap, then add the X11 offset
        const evdev_code = keymap.codeToLinux(code) orelse {
            log.debug("unmapped key: {s}", .{code});
            return;
        };
        const x_keycode: c_uint = @intCast(evdev_code + evdev_offset);

        _ = x.XTestFakeKeyEvent(
            self.display,
            x_keycode,
            if (value != 0) 1 else 0, // is_press
            0,
        );
        _ = x.XFlush(self.display);
    }

    /// Return an InputHandler interface compatible with session.zig.
    pub fn inputHandler(self: *XTestInput) InputHandler {
        return .{
            .ptr = @ptrCast(self),
            .moveFn = @ptrCast(&struct {
                fn f(ptr: *anyopaque, abs_x: u16, abs_y: u16) void {
                    const s: *XTestInput = @alignCast(@ptrCast(ptr));
                    s.moveMouse(abs_x, abs_y);
                }
            }.f),
            .mouseButtonFn = @ptrCast(&struct {
                fn f(ptr: *anyopaque, button: u8, value: i32) void {
                    const s: *XTestInput = @alignCast(@ptrCast(ptr));
                    s.injectMouseButton(button, value);
                }
            }.f),
            .scrollFn = @ptrCast(&struct {
                fn f(ptr: *anyopaque, delta: i16) void {
                    const s: *XTestInput = @alignCast(@ptrCast(ptr));
                    s.injectScroll(delta);
                }
            }.f),
            .keyCodeFn = @ptrCast(&struct {
                fn f(ptr: *anyopaque, code: []const u8, value: i32) void {
                    const s: *XTestInput = @alignCast(@ptrCast(ptr));
                    s.injectKeyCode(code, value);
                }
            }.f),
        };
    }

    const InputHandler = @import("session").InputHandler;
};
