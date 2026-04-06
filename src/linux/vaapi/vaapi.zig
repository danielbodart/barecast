const std = @import("std");
pub const Codec = @import("codec").Codec;

const log = std.log.scoped(.vaapi);

// ── VA-API C bindings ────────────────────────────────────────────────────

const c = @cImport({
    @cInclude("va/va.h");
    @cInclude("va/va_drm.h");
    @cInclude("va/va_drmcommon.h");
    // va_enc_hevc.h excluded — bitfield unions break Zig's translate-c.
    // HEVC encode parameter construction delegated to hevc_params.c.
    @cInclude("hevc_params.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

pub const VADisplay = c.VADisplay;
pub const VASurfaceID = c.VASurfaceID;

// ── Public types ─────────────────────────────────────────────────────────

pub const EncodedFrame = struct {
    data: []const u8,
    is_key: bool,
    pts: u64,
};

/// Exported VA surface info for EGL interop (double DMA-BUF trick).
pub const ExportedSurface = struct {
    fds: [2]i32,
    pitches: [2]u32,
    offsets: [2]u32,
    modifier: u64,
    width: u32,
    height: u32,
    num_layers: u32,
};

// ── Encoder ──────────────────────────────────────────────────────────────

const NUM_INPUT_SURFACES = 2;
const NUM_RECON_SURFACES = 2;

pub const Vaapi = struct {
    drm_fd: i32,
    display: VADisplay,
    config: c.VAConfigID,
    context: c.VAContextID,
    input_surfaces: [NUM_INPUT_SURFACES]VASurfaceID,
    recon_surfaces: [NUM_RECON_SURFACES]VASurfaceID,
    cur_input: u1, // 0 or 1
    cur_recon: u1, // 0 or 1
    coded_buf: c.VABufferID,
    codec: Codec,
    width: u32,
    height: u32,
    fps: u32,
    frame_count: u64,
    idr_period: u32,
    bitstream_ptr: ?[*]u8,
    bitstream_len: usize,

    pub fn init(render_path: [*:0]const u8, width: u32, height: u32, fps: u32) !Vaapi {
        const drm_fd = c.open(render_path, c.O_RDWR);
        if (drm_fd < 0) {
            log.err("failed to open {s}", .{render_path});
            return error.VaapiOpenFailed;
        }
        errdefer _ = c.close(drm_fd);

        const display = c.vaGetDisplayDRM(drm_fd);
        if (display == null) {
            log.err("vaGetDisplayDRM failed", .{});
            return error.VaapiDisplayFailed;
        }

        _ = c.vaSetInfoCallback(display, null, null);

        var major: c_int = 0;
        var minor: c_int = 0;
        if (c.vaInitialize(display, &major, &minor) != c.VA_STATUS_SUCCESS) {
            log.err("vaInitialize failed", .{});
            return error.VaapiInitFailed;
        }
        errdefer _ = c.vaTerminate(display);

        log.info("VA-API {d}.{d} on {s}", .{ major, minor, render_path });

        const codec_result = detectCodec(display) orelse {
            log.err("no supported encode codec found", .{});
            return error.VaapiNoCodec;
        };

        log.info("codec: {s}, entrypoint: {s}", .{
            if (codec_result.codec == .av1) "AV1" else "HEVC",
            if (codec_result.low_power) "EncSliceLP" else "EncSlice",
        });

        var config: c.VAConfigID = undefined;
        if (c.vaCreateConfig(display, codec_result.profile, codec_result.entrypoint, null, 0, &config) != c.VA_STATUS_SUCCESS) {
            log.err("vaCreateConfig failed", .{});
            return error.VaapiConfigFailed;
        }
        errdefer _ = c.vaDestroyConfig(display, config);

        // Input surfaces: RGB32 — compositor output is XRGB, driver converts internally
        var input_surfaces: [NUM_INPUT_SURFACES]VASurfaceID = undefined;
        if (c.vaCreateSurfaces(display, c.VA_RT_FORMAT_RGB32, width, height, &input_surfaces, NUM_INPUT_SURFACES, null, 0) != c.VA_STATUS_SUCCESS) {
            log.err("vaCreateSurfaces (input, RGB32) failed", .{});
            return error.VaapiSurfaceFailed;
        }
        errdefer _ = c.vaDestroySurfaces(display, &input_surfaces, NUM_INPUT_SURFACES);

        // Reconstruction surfaces: YUV420 — driver writes decoded reconstruction here for DPB
        var recon_surfaces: [NUM_RECON_SURFACES]VASurfaceID = undefined;
        if (c.vaCreateSurfaces(display, c.VA_RT_FORMAT_YUV420, width, height, &recon_surfaces, NUM_RECON_SURFACES, null, 0) != c.VA_STATUS_SUCCESS) {
            log.err("vaCreateSurfaces (recon, YUV420) failed", .{});
            return error.VaapiSurfaceFailed;
        }
        errdefer _ = c.vaDestroySurfaces(display, &recon_surfaces, NUM_RECON_SURFACES);

        // Context only needs reconstruction surfaces (not input surfaces).
        // Input surfaces can come from any source (pre-allocated, DMA-BUF import, etc.)
        // and are passed to vaBeginPicture independently — matching FFmpeg's pattern.
        var context: c.VAContextID = undefined;
        if (c.vaCreateContext(display, config, @intCast(width), @intCast(height), c.VA_PROGRESSIVE, &recon_surfaces, NUM_RECON_SURFACES, &context) != c.VA_STATUS_SUCCESS) {
            log.err("vaCreateContext failed", .{});
            return error.VaapiContextFailed;
        }
        errdefer _ = c.vaDestroyContext(display, context);

        const coded_buf_size: c_uint = @max(width * height, 1024 * 1024);
        var coded_buf: c.VABufferID = undefined;
        if (c.vaCreateBuffer(display, context, c.VAEncCodedBufferType, coded_buf_size, 1, null, &coded_buf) != c.VA_STATUS_SUCCESS) {
            log.err("vaCreateBuffer (coded) failed", .{});
            return error.VaapiBufferFailed;
        }

        log.info("encoder ready: {d}x{d} @{d}fps (input=RGB32, recon=YUV420)", .{ width, height, fps });

        return .{
            .drm_fd = drm_fd,
            .display = display,
            .config = config,
            .context = context,
            .input_surfaces = input_surfaces,
            .recon_surfaces = recon_surfaces,
            .cur_input = 0,
            .cur_recon = 0,
            .coded_buf = coded_buf,
            .codec = codec_result.codec,
            .width = width,
            .height = height,
            .fps = fps,
            .frame_count = 0,
            .idr_period = fps * 4,
            .bitstream_ptr = null,
            .bitstream_len = 0,
        };
    }

    /// Export the current input surface as DMA-BUF fds for EGL interop.
    pub fn exportSurface(self: *Vaapi) !ExportedSurface {
        const surface = self.input_surfaces[self.cur_input];
        var prime: c.VADRMPRIMESurfaceDescriptor = undefined;
        const status = c.vaExportSurfaceHandle(
            self.display,
            surface,
            c.VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
            c.VA_EXPORT_SURFACE_WRITE_ONLY | c.VA_EXPORT_SURFACE_SEPARATE_LAYERS,
            &prime,
        );
        if (status != c.VA_STATUS_SUCCESS) {
            log.err("vaExportSurfaceHandle failed: {d}", .{status});
            return error.VaapiExportFailed;
        }

        _ = c.vaSyncSurface(self.display, surface);

        var result: ExportedSurface = .{
            .fds = .{ -1, -1 },
            .pitches = .{ 0, 0 },
            .offsets = .{ 0, 0 },
            .modifier = 0,
            .width = prime.width,
            .height = prime.height,
            .num_layers = prime.num_layers,
        };

        for (0..@min(prime.num_layers, 2)) |i| {
            const layer = prime.layers[i];
            const obj_idx = layer.object_index[0];
            result.fds[i] = prime.objects[obj_idx].fd;
            result.pitches[i] = layer.pitch[0];
            result.offsets[i] = layer.offset[0];
            result.modifier = prime.objects[obj_idx].drm_format_modifier;
        }

        return result;
    }

    /// Write a test pattern into the current input surface (for self-contained testing).
    /// Uses vaDeriveImage + vaMapBuffer for CPU access to the RGB32 surface.
    pub fn writeTestPattern(self: *Vaapi, frame_num: u64) !void {
        const surface = self.input_surfaces[self.cur_input];
        var image: c.VAImage = undefined;

        if (c.vaDeriveImage(self.display, surface, &image) != c.VA_STATUS_SUCCESS) {
            return error.VaapiDeriveImageFailed;
        }
        defer _ = c.vaDestroyImage(self.display, image.image_id);

        var buf_ptr: ?*anyopaque = null;
        if (c.vaMapBuffer(self.display, image.buf, &buf_ptr) != c.VA_STATUS_SUCCESS) {
            return error.VaapiMapFailed;
        }
        defer _ = c.vaUnmapBuffer(self.display, image.buf);

        const pixels: [*]u8 = @ptrCast(buf_ptr.?);
        const pitch: u32 = image.pitches[0];

        fillTestPattern(pixels, self.width, self.height, pitch, frame_num);
    }

    /// Return the current input surface ID (for vaBeginPicture in tests or external use).
    pub fn currentInputSurface(self: *const Vaapi) VASurfaceID {
        return self.input_surfaces[self.cur_input];
    }

    /// Import a DMA-BUF as a VA-API surface for use as encode input.
    /// The returned surface ID can be passed to encodeImported().
    /// Caller is responsible for destroying the surface via destroyImportedSurface().
    pub fn importDmaBuf(self: *Vaapi, fds: [4]i32, format: u32, modifier: u64, strides: [4]u32, offsets: [4]u32, n_planes: u32, width: u32, height: u32) !VASurfaceID {
        var attrib_list: [2]c.VASurfaceAttrib = undefined;

        // Memory type: DRM PRIME 2
        attrib_list[0] = .{
            .type = c.VASurfaceAttribMemoryType,
            .flags = c.VA_SURFACE_ATTRIB_SETTABLE,
            .value = .{ .type = c.VAGenericValueTypeInteger, .value = .{ .i = c.VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2 } },
        };

        // Build descriptor with per-plane objects
        // Each plane may share the same fd (common for tiled/CCS formats)
        var desc: c.VADRMPRIMESurfaceDescriptor = std.mem.zeroes(c.VADRMPRIMESurfaceDescriptor);
        desc.fourcc = format;
        desc.width = width;
        desc.height = height;

        // Deduplicate fds into objects
        var num_objects: u32 = 0;
        var fd_to_obj: [4]u32 = .{ 0, 0, 0, 0 };
        for (0..n_planes) |i| {
            var found = false;
            for (0..num_objects) |j| {
                if (desc.objects[j].fd == fds[i]) {
                    fd_to_obj[i] = @intCast(j);
                    found = true;
                    break;
                }
            }
            if (!found) {
                fd_to_obj[i] = num_objects;
                desc.objects[num_objects] = .{
                    .fd = fds[i],
                    .size = strides[i] * height, // approximate
                    .drm_format_modifier = modifier,
                };
                num_objects += 1;
            }
        }
        desc.num_objects = num_objects;

        // Single layer with all planes
        desc.num_layers = 1;
        desc.layers[0].drm_format = format;
        desc.layers[0].num_planes = n_planes;
        for (0..n_planes) |i| {
            desc.layers[0].object_index[i] = fd_to_obj[i];
            desc.layers[0].offset[i] = offsets[i];
            desc.layers[0].pitch[i] = strides[i];
        }

        attrib_list[1] = .{
            .type = c.VASurfaceAttribExternalBufferDescriptor,
            .flags = c.VA_SURFACE_ATTRIB_SETTABLE,
            .value = .{ .type = c.VAGenericValueTypePointer, .value = .{ .p = @ptrCast(&desc) } },
        };

        log.debug("importDmaBuf: fd={d} format=0x{x} modifier=0x{x} planes={d} objects={d} size={d}x{d}", .{
            fds[0], format, modifier, n_planes, num_objects, width, height,
        });

        var surface: VASurfaceID = undefined;
        const status = c.vaCreateSurfaces(
            self.display,
            c.VA_RT_FORMAT_RGB32,
            width,
            height,
            &surface,
            1,
            &attrib_list,
            attrib_list.len,
        );
        if (status != c.VA_STATUS_SUCCESS) {
            log.err("vaCreateSurfaces (DMA-BUF import) failed: status={d} (VA_RT_FORMAT_RGB32, DRM_PRIME_2)", .{status});
            return error.VaapiImportFailed;
        }

        log.debug("imported DMA-BUF fd={d} as surface {d} ({d}x{d})", .{ fds[0], surface, width, height });
        return surface;
    }

    /// Destroy a surface previously created by importDmaBuf().
    pub fn destroyImportedSurface(self: *Vaapi, surface: *VASurfaceID) void {
        _ = c.vaDestroySurfaces(self.display, surface, 1);
    }

    /// Encode one frame from an externally-provided input surface (e.g. DMA-BUF import).
    /// The surface must contain RGB data compatible with the encoder.
    pub fn encodeImported(self: *Vaapi, input_surface: VASurfaceID, force_key: bool) !?EncodedFrame {
        const is_idr = isIdr(self.frame_count, self.idr_period, force_key);
        const poc: u32 = picOrderCount(self.frame_count);

        const recon = self.recon_surfaces[self.cur_recon];
        const ref_recon = self.recon_surfaces[self.cur_recon ^ 1];
        const ref_poc: u32 = if (self.frame_count > 0) picOrderCount(self.frame_count - 1) else 0;

        _ = c.vaSyncSurface(self.display, input_surface);

        if (c.vaBeginPicture(self.display, self.context, input_surface) != c.VA_STATUS_SUCCESS) {
            log.err("vaBeginPicture failed", .{});
            return error.VaapiEncodeFailed;
        }

        if (self.codec == .hevc) {
            try self.submitHevcParams(is_idr, poc, recon, ref_recon, ref_poc);
        }

        const end_status = c.vaEndPicture(self.display, self.context);
        if (end_status != c.VA_STATUS_SUCCESS) {
            log.err("vaEndPicture failed: status={d}", .{end_status});
            return error.VaapiEncodeFailed;
        }

        if (c.vaSyncSurface(self.display, input_surface) != c.VA_STATUS_SUCCESS) {
            log.err("vaSyncSurface failed", .{});
            return error.VaapiEncodeFailed;
        }

        return self.extractBitstream(is_idr);
    }

    /// Encode one frame. The current input surface must already contain RGB data
    /// (written by writeTestPattern or via exportSurface EGL interop).
    /// For DMA-BUF input from a compositor, use encodeImported() instead.
    pub fn encodeFrame(self: *Vaapi, force_key: bool) !?EncodedFrame {
        const is_idr = isIdr(self.frame_count, self.idr_period, force_key);
        const poc: u32 = picOrderCount(self.frame_count);

        const input = self.input_surfaces[self.cur_input];
        const recon = self.recon_surfaces[self.cur_recon];
        const ref_recon = self.recon_surfaces[self.cur_recon ^ 1];
        const ref_poc: u32 = if (self.frame_count > 0) picOrderCount(self.frame_count - 1) else 0;

        _ = c.vaSyncSurface(self.display, input);

        if (c.vaBeginPicture(self.display, self.context, input) != c.VA_STATUS_SUCCESS) {
            log.err("vaBeginPicture failed", .{});
            return error.VaapiEncodeFailed;
        }

        if (self.codec == .hevc) {
            try self.submitHevcParams(is_idr, poc, recon, ref_recon, ref_poc);
        }

        const end_status = c.vaEndPicture(self.display, self.context);
        if (end_status != c.VA_STATUS_SUCCESS) {
            log.err("vaEndPicture failed: status={d}", .{end_status});
            return error.VaapiEncodeFailed;
        }

        if (c.vaSyncSurface(self.display, input) != c.VA_STATUS_SUCCESS) {
            log.err("vaSyncSurface failed", .{});
            return error.VaapiEncodeFailed;
        }

        self.cur_input ^= 1;
        return self.extractBitstream(is_idr);
    }

    // ── Shared encode helpers ───────────────────────────────────────────

    /// Submit all HEVC encode parameters (seq/pic/packed headers/slice).
    fn submitHevcParams(self: *Vaapi, is_idr: bool, poc: u32, recon: VASurfaceID, ref_recon: VASurfaceID, ref_poc: u32) !void {
        const is_idr_int: c_int = @intFromBool(is_idr);

        if (is_idr) {
            const bitrate = targetBitrate(self.width, self.height, self.fps);
            const st = c.vaapi_submit_hevc_seq(self.display, self.context, self.width, self.height, self.fps, bitrate, self.idr_period);
            if (st != c.VA_STATUS_SUCCESS) {
                log.err("hevc seq failed: {d}", .{st});
                return error.VaapiEncodeFailed;
            }
        }

        var st = c.vaapi_submit_hevc_pic(self.display, self.context, recon, ref_recon, self.coded_buf, poc, is_idr_int);
        if (st != c.VA_STATUS_SUCCESS) {
            log.err("hevc pic failed: {d}", .{st});
            return error.VaapiEncodeFailed;
        }

        if (is_idr) {
            var vps_buf: [256]u8 = undefined;
            var sps_buf: [256]u8 = undefined;
            var pps_buf: [256]u8 = undefined;
            var vps_size: c_int = 0;
            var sps_size: c_int = 0;
            var pps_size: c_int = 0;

            _ = c.vaapi_generate_packed_headers(
                self.width, self.height, self.fps, self.idr_period,
                &vps_buf, 256, &vps_size,
                &sps_buf, 256, &sps_size,
                &pps_buf, 256, &pps_size,
            );

            st = c.vaapi_submit_packed_header(self.display, self.context, c.VAEncPackedHeaderSequence, &vps_buf, vps_size);
            if (st != c.VA_STATUS_SUCCESS) return error.VaapiEncodeFailed;
            st = c.vaapi_submit_packed_header(self.display, self.context, c.VAEncPackedHeaderSequence, &sps_buf, sps_size);
            if (st != c.VA_STATUS_SUCCESS) return error.VaapiEncodeFailed;
            st = c.vaapi_submit_packed_header(self.display, self.context, c.VAEncPackedHeaderSequence, &pps_buf, pps_size);
            if (st != c.VA_STATUS_SUCCESS) return error.VaapiEncodeFailed;
        }

        var slice_hdr_buf: [256]u8 = undefined;
        var slice_hdr_size: c_int = 0;
        _ = c.vaapi_generate_packed_slice_header(
            self.width, self.height, poc, is_idr_int,
            &slice_hdr_buf, 256, &slice_hdr_size,
        );
        if (c.vaapi_submit_packed_header(self.display, self.context, c.VAEncPackedHeaderSlice, &slice_hdr_buf, slice_hdr_size) != c.VA_STATUS_SUCCESS) {
            log.err("packed slice header failed", .{});
            return error.VaapiEncodeFailed;
        }

        st = c.vaapi_submit_hevc_slice(self.display, self.context, ref_recon, ref_poc, self.width, self.height, is_idr_int);
        if (st != c.VA_STATUS_SUCCESS) {
            log.err("hevc slice failed: {d}", .{st});
            return error.VaapiEncodeFailed;
        }
    }

    /// Map the coded buffer, extract bitstream, advance frame counters.
    fn extractBitstream(self: *Vaapi, is_idr: bool) !?EncodedFrame {
        var buf_ptr: ?*anyopaque = null;
        if (c.vaMapBuffer(self.display, self.coded_buf, &buf_ptr) != c.VA_STATUS_SUCCESS) {
            log.err("vaMapBuffer failed", .{});
            return error.VaapiEncodeFailed;
        }

        const segment: *const c.VACodedBufferSegment = @ptrCast(@alignCast(buf_ptr));
        if (segment.buf == null or segment.size == 0) {
            _ = c.vaUnmapBuffer(self.display, self.coded_buf);
            self.frame_count += 1;
            self.cur_recon ^= 1;
            return null;
        }

        self.bitstream_ptr = @ptrCast(segment.buf);
        self.bitstream_len = @intCast(segment.size);
        self.frame_count += 1;
        self.cur_recon ^= 1;

        return .{
            .data = self.bitstream_ptr.?[0..self.bitstream_len],
            .is_key = is_idr,
            .pts = 0,
        };
    }

    pub fn unlockBitstream(self: *Vaapi) void {
        _ = c.vaUnmapBuffer(self.display, self.coded_buf);
        self.bitstream_ptr = null;
        self.bitstream_len = 0;
    }

    pub fn deinit(self: *Vaapi) void {
        _ = c.vaDestroyBuffer(self.display, self.coded_buf);
        _ = c.vaDestroyContext(self.display, self.context);
        _ = c.vaDestroySurfaces(self.display, &self.input_surfaces, NUM_INPUT_SURFACES);
        _ = c.vaDestroySurfaces(self.display, &self.recon_surfaces, NUM_RECON_SURFACES);
        _ = c.vaDestroyConfig(self.display, self.config);
        _ = c.vaTerminate(self.display);
        _ = c.close(self.drm_fd);
        log.info("encoder destroyed", .{});
    }

    // ── Codec detection ──────────────────────────────────────────────────

    const CodecResult = struct {
        codec: Codec,
        profile: c.VAProfile,
        entrypoint: c.VAEntrypoint,
        low_power: bool,
    };

    fn detectCodec(display: VADisplay) ?CodecResult {
        if (probeCodec(display, c.VAProfileAV1Profile0, .av1)) |r| return r;
        if (probeCodec(display, c.VAProfileHEVCMain, .hevc)) |r| return r;
        return null;
    }

    fn probeCodec(display: VADisplay, profile: c.VAProfile, codec: Codec) ?CodecResult {
        var entrypoints: [16]c.VAEntrypoint = undefined;
        var num_ep: c_int = 0;
        if (c.vaQueryConfigEntrypoints(display, profile, &entrypoints, &num_ep) != c.VA_STATUS_SUCCESS) {
            return null;
        }

        for (entrypoints[0..@intCast(num_ep)]) |ep| {
            if (ep == c.VAEntrypointEncSlice) {
                return .{ .codec = codec, .profile = profile, .entrypoint = ep, .low_power = false };
            }
        }
        for (entrypoints[0..@intCast(num_ep)]) |ep| {
            if (ep == c.VAEntrypointEncSliceLP) {
                return .{ .codec = codec, .profile = profile, .entrypoint = ep, .low_power = true };
            }
        }
        return null;
    }
};

// ── Pure functions (unit-testable without VA-API hardware) ──────────────

/// Compute target bitrate from resolution and fps.
/// Formula: 90kbps base + 12 bits/pixel/frame, capped at 50Mbps.
pub fn targetBitrate(width: u32, height: u32, fps: u32) u32 {
    const pixels: u64 = @as(u64, width) * @as(u64, height);
    return @intCast(@min(90_000 + pixels * fps * 12 / 1000, 50_000_000));
}

/// Determine if a frame should be an IDR (instantaneous decoder refresh).
pub fn isIdr(frame_count: u64, idr_period: u32, force_key: bool) bool {
    return force_key or frame_count == 0 or
        (idr_period > 0 and frame_count % idr_period == 0);
}

/// Picture order count — wraps at 256 per HEVC spec.
pub fn picOrderCount(frame_count: u64) u32 {
    return @intCast(frame_count % 256);
}

/// Fill an RGB32 buffer with a synthetic test pattern (colored bars that shift per frame).
/// Pure function — operates on a raw pixel buffer, no VA-API dependency.
pub fn fillTestPattern(pixels: [*]u8, width: u32, height: u32, pitch: u32, frame_num: u64) void {
    const shift: u32 = @intCast(frame_num % width);
    for (0..height) |y| {
        const row = pixels + @as(usize, @intCast(y)) * pitch;
        for (0..width) |x| {
            const px = @as(u32, @intCast(x));
            const offset = @as(usize, px) * 4;
            // Vertical color bars that shift horizontally each frame
            const bar = ((px + shift) * 8 / width) % 8;
            // BGRX layout (VA-API RGB32 on Intel is typically BGRX)
            row[offset + 0] = if (bar & 1 != 0) 0xFF else 0x00; // B
            row[offset + 1] = if (bar & 2 != 0) 0xFF else 0x00; // G
            row[offset + 2] = if (bar & 4 != 0) 0xFF else 0x00; // R
            row[offset + 3] = 0xFF; // X
        }
    }
}

// ── Unit tests ──────────────────────────────────────────────────────────

test "targetBitrate 1080p30" {
    const br = targetBitrate(1920, 1080, 30);
    // 90_000 + (1920*1080) * 30 * 12 / 1000 = 90_000 + 746_496 = 836_496
    try std.testing.expectEqual(@as(u32, 836_496), br);
}

test "targetBitrate caps at 50Mbps" {
    const br = targetBitrate(7680, 4320, 120);
    try std.testing.expectEqual(@as(u32, 50_000_000), br);
}

test "isIdr first frame" {
    try std.testing.expect(isIdr(0, 120, false));
}

test "isIdr force key" {
    try std.testing.expect(isIdr(42, 120, true));
}

test "isIdr periodic" {
    try std.testing.expect(isIdr(120, 120, false));
    try std.testing.expect(!isIdr(119, 120, false));
}

test "isIdr idr_period zero disables periodic" {
    try std.testing.expect(!isIdr(100, 0, false));
    try std.testing.expect(isIdr(0, 0, false)); // first frame always IDR
}

test "picOrderCount wraps at 256" {
    try std.testing.expectEqual(@as(u32, 0), picOrderCount(0));
    try std.testing.expectEqual(@as(u32, 255), picOrderCount(255));
    try std.testing.expectEqual(@as(u32, 0), picOrderCount(256));
    try std.testing.expectEqual(@as(u32, 1), picOrderCount(257));
}

test "fillTestPattern does not crash" {
    var buf: [1920 * 4 * 2]u8 = undefined;
    fillTestPattern(&buf, 1920, 2, 1920 * 4, 0);
    // First pixel of bar 0 should be black (B=0,G=0,R=0,X=FF)
    try std.testing.expectEqual(@as(u8, 0x00), buf[0]); // B
    try std.testing.expectEqual(@as(u8, 0x00), buf[1]); // G
    try std.testing.expectEqual(@as(u8, 0x00), buf[2]); // R
    try std.testing.expectEqual(@as(u8, 0xFF), buf[3]); // X
}
