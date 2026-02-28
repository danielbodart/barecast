const std = @import("std");
const nvfbc = @import("nvfbc");
const Box = nvfbc.Box;
const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
});

// SHAPE extension constants (from X11/extensions/shape.h)
const ShapeInput: c_int = 2;
const ShapeSet: c_int = 0;
const Unsorted: c_int = 0;

// XShapeCombineRectangles function pointer type (matches C signature exactly)
const XRectangle = extern struct {
    x: c_short = 0,
    y: c_short = 0,
    width: c_ushort = 0,
    height: c_ushort = 0,
};

const XShapeCombineRectanglesFn = *const fn (
    ?*c.Display,
    c.Window,
    c_int, // dest_kind
    c_int, // x_off
    c_int, // y_off
    [*]const XRectangle, // rectangles
    c_int, // n_rects
    c_int, // op
    c_int, // ordering
) callconv(.c) void;

/// X11 overlay that draws bright green L-brackets at the corners of the
/// shared region. Click-through, always-on-top, transparent background.
/// Uses the X SHAPE extension (dlopen'd) for input passthrough.
pub const Overlay = struct {
    display: *c.Display,
    window: c.Window,
    colormap: c.Colormap,
    gc: c.GC,

    const bracket_len = 40; // arm length in pixels
    const bracket_width = 3; // line thickness
    const green = 0xFF00CC00; // bright green, fully opaque ARGB

    /// Create the overlay window on a fresh X11 connection (separate from
    /// the GLX context used by NvFBC to avoid Xlib threading issues).
    pub fn init(box: Box) !Overlay {
        const dpy = c.XOpenDisplay(null) orelse return error.OverlayFailed;
        errdefer _ = c.XCloseDisplay(dpy);

        const screen = c.DefaultScreen(dpy);
        const root = c.RootWindow(dpy, screen);

        // Find a 32-bit ARGB visual for transparency
        var vinfo: c.XVisualInfo = undefined;
        if (c.XMatchVisualInfo(dpy, screen, 32, c.TrueColor, &vinfo) == 0) {
            return error.OverlayFailed;
        }

        const colormap = c.XCreateColormap(dpy, root, vinfo.visual, c.AllocNone);

        var attrs: c.XSetWindowAttributes = std.mem.zeroes(c.XSetWindowAttributes);
        attrs.colormap = colormap;
        attrs.background_pixel = 0; // transparent
        attrs.border_pixel = 0;
        attrs.override_redirect = 1; // bypass window manager — appears at top of stack

        const win = c.XCreateWindow(
            dpy,
            root,
            @intCast(box.x),
            @intCast(box.y),
            box.w,
            box.h,
            0,
            vinfo.depth,
            c.InputOutput,
            vinfo.visual,
            c.CWColormap | c.CWBackPixel | c.CWBorderPixel | c.CWOverrideRedirect,
            &attrs,
        );
        if (win == 0) return error.OverlayFailed;
        errdefer _ = c.XDestroyWindow(dpy, win);

        // Make click-through via SHAPE extension: set empty input region.
        // dlopen libXext at runtime — avoids build-time dev package dependency.
        if (std.c.dlopen("libXext.so.6", .{ .LAZY = true })) |lib| {
            if (std.c.dlsym(lib, "XShapeCombineRectangles")) |sym| {
                const shapeFn: XShapeCombineRectanglesFn = @ptrCast(sym);
                const empty = [0]XRectangle{};
                shapeFn(dpy, win, ShapeInput, 0, 0, &empty, 0, ShapeSet, Unsorted);
            }
            // Don't close lib — libXext may be used by Xlib for the connection lifetime
        }

        // Create GC for drawing
        var gc_values: c.XGCValues = std.mem.zeroes(c.XGCValues);
        gc_values.foreground = green;
        gc_values.line_width = bracket_width;
        const gc = c.XCreateGC(dpy, win, c.GCForeground | c.GCLineWidth, &gc_values);

        // Show the window (XMapRaised places it at the top of the stack)
        _ = c.XMapRaised(dpy, win);

        // Draw the brackets
        drawBrackets(dpy, win, gc, box.w, box.h);

        _ = c.XFlush(dpy);

        std.debug.print("Overlay: sharing indicator visible ({}x{}+{}+{})\n", .{ box.w, box.h, box.x, box.y });

        return .{
            .display = dpy,
            .window = win,
            .colormap = colormap,
            .gc = gc,
        };
    }

    fn drawBrackets(dpy: *c.Display, win: c.Window, gc: c.GC, w: u32, h: u32) void {
        const bw: c_int = bracket_width;
        const half_bw: c_int = @divFloor(bw, 2);
        const blen: c_int = bracket_len;
        const wi: c_int = @intCast(w);
        const hi: c_int = @intCast(h);

        // Top-left corner
        _ = c.XDrawLine(dpy, win, gc, half_bw, half_bw, blen, half_bw); // horizontal
        _ = c.XDrawLine(dpy, win, gc, half_bw, half_bw, half_bw, blen); // vertical

        // Top-right corner
        _ = c.XDrawLine(dpy, win, gc, wi - blen, half_bw, wi - 1 - half_bw, half_bw);
        _ = c.XDrawLine(dpy, win, gc, wi - 1 - half_bw, half_bw, wi - 1 - half_bw, blen);

        // Bottom-left corner
        _ = c.XDrawLine(dpy, win, gc, half_bw, hi - blen, half_bw, hi - 1 - half_bw);
        _ = c.XDrawLine(dpy, win, gc, half_bw, hi - 1 - half_bw, blen, hi - 1 - half_bw);

        // Bottom-right corner
        _ = c.XDrawLine(dpy, win, gc, wi - blen, hi - 1 - half_bw, wi - 1 - half_bw, hi - 1 - half_bw);
        _ = c.XDrawLine(dpy, win, gc, wi - 1 - half_bw, hi - blen, wi - 1 - half_bw, hi - 1 - half_bw);
    }

    pub fn deinit(self: *Overlay) void {
        _ = c.XFreeGC(self.display, self.gc);
        _ = c.XDestroyWindow(self.display, self.window);
        _ = c.XFreeColormap(self.display, self.colormap);
        _ = c.XCloseDisplay(self.display);
    }
};
