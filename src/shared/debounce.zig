const std = @import("std");
const Clock = @import("clock").Clock;

/// Generic debounce wrapper. Delays invocation of a callback until
/// `delay_ns` nanoseconds have passed with no new calls. Each call
/// to `trigger` resets the timer. The caller must periodically call
/// `tick` to check if the deadline has passed and fire the callback.
pub fn Debounce(comptime Args: type) type {
    return struct {
        const Self = @This();

        callback: *const fn (Args, ?*anyopaque) void,
        ctx: ?*anyopaque,
        clock: Clock,
        delay_ns: u64,
        pending_args: ?Args = null,
        deadline: u64 = 0,

        pub fn init(
            callback: *const fn (Args, ?*anyopaque) void,
            ctx: ?*anyopaque,
            clock: Clock,
            delay_ns: u64,
        ) Self {
            return .{
                .callback = callback,
                .ctx = ctx,
                .clock = clock,
                .delay_ns = delay_ns,
            };
        }

        /// Record new arguments and reset the deadline.
        pub fn trigger(self: *Self, args: Args) void {
            self.pending_args = args;
            self.deadline = self.clock.nowNs() + self.delay_ns;
        }

        /// Check if the deadline has passed. If so, fire the callback
        /// with the most recent arguments. Returns true if fired.
        pub fn tick(self: *Self) bool {
            if (self.pending_args) |args| {
                if (self.clock.nowNs() >= self.deadline) {
                    self.pending_args = null;
                    self.callback(args, self.ctx);
                    return true;
                }
            }
            return false;
        }

        /// Cancel any pending invocation without firing.
        pub fn cancel(self: *Self) void {
            self.pending_args = null;
        }

        /// Force-fire the pending invocation immediately, if any.
        pub fn flush(self: *Self) bool {
            if (self.pending_args) |args| {
                self.pending_args = null;
                self.callback(args, self.ctx);
                return true;
            }
            return false;
        }
    };
}

// ── Tests ───────────────────────────────────────────────────────────────

const StoppedClock = @import("clock").StoppedClock;

const TestSize = struct { w: u32, h: u32 };

var test_fire_count: u32 = 0;
var test_last_args: ?TestSize = null;

fn testCallback(args: TestSize, _: ?*anyopaque) void {
    test_fire_count += 1;
    test_last_args = args;
}

fn resetTestState() void {
    test_fire_count = 0;
    test_last_args = null;
}

const ms = std.time.ns_per_ms;

test "tick does not fire before deadline" {
    resetTestState();
    var sc = StoppedClock{};
    var db = Debounce(TestSize).init(testCallback, null, sc.clock(), 50 * ms);

    db.trigger(.{ .w = 100, .h = 200 });
    sc.advance(30 * ms);
    try std.testing.expect(!db.tick());
    try std.testing.expectEqual(@as(u32, 0), test_fire_count);
}

test "tick fires after deadline" {
    resetTestState();
    var sc = StoppedClock{};
    var db = Debounce(TestSize).init(testCallback, null, sc.clock(), 50 * ms);

    db.trigger(.{ .w = 100, .h = 200 });
    sc.advance(60 * ms);
    try std.testing.expect(db.tick());
    try std.testing.expectEqual(@as(u32, 1), test_fire_count);
    try std.testing.expectEqual(@as(u32, 200), test_last_args.?.h);
}

test "rapid triggers coalesce to one fire with last args" {
    resetTestState();
    var sc = StoppedClock{};
    var db = Debounce(TestSize).init(testCallback, null, sc.clock(), 250 * ms);

    // First resize at t=0
    db.trigger(.{ .w = 360, .h = 474 });

    // Second resize at t=40ms — resets deadline to t=290ms
    sc.advance(40 * ms);
    db.trigger(.{ .w = 360, .h = 486 });

    // t=250ms — past first trigger's deadline, but not second's
    sc.advance(210 * ms);
    try std.testing.expect(!db.tick());
    try std.testing.expectEqual(@as(u32, 0), test_fire_count);

    // t=300ms — past second trigger's deadline
    sc.advance(50 * ms);
    try std.testing.expect(db.tick());
    try std.testing.expectEqual(@as(u32, 1), test_fire_count);
    try std.testing.expectEqual(@as(u32, 486), test_last_args.?.h);
}

test "flush fires immediately" {
    resetTestState();
    var sc = StoppedClock{};
    var db = Debounce(TestSize).init(testCallback, null, sc.clock(), 1 * std.time.ns_per_s);

    try std.testing.expect(!db.flush()); // nothing pending
    db.trigger(.{ .w = 42, .h = 42 });
    try std.testing.expect(db.flush()); // fires without advancing clock
    try std.testing.expectEqual(@as(u32, 1), test_fire_count);
    try std.testing.expect(db.pending_args == null);
}

test "cancel discards pending" {
    resetTestState();
    var sc = StoppedClock{};
    var db = Debounce(TestSize).init(testCallback, null, sc.clock(), 50 * ms);

    db.trigger(.{ .w = 1, .h = 1 });
    db.cancel();
    sc.advance(100 * ms);
    try std.testing.expect(!db.tick());
    try std.testing.expectEqual(@as(u32, 0), test_fire_count);
}

test "context pointer is passed to callback" {
    var counter: u32 = 0;
    const cb = struct {
        fn f(_: TestSize, ctx: ?*anyopaque) void {
            const p: *u32 = @ptrCast(@alignCast(ctx));
            p.* += 1;
        }
    }.f;
    var sc = StoppedClock{};
    var db = Debounce(TestSize).init(cb, @ptrCast(&counter), sc.clock(), 10 * ms);
    db.trigger(.{ .w = 1, .h = 1 });
    sc.advance(15 * ms);
    try std.testing.expect(db.tick());
    try std.testing.expectEqual(@as(u32, 1), counter);
}
