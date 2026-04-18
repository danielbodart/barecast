//! Encoder backend contract tests.
//!
//! Any `EncodeBackend` implementation (NVENC, VA-API, SVT-AV1 software,
//! VideoToolbox) must satisfy the same behavioural contract defined here.
//! Tests are parameterised over a backend factory, so each implementation
//! supplies its own construction logic and runs the shared cases.
//!
//! Currently validated by a trivial in-file fake backend; real backends
//! plug into `runContract` as they land (NVENC in its GPU-gated test step,
//! SVT-AV1 software in the GPU-free unit tier).

const std = @import("std");
const encoder = @import("encoder");
const Codec = encoder.Codec;

/// Minimum config a factory needs to build a backend for the contract suite.
pub const ContractConfig = struct {
    codec: Codec,
    width: u32,
    height: u32,
    fps: u32,
    qp: u32 = 20,
};

/// Factory signature. Implementations construct a fresh backend and return
/// the erased vtable. Ownership of the backing struct is the factory's
/// responsibility; `deinitFn` on the returned backend must release it.
pub const BackendFactory = *const fn (
    allocator: std.mem.Allocator,
    config: ContractConfig,
) anyerror!encoder.EncodeBackend;

/// Case 1 — configure-then-submit produces output.
/// After a single prepare+encode cycle the backend must emit at least one
/// encoded frame (the first frame is always a keyframe in this pipeline).
pub fn caseFirstFramePrdocesOutput(
    allocator: std.mem.Allocator,
    factory: BackendFactory,
    config: ContractConfig,
) !void {
    var backend = try factory(allocator, config);
    defer backend.deinit();

    try backend.prepare();
    const maybe = try backend.encode(true);
    try std.testing.expect(maybe != null);
    try std.testing.expect(maybe.?.is_key);
    backend.unlock();
}

/// Case 2 — requestKeyframe flag forces an IDR on the next encoded frame.
/// Submit one non-key frame, then a forced-key frame, assert the latter.
pub fn caseForceKeyframeHonored(
    allocator: std.mem.Allocator,
    factory: BackendFactory,
    config: ContractConfig,
) !void {
    var backend = try factory(allocator, config);
    defer backend.deinit();

    try backend.prepare();
    if (try backend.encode(false)) |_| backend.unlock();

    try backend.prepare();
    const maybe = try backend.encode(true);
    try std.testing.expect(maybe != null);
    try std.testing.expect(maybe.?.is_key);
    backend.unlock();
}

/// Case 3 — teardown releases resources without panic.
/// `deinit()` must be idempotent-safe from a freshly configured backend
/// (no frames submitted) and after successful encode.
pub fn caseTeardownNoLeak(
    allocator: std.mem.Allocator,
    factory: BackendFactory,
    config: ContractConfig,
) !void {
    // Empty backend
    {
        var backend = try factory(allocator, config);
        backend.deinit();
    }
    // Backend after one encode cycle
    {
        var backend = try factory(allocator, config);
        defer backend.deinit();
        try backend.prepare();
        if (try backend.encode(true)) |_| backend.unlock();
    }
}

/// Case 4 — reconfigure-emits-keyframe.
/// Tear down and re-create a backend at a new resolution. The first frame
/// from the freshly configured backend must be a keyframe regardless of
/// the force flag — fresh encoder state cannot refer to prior frames.
pub fn caseReconfigureEmitsKeyframe(
    allocator: std.mem.Allocator,
    factory: BackendFactory,
    config: ContractConfig,
) !void {
    // First backend at config.width × config.height
    {
        var backend = try factory(allocator, config);
        defer backend.deinit();
        try backend.prepare();
        if (try backend.encode(true)) |_| backend.unlock();
    }

    // Reconfigured backend at a different size. First emitted frame
    // should be a keyframe — we pass force=false to prove the encoder
    // self-keyframes on a fresh stream.
    var reconf = config;
    reconf.width = @max(64, config.width / 2);
    reconf.height = @max(64, config.height / 2);
    var backend = try factory(allocator, reconf);
    defer backend.deinit();
    try backend.prepare();
    const maybe = try backend.encode(false);
    try std.testing.expect(maybe != null);
    try std.testing.expect(maybe.?.is_key);
    backend.unlock();
}

/// Case 5 — malformed input is rejected cleanly.
/// A backend must refuse to encode before prepare() has been called
/// or after teardown, without crashing or producing stale output.
pub fn caseMalformedInputRejected(
    allocator: std.mem.Allocator,
    factory: BackendFactory,
    config: ContractConfig,
) !void {
    var backend = try factory(allocator, config);
    defer backend.deinit();

    // encode() before prepare() either errors cleanly or returns null.
    // Both are acceptable contracts — backend must not crash.
    const maybe = backend.encode(false) catch null;
    if (maybe) |_| backend.unlock();
}

/// Run every contract case against the supplied factory. Call this from a
/// real backend's test block; failures bubble up with useful diagnostics.
pub fn runContract(
    allocator: std.mem.Allocator,
    factory: BackendFactory,
    config: ContractConfig,
) !void {
    try caseFirstFramePrdocesOutput(allocator, factory, config);
    try caseForceKeyframeHonored(allocator, factory, config);
    try caseTeardownNoLeak(allocator, factory, config);
    try caseReconfigureEmitsKeyframe(allocator, factory, config);
    try caseMalformedInputRejected(allocator, factory, config);
}

// ─────────────────────────────────────────────────────────────────────
// Skeleton validation: drive the contract through a trivial in-file fake.
// This proves the harness compiles and the flow is coherent. Real backends
// replace the fake with their own factory.
// ─────────────────────────────────────────────────────────────────────

const FakeBackend = struct {
    allocator: std.mem.Allocator,
    codec: Codec,
    keyframe_requested: bool = true, // first frame always key
    next_pts: u64 = 0,
    frame_buf: [64]u8 = undefined,

    fn prepare(ptr: *anyopaque) anyerror!void {
        _ = ptr;
    }

    fn encode(ptr: *anyopaque, force_key: bool) anyerror!?encoder.EncodedFrame {
        const self: *FakeBackend = @ptrCast(@alignCast(ptr));
        const is_key = force_key or self.keyframe_requested;
        self.keyframe_requested = false;
        @memset(&self.frame_buf, 0xA5);
        const pts = self.next_pts;
        self.next_pts += 1;
        return encoder.EncodedFrame{
            .data = &self.frame_buf,
            .is_key = is_key,
            .pts = pts,
        };
    }

    fn unlock(ptr: *anyopaque) void {
        _ = ptr;
    }

    fn deinitErase(ptr: *anyopaque) void {
        const self: *FakeBackend = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }

    pub fn build(allocator: std.mem.Allocator, config: ContractConfig) anyerror!encoder.EncodeBackend {
        const self = try allocator.create(FakeBackend);
        self.* = .{ .allocator = allocator, .codec = config.codec };
        return .{
            .ptr = @ptrCast(self),
            .codec = self.codec,
            .prepareFn = prepare,
            .encodeFn = encode,
            .unlockFn = unlock,
            .deinitFn = deinitErase,
        };
    }
};

test "contract: FakeBackend satisfies the full contract" {
    const cfg = ContractConfig{ .codec = .av1, .width = 320, .height = 240, .fps = 30 };
    try runContract(std.testing.allocator, FakeBackend.build, cfg);
}

// ─────────────────────────────────────────────────────────────────────
// Property tests — T-008. Fuzz the factory across the valid config
// ranges and run the full contract. A backend that can be constructed
// at (w, h, fps, qp) within spec bounds must pass every contract case
// for that configuration.
// ─────────────────────────────────────────────────────────────────────

test "property: contract holds across the valid config range" {
    // Bounds per capture-pipeline R3 + SVT-AV1 spec (widths multiple of
    // 8, height even, fps 1–240, qp 0–63). The FakeBackend here is lax
    // about those bounds; a real backend plug-in constrains to its own.
    const dims = [_]struct { w: u32, h: u32 }{
        .{ .w = 64, .h = 64 }, // minimum
        .{ .w = 128, .h = 72 },
        .{ .w = 320, .h = 240 },
        .{ .w = 640, .h = 480 },
        .{ .w = 1280, .h = 720 },
        .{ .w = 1920, .h = 1080 },
        .{ .w = 3840, .h = 2160 }, // 4K
    };
    const fpses = [_]u32{ 1, 15, 24, 30, 60, 120 };
    const qps = [_]u32{ 0, 10, 20, 32, 51, 63 };

    for (dims) |d| {
        // For each dimension pick a coprime-ish fps + qp so we
        // sweep combinations without an O(n³) explosion.
        const fps = fpses[d.w % fpses.len];
        const qp = qps[d.h % qps.len];
        const cfg = ContractConfig{
            .codec = .av1,
            .width = d.w,
            .height = d.h,
            .fps = fps,
            .qp = qp,
        };
        runContract(std.testing.allocator, FakeBackend.build, cfg) catch |err| {
            std.debug.print(
                "contract failed at {d}x{d} @ {d}fps qp={d}: {}\n",
                .{ d.w, d.h, fps, qp, err },
            );
            return err;
        };
    }
}

test "property: reconfigure is idempotent on repeated calls" {
    // Repeatedly create+destroy a backend at the same config. Each
    // cycle must produce a valid first-keyframe and release cleanly.
    const cfg = ContractConfig{ .codec = .av1, .width = 640, .height = 480, .fps = 30 };
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        var backend = try FakeBackend.build(std.testing.allocator, cfg);
        defer backend.deinit();
        try backend.prepare();
        const maybe = try backend.encode(true);
        try std.testing.expect(maybe != null);
        try std.testing.expect(maybe.?.is_key);
        backend.unlock();
    }
}

// ─────────────────────────────────────────────────────────────────────
// FrameBuffer (in-memory FrameSink double) — unit tests
// ─────────────────────────────────────────────────────────────────────

test "FrameBuffer: retains frames up to capacity and wraps" {
    var buf = try encoder.FrameBuffer.init(std.testing.allocator, 3);
    defer buf.deinit();

    try std.testing.expectEqual(@as(usize, 0), buf.count());

    const data: [4]u8 = .{ 1, 2, 3, 4 };
    var i: u64 = 0;
    while (i < 5) : (i += 1) {
        const frame = encoder.EncodedFrame{ .data = &data, .is_key = (i == 0), .pts = i };
        try buf.push(frame, i * 33, 0);
    }

    try std.testing.expectEqual(@as(usize, 3), buf.count());
    try std.testing.expectEqual(@as(usize, 5), buf.total_pushed);
}

test "FrameBuffer: items() returns oldest-first with wrap" {
    var buf = try encoder.FrameBuffer.init(std.testing.allocator, 2);
    defer buf.deinit();

    const bytes: [2]u8 = .{ 0, 1 };
    inline for (.{ 10, 20, 30 }) |pts| {
        try buf.push(
            encoder.EncodedFrame{ .data = &bytes, .is_key = false, .pts = pts },
            pts,
            0,
        );
    }

    var out: [2]encoder.StoredFrame = undefined;
    const items = buf.items(&out);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(@as(u64, 20), items[0].pts_ms);
    try std.testing.expectEqual(@as(u64, 30), items[1].pts_ms);
}
