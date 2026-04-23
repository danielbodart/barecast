//! GPU-free integration lane (cavekit-testing R2 AC3).
//!
//! Drives a synthetic RGBA source through the SVT-AV1 software backend
//! into the in-memory `FrameBuffer` sink. Exercises the capture → encode
//! → transport layering end-to-end without any GPU or WebRTC dependency
//! so CI can run it anywhere. The matching `./run.ts sw-integration`
//! target is the single entry point this lane exposes.
//!
//! A success run prints one summary line; a pipeline failure prints a
//! stderr line and exits non-zero so the CI runner flags it.

const std = @import("std");
const yuv = @import("yuv");
const encoder_mod = @import("encoder");
const svt_mod = @import("svt_backend");

const FRAMES: u32 = 60;
const WIDTH: u32 = 320;
const HEIGHT: u32 = 240;
const FPS: u32 = 30;
const QP: u32 = 32;
const MAX_DRAIN_STEPS: u32 = FRAMES * 3;

/// Capture-stage proxy. Each `prepare` synthesizes a moving gradient
/// into an owned RGBA buffer, converts it to I420 with the shared
/// BT.709 limited-range helper, and plants the result into SvtBackend
/// exactly the way FrameDownloader would on a real GPU host.
const SyntheticAdapter = struct {
    allocator: std.mem.Allocator,
    inner: *svt_mod.SvtBackend,
    inner_vtable: encoder_mod.EncodeBackend,
    rgba_buf: []u8,
    yuv_buf: []u8,
    width: u32,
    height: u32,
    frame_idx: u32 = 0,

    fn prepareErase(ptr: *anyopaque) anyerror!void {
        const self: *SyntheticAdapter = @ptrCast(@alignCast(ptr));
        paintGradient(self.rgba_buf, self.width, self.height, self.frame_idx);
        self.frame_idx +%= 1;
        try yuv.rgbaToI420Bt709Limited(self.rgba_buf, self.width, self.height, self.yuv_buf);
        self.inner.setPendingYuv(self.yuv_buf);
        return self.inner_vtable.prepare();
    }

    fn encodeErase(ptr: *anyopaque, force_key: bool) anyerror!?encoder_mod.EncodedFrame {
        const self: *SyntheticAdapter = @ptrCast(@alignCast(ptr));
        return self.inner_vtable.encode(force_key);
    }

    fn unlockErase(ptr: *anyopaque) void {
        const self: *SyntheticAdapter = @ptrCast(@alignCast(ptr));
        self.inner_vtable.unlock();
    }

    fn deinitErase(ptr: *anyopaque) void {
        const self: *SyntheticAdapter = @ptrCast(@alignCast(ptr));
        self.inner.deinit();
        self.allocator.destroy(self.inner);
        self.allocator.free(self.rgba_buf);
        self.allocator.free(self.yuv_buf);
        self.allocator.destroy(self);
    }

    fn build(
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
        fps: u32,
        qp: u32,
    ) !encoder_mod.EncodeBackend {
        const adapter = try allocator.create(SyntheticAdapter);
        errdefer allocator.destroy(adapter);

        const svt = try allocator.create(svt_mod.SvtBackend);
        errdefer allocator.destroy(svt);

        svt.* = try svt_mod.SvtBackend.init(width, height, fps, qp);
        errdefer svt.deinit();

        const rgba = try allocator.alloc(u8, @as(usize, width) * height * 4);
        errdefer allocator.free(rgba);

        const yuv_buf = try allocator.alloc(u8, yuv.i420Size(width, height));
        errdefer allocator.free(yuv_buf);

        adapter.* = .{
            .allocator = allocator,
            .inner = svt,
            .inner_vtable = svt.backend(),
            .rgba_buf = rgba,
            .yuv_buf = yuv_buf,
            .width = width,
            .height = height,
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

/// Paint a moving R/G/B gradient. Real content matters — an all-grey
/// frame would compress to a single intra block and hide any issues
/// with per-frame motion estimation or reference handling.
fn paintGradient(buf: []u8, width: u32, height: u32, phase: u32) void {
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const idx = (@as(usize, y) * width + x) * 4;
            buf[idx + 0] = @intCast((x + phase) & 0xff);
            buf[idx + 1] = @intCast((y + phase) & 0xff);
            buf[idx + 2] = @intCast((x + y + phase) & 0xff);
            buf[idx + 3] = 255;
        }
    }
}

pub fn main() !u8 {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var backend = try SyntheticAdapter.build(allocator, WIDTH, HEIGHT, FPS, QP);
    defer backend.deinit();

    var frames = try encoder_mod.FrameBuffer.init(allocator, 128);
    defer frames.deinit();

    var pushed: u32 = 0;
    var iter: u32 = 0;
    while (iter < MAX_DRAIN_STEPS and pushed < FRAMES) : (iter += 1) {
        try backend.prepare();
        const force_key = iter == 0;
        if (try backend.encode(force_key)) |frame| {
            try frames.push(frame, iter, 0);
            backend.unlock();
            pushed += 1;
        }
    }

    const count = frames.count();
    var out_slots: [128]encoder_mod.StoredFrame = undefined;
    const items = frames.items(out_slots[0..count]);
    var keys: u32 = 0;
    var total: u64 = 0;
    for (items) |it| {
        if (it.is_key) keys += 1;
        total += it.bytes.len;
    }

    var stdout_buf: [256]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    try stdout.interface.print(
        "sw-integration: drove {d} iterations → {d} frames buffered, {d} keyframes, {d} bytes total\n",
        .{ iter, count, keys, total },
    );
    try stdout.interface.flush();

    // The pipeline is healthy when a keyframe and ≥half the requested
    // frames made it through. A stricter assertion would over-fit to
    // SVT's exact warm-up behaviour across library versions.
    if (count < FRAMES / 2 or keys == 0) {
        var err_buf: [256]u8 = undefined;
        var stderr = std.fs.File.stderr().writer(&err_buf);
        try stderr.interface.print(
            "sw-integration FAILED: expected >={d} frames + >=1 keyframe, got {d} / {d}\n",
            .{ FRAMES / 2, count, keys },
        );
        try stderr.interface.flush();
        return 1;
    }

    return 0;
}
