const std = @import("std");
const nvfbc = @import("nvfbc");
const Box = nvfbc.Box;

const x = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
});
const cairo = @cImport({
    @cInclude("cairo/cairo.h");
    @cInclude("cairo/cairo-xlib.h");
});

// SHAPE extension constants (from X11/extensions/shape.h)
const ShapeInput: c_int = 2;
const ShapeSet: c_int = 0;
const Unsorted: c_int = 0;

const XRectangle = extern struct {
    rx: c_short = 0,
    ry: c_short = 0,
    width: c_ushort = 0,
    height: c_ushort = 0,
};

const XShapeCombineRectanglesFn = *const fn (
    ?*x.Display,
    x.Window,
    c_int,
    c_int,
    c_int,
    [*]const XRectangle,
    c_int,
    c_int,
    c_int,
) callconv(.c) void;

/// X11 overlay with Cairo rendering. Draws corner brackets, viewer cursors,
/// and drawing annotations. Click-through, always-on-top, transparent background.
pub const Overlay = struct {
    display: *x.Display,
    window: x.Window,
    colormap: x.Colormap,
    surface: *cairo.cairo_surface_t,
    width: u32,
    height: u32,

    const bracket_len = 40;
    const bracket_width = 3.0;

    pub fn init(box: Box) !Overlay {
        const dpy = x.XOpenDisplay(null) orelse return error.OverlayFailed;
        errdefer _ = x.XCloseDisplay(dpy);

        const screen = x.DefaultScreen(dpy);
        const root = x.RootWindow(dpy, screen);

        var vinfo: x.XVisualInfo = undefined;
        if (x.XMatchVisualInfo(dpy, screen, 32, x.TrueColor, &vinfo) == 0) {
            return error.OverlayFailed;
        }

        const colormap = x.XCreateColormap(dpy, root, vinfo.visual, x.AllocNone);

        var attrs: x.XSetWindowAttributes = std.mem.zeroes(x.XSetWindowAttributes);
        attrs.colormap = colormap;
        attrs.background_pixel = 0;
        attrs.border_pixel = 0;
        attrs.override_redirect = 1;

        const win = x.XCreateWindow(
            dpy,
            root,
            @intCast(box.x),
            @intCast(box.y),
            box.w,
            box.h,
            0,
            vinfo.depth,
            x.InputOutput,
            vinfo.visual,
            x.CWColormap | x.CWBackPixel | x.CWBorderPixel | x.CWOverrideRedirect,
            &attrs,
        );
        if (win == 0) return error.OverlayFailed;
        errdefer _ = x.XDestroyWindow(dpy, win);

        // Click-through via SHAPE extension
        if (std.c.dlopen("libXext.so.6", .{ .LAZY = true })) |lib| {
            if (std.c.dlsym(lib, "XShapeCombineRectangles")) |sym| {
                const shapeFn: XShapeCombineRectanglesFn = @ptrCast(sym);
                const empty = [0]XRectangle{};
                shapeFn(dpy, win, ShapeInput, 0, 0, &empty, 0, ShapeSet, Unsorted);
            }
        }

        // Create Cairo surface backed by the X11 window
        const surface = cairo.cairo_xlib_surface_create(
            @ptrCast(dpy),
            @intCast(win),
            @ptrCast(vinfo.visual),
            @intCast(box.w),
            @intCast(box.h),
        ) orelse return error.OverlayFailed;
        errdefer cairo.cairo_surface_destroy(surface);

        _ = x.XMapRaised(dpy, win);

        // Initial bracket draw
        var self = Overlay{
            .display = dpy,
            .window = win,
            .colormap = colormap,
            .surface = surface,
            .width = box.w,
            .height = box.h,
        };
        self.drawBrackets();
        _ = x.XFlush(dpy);

        std.debug.print("Overlay: sharing indicator visible ({}x{}+{}+{})\n", .{ box.w, box.h, box.x, box.y });

        return self;
    }

    /// Redraw brackets only. Cursor and draw-path rendering has moved to
    /// browser-side SVG overlay (see worker/src/overlay.ts).
    pub fn redraw(self: *Overlay) void {
        const cr = cairo.cairo_create(self.surface) orelse return;
        defer cairo.cairo_destroy(cr);

        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_CLEAR);
        cairo.cairo_paint(cr);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);

        self.drawBracketsOn(cr);

        cairo.cairo_surface_flush(self.surface);
        _ = x.XFlush(self.display);
    }

    fn drawBrackets(self: *Overlay) void {
        const cr = cairo.cairo_create(self.surface) orelse return;
        defer cairo.cairo_destroy(cr);

        // Clear first
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_CLEAR);
        cairo.cairo_paint(cr);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);

        self.drawBracketsOn(cr);
        cairo.cairo_surface_flush(self.surface);
    }

    fn drawBracketsOn(self: *const Overlay, cr: *cairo.cairo_t) void {
        const w: f64 = @floatFromInt(self.width);
        const h: f64 = @floatFromInt(self.height);
        const blen: f64 = bracket_len;
        const half: f64 = bracket_width / 2.0;

        cairo.cairo_set_source_rgba(cr, 0.0, 0.8, 0.0, 1.0); // bright green
        cairo.cairo_set_line_width(cr, bracket_width);
        cairo.cairo_set_line_cap(cr, cairo.CAIRO_LINE_CAP_SQUARE);

        // Top-left
        cairo.cairo_move_to(cr, half, blen);
        cairo.cairo_line_to(cr, half, half);
        cairo.cairo_line_to(cr, blen, half);
        cairo.cairo_stroke(cr);

        // Top-right
        cairo.cairo_move_to(cr, w - blen, half);
        cairo.cairo_line_to(cr, w - half, half);
        cairo.cairo_line_to(cr, w - half, blen);
        cairo.cairo_stroke(cr);

        // Bottom-left
        cairo.cairo_move_to(cr, half, h - blen);
        cairo.cairo_line_to(cr, half, h - half);
        cairo.cairo_line_to(cr, blen, h - half);
        cairo.cairo_stroke(cr);

        // Bottom-right
        cairo.cairo_move_to(cr, w - blen, h - half);
        cairo.cairo_line_to(cr, w - half, h - half);
        cairo.cairo_line_to(cr, w - half, h - blen);
        cairo.cairo_stroke(cr);
    }

    pub fn deinit(self: *Overlay) void {
        cairo.cairo_surface_destroy(self.surface);
        _ = x.XDestroyWindow(self.display, self.window);
        _ = x.XFreeColormap(self.display, self.colormap);
        _ = x.XCloseDisplay(self.display);
    }
};
