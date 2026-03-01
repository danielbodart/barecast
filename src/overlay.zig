const std = @import("std");
const nvfbc = @import("nvfbc");
const Box = nvfbc.Box;
const viewer_state = @import("viewer_state");
const ViewerRegistry = viewer_state.ViewerRegistry;
const Color = viewer_state.Color;
const Point = viewer_state.Point;

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
    const cursor_size = 24.0;
    const draw_line_width = 2.5;

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

    /// Full redraw: clear → brackets → per-viewer paths → per-viewer cursors.
    pub fn redraw(self: *Overlay, registry: *ViewerRegistry) void {
        const cr = cairo.cairo_create(self.surface) orelse return;
        defer cairo.cairo_destroy(cr);

        // Clear to transparent
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_CLEAR);
        cairo.cairo_paint(cr);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);

        // Brackets
        self.drawBracketsOn(cr);

        // Viewer content — lock registry for snapshot
        registry.mutex.lock();
        defer registry.mutex.unlock();

        for (&registry.viewers) |*viewer| {
            if (!viewer.active) continue;
            const col = viewer.color();

            // Drawing paths
            self.drawViewerPaths(cr, viewer, col);

            // Cursor
            self.drawCursor(cr, viewer.cursor_x, viewer.cursor_y, col);
        }

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

    fn drawViewerPaths(self: *const Overlay, cr: *cairo.cairo_t, viewer: *const viewer_state.Viewer, col: Color) void {
        _ = self;
        cairo.cairo_set_source_rgba(cr, col.r, col.g, col.b, 0.8);
        cairo.cairo_set_line_width(cr, draw_line_width);
        cairo.cairo_set_line_cap(cr, cairo.CAIRO_LINE_CAP_ROUND);
        cairo.cairo_set_line_join(cr, cairo.CAIRO_LINE_JOIN_ROUND);

        // Completed paths
        for (viewer.completedPaths()) |path| {
            drawPath(cr, path.slice());
        }

        // Current in-progress path
        if (viewer.current_path) |path| {
            drawPath(cr, path.slice());
        }
    }

    fn drawPath(cr: *cairo.cairo_t, points: []const Point) void {
        if (points.len < 2) return;
        cairo.cairo_move_to(cr, @floatFromInt(points[0].x), @floatFromInt(points[0].y));
        for (points[1..]) |pt| {
            cairo.cairo_line_to(cr, @floatFromInt(pt.x), @floatFromInt(pt.y));
        }
        cairo.cairo_stroke(cr);
    }

    fn drawCursor(_: *const Overlay, cr: *cairo.cairo_t, cx: u16, cy: u16, col: Color) void {
        const fx: f64 = @floatFromInt(cx);
        const fy: f64 = @floatFromInt(cy);
        const s = cursor_size;

        // Arrow cursor shape: tip at (fx, fy), Bibata-inspired
        // Black fill with viewer color tint, white outline

        // Define arrow path
        cairo.cairo_new_path(cr);
        cairo.cairo_move_to(cr, fx, fy); // tip
        cairo.cairo_line_to(cr, fx, fy + s * 0.95);
        cairo.cairo_line_to(cr, fx + s * 0.28, fy + s * 0.72);
        cairo.cairo_line_to(cr, fx + s * 0.65, fy + s * 0.72);
        cairo.cairo_close_path(cr);

        // White outline
        cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 1.0);
        cairo.cairo_set_line_width(cr, 2.0);
        cairo.cairo_stroke_preserve(cr);

        // Colored fill (viewer's color, slightly darkened)
        cairo.cairo_set_source_rgba(cr, col.r * 0.8, col.g * 0.8, col.b * 0.8, 0.95);
        cairo.cairo_fill(cr);
    }

    pub fn deinit(self: *Overlay) void {
        cairo.cairo_surface_destroy(self.surface);
        _ = x.XDestroyWindow(self.display, self.window);
        _ = x.XFreeColormap(self.display, self.colormap);
        _ = x.XCloseDisplay(self.display);
    }
};
