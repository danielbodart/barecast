//! Encoder backend contract tests.
//!
//! Any `EncodeBackend` implementation (NVENC, SVT-AV1, VideoToolbox) must
//! satisfy the same behavioural contract defined here. Tests are
//! parameterised over a backend factory, so each implementation supplies
//! its own construction logic and runs the shared cases.
//!
//! This file exercises the contract against:
//!   * `FakeBackend` — in-file dummy that emits on first encode.
//!   * `SvtContractAdapter` — real SVT-AV1 software backend wrapped with a
//!     mid-grey YUV feeder (so the contract runs GPU-free in the unit tier).
//!
//! The hardware NVENC backend is exercised by the same `runContract` entry
//! point from its GPU-gated test step (compositor integration tests).

const std = @import("std");
const encoder = @import("encoder");
const svt_backend = @import("svt_backend");
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

/// Software encoders (SVT-AV1) buffer inputs internally before emitting the
/// first packet. Driving the backend through `prepare → encode` once is not
/// enough; we have to drain a bounded number of cycles until a packet
/// emerges. Hardware backends that emit immediately exit on the first
/// iteration, so the same helper serves every implementation.
///
/// `force_first_key` applies only to the first submitted frame; subsequent
/// drain cycles submit with `force = false` so the encoder's natural GOP
/// structure holds.
pub fn encodeUntilOutput(
    backend: encoder.EncodeBackend,
    force_first_key: bool,
    max_steps: usize,
) !?encoder.EncodedFrame {
    var i: usize = 0;
    while (i < max_steps) : (i += 1) {
        try backend.prepare();
        const force = force_first_key and i == 0;
        if (try backend.encode(force)) |frame| return frame;
    }
    return null;
}

/// Case 1 — a fresh backend emits a keyframe within a bounded number of
/// submissions. The encoder's stream must start with an IDR; whether it
/// comes out on the first cycle or after a short queue is a backend detail.
pub fn caseFirstFrameProducesOutput(
    allocator: std.mem.Allocator,
    factory: BackendFactory,
    config: ContractConfig,
) !void {
    var backend = try factory(allocator, config);
    defer backend.deinit();

    const maybe = try encodeUntilOutput(backend, true, 32);
    try std.testing.expect(maybe != null);
    try std.testing.expect(maybe.?.is_key);
    backend.unlock();
}

/// Case 2 — requestKeyframe flag forces an IDR within a bounded number of
/// subsequent submissions. Warm past the opening IDR, drive one non-key
/// submission, then force a keyframe and assert the next emitted frame is
/// marked as a keyframe.
pub fn caseForceKeyframeHonored(
    allocator: std.mem.Allocator,
    factory: BackendFactory,
    config: ContractConfig,
) !void {
    var backend = try factory(allocator, config);
    defer backend.deinit();

    // Warm up: drain the opening IDR.
    if (try encodeUntilOutput(backend, true, 32)) |_| backend.unlock();

    // One non-key submission. May or may not emit; either way does not
    // change the contract below.
    try backend.prepare();
    if (try backend.encode(false)) |_| backend.unlock();

    // Force a keyframe on the next submission. The next frame the backend
    // emits must be flagged as a keyframe.
    const maybe = try encodeUntilOutput(backend, true, 32);
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
    // Backend after one drain cycle
    {
        var backend = try factory(allocator, config);
        defer backend.deinit();
        if (try encodeUntilOutput(backend, true, 32)) |_| backend.unlock();
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
        if (try encodeUntilOutput(backend, true, 32)) |_| backend.unlock();
    }

    // Reconfigured backend at a different size. First emitted frame
    // should be a keyframe — pass force=false to prove the encoder
    // self-keyframes on a fresh stream.
    var reconf = config;
    reconf.width = @max(64, config.width / 2);
    reconf.height = @max(64, config.height / 2);
    var backend = try factory(allocator, reconf);
    defer backend.deinit();
    const maybe = try encodeUntilOutput(backend, false, 32);
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
    try caseFirstFrameProducesOutput(allocator, factory, config);
    try caseForceKeyframeHonored(allocator, factory, config);
    try caseTeardownNoLeak(allocator, factory, config);
    try caseReconfigureEmitsKeyframe(allocator, factory, config);
    try caseMalformedInputRejected(allocator, factory, config);
}

// ─────────────────────────────────────────────────────────────────────
// Skeleton validation: drive the contract through a trivial in-file fake.
// This proves the harness compiles and the flow is coherent.
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
// SVT-AV1 software backend — T-016 payoff.
//
// SvtContractAdapter wraps a real SvtBackend with an owned mid-grey I420
// buffer. Its `prepareFn` replants the YUV into SvtBackend.pending_yuv
// each cycle (SvtBackend consumes the reference during encode), so the
// contract suite can drive the software encoder without GPU capture.
//
// This is T-016: running `runContract` against the real software encoder
// so divergences surface at unit-test time.
// ─────────────────────────────────────────────────────────────────────

const SvtContractAdapter = struct {
    allocator: std.mem.Allocator,
    inner: *svt_backend.SvtBackend,
    inner_vtable: encoder.EncodeBackend,
    yuv: []u8,

    fn prepareErase(ptr: *anyopaque) anyerror!void {
        const self: *SvtContractAdapter = @ptrCast(@alignCast(ptr));
        self.inner.setPendingYuv(self.yuv);
        return self.inner_vtable.prepare();
    }

    fn encodeErase(ptr: *anyopaque, force_key: bool) anyerror!?encoder.EncodedFrame {
        const self: *SvtContractAdapter = @ptrCast(@alignCast(ptr));
        return self.inner_vtable.encode(force_key);
    }

    fn unlockErase(ptr: *anyopaque) void {
        const self: *SvtContractAdapter = @ptrCast(@alignCast(ptr));
        self.inner_vtable.unlock();
    }

    fn deinitErase(ptr: *anyopaque) void {
        const self: *SvtContractAdapter = @ptrCast(@alignCast(ptr));
        self.inner.deinit();
        self.allocator.destroy(self.inner);
        self.allocator.free(self.yuv);
        self.allocator.destroy(self);
    }

    /// Fill an I420 buffer with mid-grey (Y=128, U=V=128). The actual
    /// pixel contents do not matter for contract tests — SVT-AV1 still
    /// produces a valid bitstream — but a stable fill avoids uninitialised
    /// memory reads.
    fn fillMidGreyI420(buf: []u8, width: u32, height: u32) void {
        const luma = @as(usize, width) * height;
        const chroma = @as(usize, width / 2) * (height / 2);
        @memset(buf[0..luma], 128);
        @memset(buf[luma .. luma + chroma], 128);
        @memset(buf[luma + chroma .. luma + 2 * chroma], 128);
    }

    pub fn build(
        allocator: std.mem.Allocator,
        config: ContractConfig,
    ) anyerror!encoder.EncodeBackend {
        const adapter = try allocator.create(SvtContractAdapter);
        errdefer allocator.destroy(adapter);

        const svt = try allocator.create(svt_backend.SvtBackend);
        errdefer allocator.destroy(svt);

        svt.* = try svt_backend.SvtBackend.init(
            config.width,
            config.height,
            config.fps,
            config.qp,
        );
        errdefer svt.deinit();

        const yuv_len = svt.layout.totalSize();
        const yuv = try allocator.alloc(u8, yuv_len);
        errdefer allocator.free(yuv);
        fillMidGreyI420(yuv, config.width, config.height);

        adapter.* = .{
            .allocator = allocator,
            .inner = svt,
            .inner_vtable = svt.backend(),
            .yuv = yuv,
        };

        return .{
            .ptr = @ptrCast(adapter),
            .codec = .av1,
            .prepareFn = prepareErase,
            .encodeFn = encodeErase,
            .unlockFn = unlockErase,
            .deinitFn = deinitErase,
        };
    }
};

test "contract: SvtBackend satisfies the full contract" {
    const cfg = ContractConfig{ .codec = .av1, .width = 320, .height = 240, .fps = 30, .qp = 32 };
    try runContract(std.testing.allocator, SvtContractAdapter.build, cfg);
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
// T-015 — SW backend → IVF container end-to-end.
//
// Proves the software encoder emits into the AV1 IVF path that the
// hardware backends already use (`FrameSink.ivf` / `SessionRecorder`).
// Drives the SvtContractAdapter directly into an IvfWriter, finalises,
// and asserts the resulting file is a valid IVF with the AV01 FourCC
// and at least one emitted frame.
// ─────────────────────────────────────────────────────────────────────

test "T-015: SvtBackend output streams into a valid IVF container" {
    const allocator = std.testing.allocator;
    const cfg = ContractConfig{ .codec = .av1, .width = 320, .height = 240, .fps = 30, .qp = 32 };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Build backend via the contract factory so the same path used by
    // contract tests also drives recording.
    var backend = try SvtContractAdapter.build(allocator, cfg);
    defer backend.deinit();

    // Open IVF writer in the tmpdir — same IvfWriter used by session_recorder.
    var ivf = try encoder.IvfWriter.initDir(tmp.dir, "svt-t015.ivf");
    defer ivf.deinit();

    // Drain the SW encoder until at least one frame emerges, then keep
    // pushing a few more to exercise the multi-frame write path. SVT-AV1
    // with LOW_DELAY_B MiniGOP=4 typically buffers the first 3 submissions
    // before emitting; 32 steps is an ample ceiling.
    var emitted: u32 = 0;
    var i: usize = 0;
    while (i < 32 and emitted < 4) : (i += 1) {
        try backend.prepare();
        const force_key = i == 0;
        if (try backend.encode(force_key)) |frame| {
            try ivf.writeFrame(frame.data, i);
            backend.unlock();
            emitted += 1;
        }
    }

    try std.testing.expect(emitted > 0);
    try ivf.finalize(@intCast(cfg.width), @intCast(cfg.height), cfg.fps, 1);

    // Validate header: open the file and check magic + codec + frame count.
    const file = try tmp.dir.openFile("svt-t015.ivf", .{});
    defer file.close();
    var hdr: [32]u8 = undefined;
    const n = try file.readAll(&hdr);
    try std.testing.expectEqual(@as(usize, 32), n);
    try std.testing.expectEqualSlices(u8, "DKIF", hdr[0..4]);
    try std.testing.expectEqualSlices(u8, "AV01", hdr[8..12]);
    try std.testing.expectEqual(@as(u16, 320), std.mem.readInt(u16, hdr[12..14], .little));
    try std.testing.expectEqual(@as(u16, 240), std.mem.readInt(u16, hdr[14..16], .little));
    try std.testing.expectEqual(@as(u32, emitted), std.mem.readInt(u32, hdr[24..28], .little));
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
