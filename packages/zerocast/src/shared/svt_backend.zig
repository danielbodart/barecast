//! SVT-AV1 software encoder backend.
//!
//! Implements the `encoder.EncodeBackend` vtable by wrapping the SVT-AV1
//! C API. Produces AV1 bitstreams on hosts without hardware AV1 encode.
//!
//! Frame ingestion is CPU-side: callers plant a YUV I420 buffer via
//! `setPendingYuv` before each `prepare → encode` cycle. The actual
//! capture-to-YUV download path is wired by T-010; this backend just
//! accepts whatever is set.
//!
//! Encoder parameters at T-006 are intentionally minimal — enough to
//! produce a valid AV1 bitstream. T-011 (CQP), T-012 (P-only GOP), and
//! T-013 (BT.709 metadata) refine the configuration.

const std = @import("std");
const encoder = @import("encoder");
const Codec = @import("codec").Codec;

const c = @cImport({
    @cInclude("EbSvtAv1Enc.h");
});

const log = std.log.scoped(.svt_backend);

pub const SvtError = error{
    InitHandleFailed,
    SetParameterFailed,
    InitFailed,
    SendPictureFailed,
    GetPacketFailed,
    NoPendingInput,
};

/// Plane strides/offsets for a single YUV I420 picture.
pub const PictureLayout = struct {
    width: u32,
    height: u32,

    pub fn lumaSize(self: PictureLayout) usize {
        return @as(usize, self.width) * self.height;
    }
    pub fn chromaSize(self: PictureLayout) usize {
        return @as(usize, self.width / 2) * (self.height / 2);
    }
    pub fn totalSize(self: PictureLayout) usize {
        return self.lumaSize() + 2 * self.chromaSize();
    }
};

pub const SvtBackend = struct {
    component: ?*c.EbComponentType = null,
    config: c.EbSvtAv1EncConfiguration = .{},
    layout: PictureLayout,
    codec: Codec = .av1,

    // Input staging — callers populate via setPendingYuv before each
    // prepare/encode cycle. Owned externally; this struct only reads.
    pending_yuv: ?[]const u8 = null,

    // Output — held between encode() returning non-null and unlock().
    current_packet: ?*c.EbBufferHeaderType = null,

    // Monotonic PTS counter in picture units; converted to time by the
    // caller. SVT-AV1 requires unique PTS per input picture.
    next_pts: i64 = 0,

    /// Initialise an SVT-AV1 encoder for the given dimensions and rate
    /// parameters. Caller owns lifecycle; call `deinit` to release.
    pub fn init(width: u32, height: u32, fps: u32, qp: u32) SvtError!SvtBackend {
        var self = SvtBackend{ .layout = .{ .width = width, .height = height } };

        // Allocate component + prime default config in one call.
        var config: c.EbSvtAv1EncConfiguration = .{};
        const init_rc = c.svt_av1_enc_init_handle(&self.component, &config);
        if (init_rc != c.EB_ErrorNone) {
            log.err("svt_av1_enc_init_handle failed: {d}", .{init_rc});
            return SvtError.InitHandleFailed;
        }
        errdefer _ = c.svt_av1_enc_deinit_handle(self.component);

        // Dimensions + frame rate.
        config.source_width = width;
        config.source_height = height;
        config.frame_rate_numerator = fps;
        config.frame_rate_denominator = 1;

        // Preset 12 — fastest. Appropriate for a software-fallback where
        // encode speed matters more than peak quality.
        config.enc_mode = 12;

        // CQP rate control (T-011 refines). `enable_adaptive_quantization=0`
        // + `rate_control_mode=CQP_OR_CRF` means every frame uses `qp`.
        config.rate_control_mode = c.SVT_AV1_RC_MODE_CQP_OR_CRF;
        config.enable_adaptive_quantization = 0;
        config.qp = @intCast(qp);

        // Apply and commit.
        const set_rc = c.svt_av1_enc_set_parameter(self.component, &config);
        if (set_rc != c.EB_ErrorNone) {
            log.err("svt_av1_enc_set_parameter failed: {d}", .{set_rc});
            return SvtError.SetParameterFailed;
        }

        const init_enc_rc = c.svt_av1_enc_init(self.component);
        if (init_enc_rc != c.EB_ErrorNone) {
            log.err("svt_av1_enc_init failed: {d}", .{init_enc_rc});
            return SvtError.InitFailed;
        }

        self.config = config;
        return self;
    }

    pub fn deinit(self: *SvtBackend) void {
        if (self.component) |comp| {
            _ = c.svt_av1_enc_deinit(comp);
            _ = c.svt_av1_enc_deinit_handle(comp);
            self.component = null;
        }
    }

    /// Plant an I420 YUV buffer for the next encode cycle. Expected
    /// layout: luma plane (width*height) immediately followed by U
    /// plane ((width/2)*(height/2)) and V plane (same size). The
    /// caller keeps ownership; SvtBackend reads only during `encodeFn`.
    pub fn setPendingYuv(self: *SvtBackend, yuv: []const u8) void {
        self.pending_yuv = yuv;
    }

    /// Return an EncodeBackend vtable pointing to this instance.
    pub fn backend(self: *SvtBackend) encoder.EncodeBackend {
        return .{
            .ptr = @ptrCast(self),
            .codec = self.codec,
            .prepareFn = @ptrCast(&prepareFn),
            .encodeFn = @ptrCast(&encodeFn),
            .unlockFn = @ptrCast(&unlockFn),
            .deinitFn = @ptrCast(&deinitFn),
        };
    }

    fn prepareFn(self: *SvtBackend) anyerror!void {
        if (self.pending_yuv == null) {
            log.err("prepareFn: no pending YUV input", .{});
            return SvtError.NoPendingInput;
        }
        if (self.pending_yuv.?.len < self.layout.totalSize()) {
            log.err("prepareFn: YUV buffer too small ({d} < {d})", .{
                self.pending_yuv.?.len, self.layout.totalSize(),
            });
            return SvtError.NoPendingInput;
        }
    }

    fn encodeFn(self: *SvtBackend, force_key: bool) anyerror!?encoder.EncodedFrame {
        const yuv = self.pending_yuv orelse return SvtError.NoPendingInput;

        // Build EbSvtIOFormat referencing the caller's YUV planes directly.
        const luma_len = self.layout.lumaSize();
        const chroma_len = self.layout.chromaSize();
        var io = c.EbSvtIOFormat{
            .luma = @constCast(@ptrCast(yuv.ptr)),
            .cb = @constCast(@ptrCast(yuv.ptr + luma_len)),
            .cr = @constCast(@ptrCast(yuv.ptr + luma_len + chroma_len)),
            .y_stride = self.layout.width,
            .cb_stride = self.layout.width / 2,
            .cr_stride = self.layout.width / 2,
        };

        var in_hdr = c.EbBufferHeaderType{
            .size = @sizeOf(c.EbBufferHeaderType),
            .p_buffer = @ptrCast(&io),
            .n_filled_len = @intCast(self.layout.totalSize()),
            .n_alloc_len = @intCast(self.layout.totalSize()),
            .p_app_private = null,
            .wrapper_ptr = null,
            .n_tick_count = 0,
            .dts = self.next_pts,
            .pts = self.next_pts,
            .temporal_layer_index = 0,
            .qp = 0,
            .pic_type = if (force_key) c.EB_AV1_KEY_PICTURE else c.EB_AV1_INVALID_PICTURE,
            .metadata = null,
            .flags = 0,
            .luma_sse = 0,
            .cr_sse = 0,
            .cb_sse = 0,
            .luma_ssim = 0.0,
            .cr_ssim = 0.0,
            .cb_ssim = 0.0,
        };
        self.next_pts += 1;

        const send_rc = c.svt_av1_enc_send_picture(self.component, &in_hdr);
        if (send_rc != c.EB_ErrorNone) {
            log.err("svt_av1_enc_send_picture failed: {d}", .{send_rc});
            return SvtError.SendPictureFailed;
        }

        // Consume current input reference — a subsequent encode needs a
        // fresh setPendingYuv.
        self.pending_yuv = null;

        // Non-blocking poll. If no packet is ready yet (SVT buffers inputs
        // internally before emitting), return null so the caller can try
        // again after submitting more frames.
        var out_ptr: ?*c.EbBufferHeaderType = null;
        const get_rc = c.svt_av1_enc_get_packet(self.component, &out_ptr, 0);
        if (get_rc == c.EB_NoErrorEmptyQueue) return null;
        if (get_rc != c.EB_ErrorNone) {
            log.err("svt_av1_enc_get_packet failed: {d}", .{get_rc});
            return SvtError.GetPacketFailed;
        }

        const pkt = out_ptr orelse return null;
        self.current_packet = pkt;
        const bytes = pkt.p_buffer[0..pkt.n_filled_len];
        const is_key = pkt.pic_type == c.EB_AV1_KEY_PICTURE or pkt.pic_type == c.EB_AV1_INTRA_ONLY_PICTURE;
        return .{
            .data = bytes,
            .is_key = is_key,
            .pts = @intCast(@max(0, pkt.pts)),
        };
    }

    fn unlockFn(self: *SvtBackend) void {
        if (self.current_packet != null) {
            c.svt_av1_enc_release_out_buffer(&self.current_packet);
            self.current_packet = null;
        }
    }

    fn deinitFn(self: *SvtBackend) void {
        self.deinit();
    }
};

// ─────────────────────────────────────────────────────────────────────
// Smoke test — exercises init/deinit without feeding frames. Verifies
// the backend links and the SVT-AV1 handle lifecycle completes cleanly.
// Full contract-test integration follows in T-016.
// ─────────────────────────────────────────────────────────────────────

test "SvtBackend init + deinit does not leak handles" {
    var be = try SvtBackend.init(320, 240, 30, 32);
    defer be.deinit();
    try std.testing.expectEqual(Codec.av1, be.codec);
    try std.testing.expect(be.component != null);
}
