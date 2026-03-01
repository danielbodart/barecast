const std = @import("std");

const log = std.log.scoped(.viewer_state);

pub const MAX_VIEWERS: usize = 8;
pub const MAX_PATHS_PER_VIEWER: usize = 64;
pub const MAX_POINTS_PER_PATH: usize = 512;
pub const PEER_ID_LEN: usize = 16;

/// Viewer colors — distinct, high-contrast on dark backgrounds.
/// Index 0 = first viewer, wraps around.
pub const viewer_colors = [_]Color{
    .{ .r = 0.30, .g = 0.69, .b = 1.00 }, // blue
    .{ .r = 1.00, .g = 0.40, .b = 0.40 }, // red
    .{ .r = 0.40, .g = 0.87, .b = 0.40 }, // green
    .{ .r = 1.00, .g = 0.75, .b = 0.20 }, // yellow
    .{ .r = 0.80, .g = 0.45, .b = 1.00 }, // purple
    .{ .r = 1.00, .g = 0.55, .b = 0.20 }, // orange
    .{ .r = 0.40, .g = 0.90, .b = 0.85 }, // cyan
    .{ .r = 1.00, .g = 0.50, .b = 0.70 }, // pink
};

/// CSS hex colors matching viewer_colors (for browser toolbar).
pub const viewer_color_hex = [_][]const u8{
    "#4DB0FF", // blue
    "#FF6666", // red
    "#66DE66", // green
    "#FFBF33", // yellow
    "#CC73FF", // purple
    "#FF8C33", // orange
    "#66E6D9", // cyan
    "#FF80B3", // pink
};

pub const Color = struct {
    r: f64,
    g: f64,
    b: f64,
};

pub const Point = struct {
    x: u16,
    y: u16,
};

pub const Path = struct {
    points: [MAX_POINTS_PER_PATH]Point,
    len: u16,

    pub fn init() Path {
        return .{
            .points = undefined,
            .len = 0,
        };
    }

    pub fn addPoint(self: *Path, x: u16, y: u16) void {
        if (self.len < MAX_POINTS_PER_PATH) {
            self.points[self.len] = .{ .x = x, .y = y };
            self.len += 1;
        }
    }

    pub fn slice(self: *const Path) []const Point {
        return self.points[0..self.len];
    }
};

pub const ViewerMode = enum(u8) {
    draw,
    input,
};

pub const Viewer = struct {
    active: bool,
    peer_id: [PEER_ID_LEN]u8,
    color_index: u8,
    mode: ViewerMode,
    cursor_x: u16,
    cursor_y: u16,
    /// Completed drawing paths
    paths: [MAX_PATHS_PER_VIEWER]Path,
    path_count: u16,
    /// Currently active drawing path (while dragging)
    current_path: ?Path,

    pub fn init(peer_id: [PEER_ID_LEN]u8, color_index: u8) Viewer {
        return .{
            .active = true,
            .peer_id = peer_id,
            .color_index = color_index,
            .mode = .draw,
            .cursor_x = 0,
            .cursor_y = 0,
            .paths = undefined,
            .path_count = 0,
            .current_path = null,
        };
    }

    pub fn color(self: *const Viewer) Color {
        return viewer_colors[self.color_index % viewer_colors.len];
    }

    pub fn startPath(self: *Viewer, x: u16, y: u16) void {
        var path = Path.init();
        path.addPoint(x, y);
        self.current_path = path;
    }

    pub fn extendPath(self: *Viewer, x: u16, y: u16) void {
        if (self.current_path) |*path| {
            path.addPoint(x, y);
        }
    }

    pub fn endPath(self: *Viewer) void {
        if (self.current_path) |path| {
            if (path.len > 1 and self.path_count < MAX_PATHS_PER_VIEWER) {
                self.paths[self.path_count] = path;
                self.path_count += 1;
            }
            self.current_path = null;
        }
    }

    pub fn undoPath(self: *Viewer) void {
        if (self.path_count > 0) {
            self.path_count -= 1;
        }
    }

    pub fn clearPaths(self: *Viewer) void {
        self.path_count = 0;
        self.current_path = null;
    }

    pub fn completedPaths(self: *const Viewer) []const Path {
        return self.paths[0..self.path_count];
    }
};

/// Thread-safe registry of active viewers. Shared between data channel
/// callbacks (libdatachannel threads) and the overlay redraw (main thread).
pub const ViewerRegistry = struct {
    viewers: [MAX_VIEWERS]Viewer,
    mutex: std.Thread.Mutex,
    next_color: u8,

    pub fn init() ViewerRegistry {
        var reg: ViewerRegistry = undefined;
        reg.mutex = .{};
        reg.next_color = 0;
        for (&reg.viewers) |*v| {
            v.active = false;
        }
        return reg;
    }

    /// Register a new viewer. Returns the assigned color index, or null if full.
    pub fn addViewer(self: *ViewerRegistry, peer_id: [PEER_ID_LEN]u8) ?u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (&self.viewers) |*v| {
            if (!v.active) {
                const color_index = self.next_color;
                self.next_color +%= 1;
                v.* = Viewer.init(peer_id, color_index);
                return color_index;
            }
        }
        return null;
    }

    /// Remove a viewer by peer ID.
    pub fn removeViewer(self: *ViewerRegistry, peer_id: *const [PEER_ID_LEN]u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (&self.viewers) |*v| {
            if (v.active and std.mem.eql(u8, &v.peer_id, peer_id)) {
                v.active = false;
                return;
            }
        }
    }

    /// Find a viewer by peer ID. Returns pointer valid while lock is held.
    /// Caller must NOT hold the mutex — this locks internally.
    fn findViewerLocked(self: *ViewerRegistry, peer_id: *const [PEER_ID_LEN]u8) ?*Viewer {
        for (&self.viewers) |*v| {
            if (v.active and std.mem.eql(u8, &v.peer_id, peer_id)) {
                return v;
            }
        }
        return null;
    }

    /// Update cursor position for a viewer.
    pub fn updateCursor(self: *ViewerRegistry, peer_id: *const [PEER_ID_LEN]u8, x: u16, y: u16) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.findViewerLocked(peer_id)) |v| {
            v.cursor_x = x;
            v.cursor_y = y;
        }
    }

    /// Start a drawing path.
    pub fn drawStart(self: *ViewerRegistry, peer_id: *const [PEER_ID_LEN]u8, x: u16, y: u16) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.findViewerLocked(peer_id)) |v| {
            v.startPath(x, y);
        }
    }

    /// Extend current drawing path.
    pub fn drawMove(self: *ViewerRegistry, peer_id: *const [PEER_ID_LEN]u8, x: u16, y: u16) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.findViewerLocked(peer_id)) |v| {
            v.extendPath(x, y);
        }
    }

    /// End current drawing path.
    pub fn drawEnd(self: *ViewerRegistry, peer_id: *const [PEER_ID_LEN]u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.findViewerLocked(peer_id)) |v| {
            v.endPath();
        }
    }

    /// Undo last completed path.
    pub fn drawUndo(self: *ViewerRegistry, peer_id: *const [PEER_ID_LEN]u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.findViewerLocked(peer_id)) |v| {
            v.undoPath();
        }
    }

    /// Clear all paths for a viewer.
    pub fn drawClear(self: *ViewerRegistry, peer_id: *const [PEER_ID_LEN]u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.findViewerLocked(peer_id)) |v| {
            v.clearPaths();
        }
    }

    /// Check if any viewer has active content (cursors or drawings).
    pub fn hasActiveContent(self: *ViewerRegistry) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.viewers) |*v| {
            if (v.active) return true;
        }
        return false;
    }

    /// Get count of active viewers (for testing).
    pub fn activeCount(self: *ViewerRegistry) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: usize = 0;
        for (&self.viewers) |*v| {
            if (v.active) count += 1;
        }
        return count;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

fn testPeerId(comptime s: *const [PEER_ID_LEN]u8) [PEER_ID_LEN]u8 {
    return s.*;
}

test "ViewerRegistry add and remove" {
    var reg = ViewerRegistry.init();
    const id1 = testPeerId("aaaa1111bbbb2222");
    const id2 = testPeerId("cccc3333dddd4444");

    const c1 = reg.addViewer(id1);
    try std.testing.expect(c1 != null);
    try std.testing.expectEqual(reg.activeCount(), 1);

    const c2 = reg.addViewer(id2);
    try std.testing.expect(c2 != null);
    try std.testing.expectEqual(reg.activeCount(), 2);

    // Colors should be different
    try std.testing.expect(c1.? != c2.?);

    reg.removeViewer(&id1);
    try std.testing.expectEqual(reg.activeCount(), 1);

    reg.removeViewer(&id2);
    try std.testing.expectEqual(reg.activeCount(), 0);
}

test "ViewerRegistry reuses slots" {
    var reg = ViewerRegistry.init();
    const id1 = testPeerId("aaaa1111bbbb2222");
    const id2 = testPeerId("cccc3333dddd4444");

    _ = reg.addViewer(id1);
    reg.removeViewer(&id1);
    _ = reg.addViewer(id2);
    try std.testing.expectEqual(reg.activeCount(), 1);
}

test "ViewerRegistry full returns null" {
    var reg = ViewerRegistry.init();
    for (0..MAX_VIEWERS) |i| {
        var id: [PEER_ID_LEN]u8 = undefined;
        @memset(&id, @intCast(i + 'A'));
        try std.testing.expect(reg.addViewer(id) != null);
    }
    try std.testing.expect(reg.addViewer(testPeerId("overflow00000000")) == null);
}

test "ViewerRegistry cursor update" {
    var reg = ViewerRegistry.init();
    const id = testPeerId("aaaa1111bbbb2222");
    _ = reg.addViewer(id);

    reg.updateCursor(&id, 100, 200);

    reg.mutex.lock();
    defer reg.mutex.unlock();
    const v = reg.findViewerLocked(&id).?;
    try std.testing.expectEqual(v.cursor_x, 100);
    try std.testing.expectEqual(v.cursor_y, 200);
}

test "ViewerRegistry draw path lifecycle" {
    var reg = ViewerRegistry.init();
    const id = testPeerId("aaaa1111bbbb2222");
    _ = reg.addViewer(id);

    // Start → move → move → end
    reg.drawStart(&id, 10, 20);
    reg.drawMove(&id, 30, 40);
    reg.drawMove(&id, 50, 60);
    reg.drawEnd(&id);

    reg.mutex.lock();
    const v = reg.findViewerLocked(&id).?;
    try std.testing.expectEqual(v.path_count, 1);
    const path = v.completedPaths()[0];
    try std.testing.expectEqual(path.len, 3);
    try std.testing.expectEqual(path.points[0].x, 10);
    try std.testing.expectEqual(path.points[2].x, 50);
    reg.mutex.unlock();

    // Undo
    reg.drawUndo(&id);
    reg.mutex.lock();
    const v2 = reg.findViewerLocked(&id).?;
    try std.testing.expectEqual(v2.path_count, 0);
    reg.mutex.unlock();
}

test "ViewerRegistry draw clear" {
    var reg = ViewerRegistry.init();
    const id = testPeerId("aaaa1111bbbb2222");
    _ = reg.addViewer(id);

    // Two paths
    reg.drawStart(&id, 0, 0);
    reg.drawMove(&id, 10, 10);
    reg.drawEnd(&id);
    reg.drawStart(&id, 20, 20);
    reg.drawMove(&id, 30, 30);
    reg.drawEnd(&id);

    reg.drawClear(&id);

    reg.mutex.lock();
    const v = reg.findViewerLocked(&id).?;
    try std.testing.expectEqual(v.path_count, 0);
    reg.mutex.unlock();
}

test "ViewerRegistry hasActiveContent" {
    var reg = ViewerRegistry.init();
    try std.testing.expect(!reg.hasActiveContent());

    const id = testPeerId("aaaa1111bbbb2222");
    _ = reg.addViewer(id);
    try std.testing.expect(reg.hasActiveContent());

    reg.removeViewer(&id);
    try std.testing.expect(!reg.hasActiveContent());
}

test "Viewer color wraps" {
    const id = testPeerId("aaaa1111bbbb2222");
    const v = Viewer.init(id, 255);
    const c = v.color();
    // Should not crash — wraps via modulo
    try std.testing.expect(c.r >= 0.0 and c.r <= 1.0);
}

test "Path single point not saved" {
    var v = Viewer.init(testPeerId("aaaa1111bbbb2222"), 0);
    v.startPath(10, 20);
    v.endPath();
    // Single-point paths are discarded
    try std.testing.expectEqual(v.path_count, 0);
}

test "Path addPoint capped at MAX_POINTS_PER_PATH" {
    var path = Path.init();
    for (0..MAX_POINTS_PER_PATH + 10) |i| {
        path.addPoint(@intCast(i % 65535), 0);
    }
    try std.testing.expectEqual(path.len, MAX_POINTS_PER_PATH);
}
