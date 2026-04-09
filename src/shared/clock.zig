const std = @import("std");

/// Runtime-polymorphic clock interface (fat pointer, like std.mem.Allocator).
/// Production code uses SystemClock; tests use StoppedClock for deterministic time.
pub const Clock = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        now_ns: *const fn (ptr: *anyopaque) u64,
    };

    /// Current time in nanoseconds (monotonic).
    pub fn nowNs(self: Clock) u64 {
        return self.vtable.now_ns(self.ptr);
    }
};

/// Real monotonic clock backed by std.time.nanoTimestamp.
pub const SystemClock = struct {
    /// Return a Clock interface backed by the system clock.
    /// SystemClock has no state, so we use a sentinel pointer.
    pub fn clock() Clock {
        return .{
            .ptr = @ptrFromInt(@intFromPtr(&vtable)), // stable non-null pointer
            .vtable = &vtable,
        };
    }

    const vtable = Clock.VTable{
        .now_ns = &nowNs,
    };

    fn nowNs(_: *anyopaque) u64 {
        return @intCast(@as(u128, @bitCast(std.time.nanoTimestamp())));
    }
};

/// Manually-controlled clock for deterministic tests.
/// Time only advances when you call `advance()`.
pub const StoppedClock = struct {
    current_ns: u64 = 0,

    pub fn clock(self: *StoppedClock) Clock {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    /// Advance the clock by the given number of nanoseconds.
    pub fn advance(self: *StoppedClock, ns: u64) void {
        self.current_ns += ns;
    }

    /// Set the clock to an absolute value.
    pub fn set(self: *StoppedClock, ns: u64) void {
        self.current_ns = ns;
    }

    const vtable = Clock.VTable{
        .now_ns = @ptrCast(&nowNs),
    };

    fn nowNs(self: *StoppedClock) u64 {
        return self.current_ns;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "SystemClock returns increasing time" {
    const c = SystemClock.clock();
    const t1 = c.nowNs();
    const t2 = c.nowNs();
    try std.testing.expect(t2 >= t1);
}

test "StoppedClock starts at zero" {
    var sc = StoppedClock{};
    const c = sc.clock();
    try std.testing.expectEqual(@as(u64, 0), c.nowNs());
}

test "StoppedClock advance" {
    var sc = StoppedClock{};
    const c = sc.clock();
    sc.advance(1000);
    try std.testing.expectEqual(@as(u64, 1000), c.nowNs());
    sc.advance(500);
    try std.testing.expectEqual(@as(u64, 1500), c.nowNs());
}

test "StoppedClock set" {
    var sc = StoppedClock{};
    const c = sc.clock();
    sc.set(42);
    try std.testing.expectEqual(@as(u64, 42), c.nowNs());
}
