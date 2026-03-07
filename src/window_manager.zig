const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.wm);

const x = @cImport({
    @cInclude("X11/Xlib.h");
});

/// Minimal window manager for headless app sharing.
///
/// Listens for X11 structure events on the root window (same mechanism as
/// a real WM) and translates between the app's window and the headless
/// display size. Responsibilities:
///
/// - Detect when the app maps its window → resize display to match
/// - Detect when the app resizes itself → resize display to match
/// - Accept external resize requests (from browser viewer) → resize both
///   the display and the app window
///
/// Does NOT provide decorations — the browser provides the chrome.
pub const WindowSize = struct { w: u32, h: u32 };

pub const WindowManager = struct {
    display: *x.Display,
    root: x.Window,
    app_window: x.Window,
    width: u32,
    height: u32,
    on_resize: ?*const fn (u32, u32) void,

    pub fn init(display_name: [*:0]const u8) !WindowManager {
        const dpy = x.XOpenDisplay(display_name) orelse {
            log.err("cannot open display {s}", .{display_name});
            return error.DisplayFailed;
        };

        const screen = x.DefaultScreen(dpy);
        const root = x.RootWindow(dpy, screen);

        // Listen for substructure events. We use NotifyMask only (not
        // RedirectMask) to coexist with picom compositor. RedirectMask
        // would conflict — only one client can have it per root window.
        _ = x.XSelectInput(dpy, root, x.SubstructureNotifyMask);
        _ = x.XFlush(dpy);

        log.info("window manager listening on {s}", .{display_name});

        return .{
            .display = dpy,
            .root = root,
            .app_window = 0,
            .width = 0,
            .height = 0,
            .on_resize = null,
        };
    }

    /// Wait for the app's first top-level window to appear.
    /// Blocks until a window is mapped or timeout (seconds).
    /// Returns the window's initial dimensions.
    pub fn waitForWindow(self: *WindowManager, timeout_s: u32) !WindowSize {
        const deadline = std.time.nanoTimestamp() + @as(i128, timeout_s) * std.time.ns_per_s;
        var ev: x.XEvent = undefined;

        while (std.time.nanoTimestamp() < deadline) {
            // Check for pending events
            if (x.XPending(self.display) > 0) {
                _ = x.XNextEvent(self.display, &ev);

                if (ev.type == x.MapNotify) {
                    const map: *x.XMapEvent = @ptrCast(&ev);
                    if (map.override_redirect != 0) continue;
                    return self.adoptWindow(map.window);
                }
            } else {
                // Fallback: scan for existing children (window may have
                // mapped before we started listening)
                if (self.scanForWindow()) |size| return size;
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
        }

        // Final scan before giving up
        if (self.scanForWindow()) |size| return size;
        return error.WindowTimeout;
    }

    fn adoptWindow(self: *WindowManager, window: x.Window) WindowSize {
        self.app_window = window;

        var attrs: x.XWindowAttributes = undefined;
        _ = x.XGetWindowAttributes(self.display, window, &attrs);

        self.width = @intCast(attrs.width);
        self.height = @intCast(attrs.height);

        log.info("app window 0x{x}: {d}x{d}", .{
            self.app_window, self.width, self.height,
        });

        return .{ .w = self.width, .h = self.height };
    }

    fn scanForWindow(self: *WindowManager) ?WindowSize {
        var root_return: x.Window = undefined;
        var parent_return: x.Window = undefined;
        var children: [*c]x.Window = undefined;
        var nchildren: c_uint = 0;

        if (x.XQueryTree(self.display, self.root, &root_return, &parent_return, &children, &nchildren) == 0) {
            return null;
        }
        defer if (nchildren > 0) {
            _ = x.XFree(children);
        };

        for (0..nchildren) |i| {
            var attrs: x.XWindowAttributes = undefined;
            if (x.XGetWindowAttributes(self.display, children[i], &attrs) == 0) continue;
            // Skip unmapped, override-redirect, or tiny windows
            if (attrs.map_state != x.IsViewable) continue;
            if (attrs.override_redirect != 0) continue;
            if (attrs.width < 10 or attrs.height < 10) continue;

            return self.adoptWindow(children[i]);
        }
        return null;
    }

    /// Process pending X11 events. Call this periodically from the
    /// capture loop (non-blocking).
    pub fn processEvents(self: *WindowManager) void {
        var ev: x.XEvent = undefined;

        while (x.XPending(self.display) > 0) {
            _ = x.XNextEvent(self.display, &ev);

            switch (ev.type) {
                x.ConfigureNotify => {
                    const cfg: *x.XConfigureEvent = @ptrCast(&ev);
                    if (cfg.window == self.app_window) {
                        const w: u32 = @intCast(cfg.width);
                        const h: u32 = @intCast(cfg.height);
                        if (w != self.width or h != self.height) {
                            self.width = w;
                            self.height = h;
                            log.info("app resized: {d}x{d}", .{ w, h });
                            if (self.on_resize) |cb| cb(w, h);
                        }
                    }
                },
                x.MapNotify => {
                    const map: *x.XMapEvent = @ptrCast(&ev);
                    if (map.override_redirect != 0) continue;
                    // If we don't have an app window yet, adopt this one
                    if (self.app_window == 0) {
                        self.app_window = map.window;
                        var attrs: x.XWindowAttributes = undefined;
                        _ = x.XGetWindowAttributes(self.display, self.app_window, &attrs);
                        self.width = @intCast(attrs.width);
                        self.height = @intCast(attrs.height);
                        log.info("adopted window 0x{x}: {d}x{d}", .{
                            self.app_window, self.width, self.height,
                        });
                        if (self.on_resize) |cb| cb(self.width, self.height);
                    }
                },
                else => {},
            }
        }
    }

    /// Resize the app window (called when browser viewer resizes).
    /// The app receives a ConfigureNotify and redraws at the new size.
    pub fn resizeApp(self: *WindowManager, width: u32, height: u32) void {
        if (self.app_window == 0) return;

        _ = x.XMoveResizeWindow(
            self.display,
            self.app_window,
            0, 0,
            @intCast(width),
            @intCast(height),
        );
        _ = x.XFlush(self.display);

        self.width = width;
        self.height = height;
        log.info("resized app to {d}x{d}", .{ width, height });
    }

    pub fn deinit(self: *WindowManager) void {
        _ = x.XCloseDisplay(self.display);
    }
};
