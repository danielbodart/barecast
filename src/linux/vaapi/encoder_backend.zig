const std = @import("std");
const VaapiEncoder = @import("vaapi").Vaapi;
const VASurfaceID = @import("vaapi").VASurfaceID;
const Codec = @import("codec").Codec;
const encoder = @import("encoder");

const log = std.log.scoped(.vaapi_backend);

/// DMA-BUF attributes for importing compositor frames as VA-API surfaces.
pub const DmaBufAttrs = struct {
    fd: i32,
    format: u32,
    modifier: u64,
    stride: u32,
    offset: u32,
    width: u32,
    height: u32,
};

/// VA-API hardware encoder backend (Intel QSV / AMD VCN).
/// Supports two input modes:
///   1. Self-allocated surfaces (writeTestPattern / exportSurface EGL interop)
///   2. DMA-BUF import (compositor frames — set pending_dmabuf before processFrame)
pub const EncoderBackend = struct {
    vaapi: VaapiEncoder,

    // DMA-BUF input mode: set by caller before each processFrame()
    pending_dmabuf: ?DmaBufAttrs = null,
    imported_surface: ?VASurfaceID = null,

    // Cache of imported surfaces (wlroots swapchain reuses ~2-3 fds)
    surface_cache: [MAX_CACHED]CacheEntry = [_]CacheEntry{.{}} ** MAX_CACHED,

    cache_generation: u32 = 0,

    const MAX_CACHED = 4;
    const CacheEntry = struct {
        fd: i32 = -1,
        surface: VASurfaceID = 0,
        use_count: u32 = 0,
    };

    pub fn init(render_path: [*:0]const u8, width: u32, height: u32, fps: u32) !EncoderBackend {
        var enc = try VaapiEncoder.init(render_path, width, height, fps);
        errdefer enc.deinit();

        return .{ .vaapi = enc };
    }

    pub fn codec(self: *const EncoderBackend) Codec {
        return self.vaapi.codec;
    }

    pub fn exportSurface(self: *EncoderBackend) !@import("vaapi").ExportedSurface {
        return self.vaapi.exportSurface();
    }

    /// Return an EncodeBackend vtable pointing to this instance.
    pub fn backend(self: *EncoderBackend) encoder.EncodeBackend {
        return .{
            .ptr = @ptrCast(self),
            .codec = self.vaapi.codec,
            .prepareFn = @ptrCast(&prepareFn),
            .encodeFn = @ptrCast(&encodeFn),
            .unlockFn = @ptrCast(&unlockFn),
            .deinitFn = @ptrCast(&deinitFn),
        };
    }

    fn prepareFn(self: *EncoderBackend) !void {
        const dmabuf = self.pending_dmabuf orelse return; // no-op in self-allocated mode

        // Look up or import the DMA-BUF surface
        self.imported_surface = self.lookupOrImport(dmabuf) catch |err| {
            log.err("DMA-BUF import failed: {}", .{err});
            return err;
        };
    }

    fn encodeFn(self: *EncoderBackend, force_key: bool) !?encoder.EncodedFrame {
        const result = if (self.imported_surface) |surface|
            try self.vaapi.encodeImported(surface, force_key)
        else
            try self.vaapi.encodeFrame(force_key);

        self.imported_surface = null;
        self.pending_dmabuf = null;

        if (result) |frame| {
            return .{
                .data = frame.data,
                .is_key = frame.is_key,
                .pts = frame.pts,
            };
        }
        return null;
    }

    fn unlockFn(self: *EncoderBackend) void {
        self.vaapi.unlockBitstream();
    }

    fn deinitFn(self: *EncoderBackend) void {
        // Destroy cached imported surfaces
        for (&self.surface_cache) |*entry| {
            if (entry.fd >= 0) {
                self.vaapi.destroyImportedSurface(&entry.surface);
                entry.fd = -1;
            }
        }
        self.vaapi.deinit();
    }

    // ── Surface cache ───────────────────────────────────────────────

    fn lookupOrImport(self: *EncoderBackend, dmabuf: DmaBufAttrs) !VASurfaceID {
        self.cache_generation +%= 1;

        // Check cache
        for (&self.surface_cache) |*entry| {
            if (entry.fd == dmabuf.fd) {
                entry.use_count = self.cache_generation;
                return entry.surface;
            }
        }

        // Import new surface
        const surface = try self.vaapi.importDmaBuf(
            dmabuf.fd,
            dmabuf.format,
            dmabuf.modifier,
            dmabuf.stride,
            dmabuf.offset,
            dmabuf.width,
            dmabuf.height,
        );

        // Find slot: prefer empty, then evict least-recently-used
        var evict_idx: usize = 0;
        var oldest: u32 = std.math.maxInt(u32);
        for (self.surface_cache, 0..) |entry, i| {
            if (entry.fd < 0) {
                evict_idx = i;
                oldest = 0;
                break;
            }
            if (entry.use_count < oldest) {
                oldest = entry.use_count;
                evict_idx = i;
            }
        }

        if (self.surface_cache[evict_idx].fd >= 0) {
            log.debug("evicting cached surface fd={d}", .{self.surface_cache[evict_idx].fd});
            self.vaapi.destroyImportedSurface(&self.surface_cache[evict_idx].surface);
        }

        self.surface_cache[evict_idx] = .{ .fd = dmabuf.fd, .surface = surface, .use_count = self.cache_generation };
        return surface;
    }
};
