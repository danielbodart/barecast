const std = @import("std");
const posix = std.posix;
const Codec = @import("codec").Codec;

const log = std.log.scoped(.gpu_detect);

// ── Public types ────────────────────────────────────────────────────────

pub const GpuVendor = enum {
    nvidia,
    intel,
    amd,
    unknown,

    pub fn name(self: GpuVendor) []const u8 {
        return switch (self) {
            .nvidia => "NVIDIA",
            .intel => "Intel",
            .amd => "AMD",
            .unknown => "unknown",
        };
    }

    /// Vendor preference for tie-breaking when codec support is equal.
    fn priority(self: GpuVendor) u8 {
        return switch (self) {
            .nvidia => 3,
            .intel => 2,
            .amd => 1,
            .unknown => 0,
        };
    }
};

pub const GpuCandidate = struct {
    render_node: [32]u8,
    render_node_len: u8,
    vendor: GpuVendor,
    best_codec: ?Codec, // null = no encode support detected
    has_av1: bool,
    has_hevc: bool,

    pub fn renderPath(self: *const GpuCandidate) [*:0]const u8 {
        return @ptrCast(self.render_node[0..self.render_node_len]);
    }

    /// Score for ranking: AV1 > HEVC > nothing, then vendor priority.
    fn score(self: *const GpuCandidate) u16 {
        const codec_score: u16 = if (self.has_av1) 200 else if (self.has_hevc) 100 else 0;
        return codec_score + self.vendor.priority();
    }
};

pub const DetectResult = struct {
    candidates: [MAX_GPUS]GpuCandidate,
    count: u8,

    pub fn best(self: *const DetectResult) ?*const GpuCandidate {
        if (self.count == 0) return null;
        return &self.candidates[0]; // already sorted by score
    }
};

const MAX_GPUS = 8;

// ── Main entry point ────────────────────────────────────────────────────

/// Detect all GPUs with hardware encode capability, sorted best-first.
/// AV1 beats HEVC; among equal codecs, NVIDIA > Intel > AMD.
pub fn detectGpus() DetectResult {
    var result = DetectResult{ .candidates = undefined, .count = 0 };

    // Enumerate render nodes via sysfs
    var nodes: [MAX_GPUS]RenderNode = undefined;
    const node_count = enumerateRenderNodes(&nodes);

    for (nodes[0..node_count]) |node| {
        if (result.count >= MAX_GPUS) break;

        var candidate = GpuCandidate{
            .render_node = undefined,
            .render_node_len = node.path_len,
            .vendor = node.vendor,
            .best_codec = null,
            .has_av1 = false,
            .has_hevc = false,
        };
        @memcpy(candidate.render_node[0..node.path_len], node.path[0..node.path_len]);
        candidate.render_node[node.path_len] = 0; // null terminate

        // Probe encode capabilities based on vendor
        switch (node.vendor) {
            .nvidia => probeNvenc(&candidate),
            .intel, .amd => probeVaapi(&candidate),
            .unknown => {},
        }

        if (candidate.has_av1) {
            candidate.best_codec = .av1;
        } else if (candidate.has_hevc) {
            candidate.best_codec = .hevc;
        }

        const vendor_name = node.vendor.name();
        if (candidate.best_codec) |codec| {
            log.info("{s} @ {s}: {s} encode supported", .{
                vendor_name,
                candidate.render_node[0..candidate.render_node_len],
                codec.name(),
            });
        } else {
            log.info("{s} @ {s}: no encode support", .{
                vendor_name,
                candidate.render_node[0..candidate.render_node_len],
            });
        }

        result.candidates[result.count] = candidate;
        result.count += 1;
    }

    // Sort by score descending (best first)
    sortCandidates(result.candidates[0..result.count]);

    if (result.count > 0) {
        const b = result.candidates[0];
        if (b.best_codec) |codec| {
            log.info("selected: {s} {s} @ {s}", .{
                b.vendor.name(), codec.name(),
                b.render_node[0..b.render_node_len],
            });
        }
    } else {
        log.warn("no GPUs with encode support found", .{});
    }

    return result;
}

// ── Render node enumeration via sysfs ───────────────────────────────────

const RenderNode = struct {
    path: [32]u8, // "/dev/dri/renderDNNN"
    path_len: u8,
    vendor: GpuVendor,
};

fn enumerateRenderNodes(out: *[MAX_GPUS]RenderNode) usize {
    var count: usize = 0;

    // Scan renderD128..renderD143 (covers typical systems)
    for (128..144) |n| {
        if (count >= MAX_GPUS) break;

        var path_buf: [32]u8 = [_]u8{0} ** 32;
        const path = std.fmt.bufPrint(&path_buf, "/dev/dri/renderD{d}", .{n}) catch continue;

        // Check if render node exists
        posix.access(path, posix.F_OK) catch continue;

        // Read PCI vendor from sysfs
        var sysfs_buf: [64]u8 = undefined;
        const sysfs_path = std.fmt.bufPrint(&sysfs_buf, "/sys/class/drm/renderD{d}/device/vendor", .{n}) catch continue;

        const vendor = readSysfsVendor(sysfs_path) orelse continue;

        out[count] = .{
            .path = path_buf,
            .path_len = @intCast(path.len),
            .vendor = vendor,
        };
        count += 1;
    }

    return count;
}

fn readSysfsVendor(path: []const u8) ?GpuVendor {
    var path_z: [128]u8 = undefined;
    if (path.len >= path_z.len) return null;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const fd = posix.open(@ptrCast(path_z[0..path.len :0]), .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer posix.close(fd);

    var buf: [16]u8 = undefined;
    const n = posix.read(fd, &buf) catch return null;
    if (n < 4) return null;

    // Parse "0x10de\n" → vendor id
    const trimmed = std.mem.trimRight(u8, buf[0..n], &.{ '\n', ' ' });
    const hex = if (std.mem.startsWith(u8, trimmed, "0x")) trimmed[2..] else trimmed;
    const vendor_id = std.fmt.parseInt(u16, hex, 16) catch return null;

    return switch (vendor_id) {
        0x10de => .nvidia,
        0x8086 => .intel,
        0x1002 => .amd,
        else => .unknown,
    };
}

// ── NVENC probe (CUDA + NVENC GUID enumeration) ─────────────────────────

fn probeNvenc(candidate: *GpuCandidate) void {
    // Use the Nvenc module's types for the probe. We create a minimal CUDA
    // context (no GL needed) and open an NVENC session to enumerate codecs.
    const nvenc = @import("nvenc");

    // Minimal CUDA context — just enough for NVENC to open a session.
    // No GL textures, no buffers — pure CUDA driver API.
    const cuda_lib = std.c.dlopen("libcuda.so.1", .{ .LAZY = true }) orelse blk: {
        break :blk std.c.dlopen("libcuda.so", .{ .LAZY = true }) orelse {
            log.debug("NVENC probe: libcuda not found", .{});
            return;
        };
    };
    defer _ = std.c.dlclose(cuda_lib);

    const CuInitFn = *const fn (u32) callconv(.c) c_int;
    const CuDeviceGetFn = *const fn (*c_int, c_int) callconv(.c) c_int;
    const CuCtxCreateFn = *const fn (*?*anyopaque, u32, c_int) callconv(.c) c_int;
    const CuCtxDestroyFn = *const fn (*anyopaque) callconv(.c) c_int;

    const cuInit = dlsym(CuInitFn, cuda_lib, "cuInit") orelse return;
    const cuDeviceGet = dlsym(CuDeviceGetFn, cuda_lib, "cuDeviceGet") orelse return;
    const cuCtxCreate = dlsym(CuCtxCreateFn, cuda_lib, "cuCtxCreate_v2") orelse return;
    const cuCtxDestroy = dlsym(CuCtxDestroyFn, cuda_lib, "cuCtxDestroy_v2") orelse return;

    if (cuInit(0) != 0) { log.debug("NVENC probe: cuInit failed", .{}); return; }

    var device: c_int = 0;
    if (cuDeviceGet(&device, 0) != 0) { log.debug("NVENC probe: cuDeviceGet failed", .{}); return; }

    var ctx: ?*anyopaque = null;
    if (cuCtxCreate(&ctx, 0, device) != 0 or ctx == null) { log.debug("NVENC probe: cuCtxCreate failed", .{}); return; }
    defer _ = cuCtxDestroy(ctx.?);

    // Now use the real Nvenc module to probe codecs. We create a minimal
    // "cuda-like" struct with just the fields Nvenc.init reads.
    // Nvenc.init takes *const cuda.Cuda and reads: .ctx, .frame_width, .frame_height,
    // .device_ptr, .device_pitch. For probing we only need the session+GUIDs,
    // but Nvenc.init also registers a resource. So we'll probe at a lower level.

    // dlopen libnvidia-encode and use the Nvenc types directly
    const nvenc_lib = std.c.dlopen("libnvidia-encode.so.1", .{ .LAZY = true }) orelse {
        log.debug("NVENC probe: libnvidia-encode not found", .{});
        return;
    };
    defer _ = std.c.dlclose(nvenc_lib);

    const create_sym = std.c.dlsym(nvenc_lib, "NvEncodeAPICreateInstance") orelse return;
    const createInstance: nvenc.CreateInstanceFn = @ptrCast(create_sym);

    var fns = nvenc.ApiFunctionList{};
    if (createInstance(&fns) != .success) {
        log.debug("NVENC probe: NvEncodeAPICreateInstance failed", .{});
        return;
    }

    // Open encode session with our CUDA context
    var session_params = nvenc.OpenEncodeSessionExParams{ .device = ctx };
    var encoder_handle: ?*anyopaque = null;
    const openSession = fns.nvEncOpenEncodeSessionEx orelse return;
    const status = openSession(&session_params, &encoder_handle);
    if (status != .success or encoder_handle == null) {
        log.debug("NVENC probe: nvEncOpenEncodeSessionEx failed ({d})", .{@intFromEnum(status)});
        return;
    }
    const destroyFn = fns.nvEncDestroyEncoder orelse return;
    defer _ = destroyFn(encoder_handle);

    // Enumerate codec GUIDs
    const getCount = fns.nvEncGetEncodeGUIDCount orelse return;
    const getGUIDs = fns.nvEncGetEncodeGUIDs orelse return;

    var guid_count: u32 = 0;
    if (getCount(encoder_handle, &guid_count) != .success) return;

    var guids: [16]nvenc.Guid = undefined;
    var returned: u32 = 0;
    if (getGUIDs(encoder_handle, &guids, @min(guid_count, 16), &returned) != .success) return;

    for (guids[0..returned]) |guid| {
        if (guidEql(guid, nvenc.codec_av1_guid)) candidate.has_av1 = true;
        if (guidEql(guid, nvenc.codec_hevc_guid)) candidate.has_hevc = true;
    }
}

fn guidEql(a: anytype, b: anytype) bool {
    return a.data1 == b.data1 and a.data2 == b.data2 and a.data3 == b.data3 and std.mem.eql(u8, &a.data4, &b.data4);
}

// ── VA-API probe ────────────────────────────────────────────────────────

fn probeVaapi(candidate: *GpuCandidate) void {
    const va_lib = std.c.dlopen("libva.so.2", .{ .LAZY = true }) orelse return;
    defer _ = std.c.dlclose(va_lib);

    const va_drm_lib = std.c.dlopen("libva-drm.so.2", .{ .LAZY = true }) orelse return;
    defer _ = std.c.dlclose(va_drm_lib);

    const VADisplay = ?*anyopaque;
    const VAStatus = c_int;
    const VA_STATUS_SUCCESS: c_int = 0;

    const vaGetDisplayDRM = dlsym(*const fn (c_int) callconv(.c) VADisplay, va_drm_lib, "vaGetDisplayDRM") orelse return;
    const vaInitialize = dlsym(*const fn (VADisplay, *c_int, *c_int) callconv(.c) VAStatus, va_lib, "vaInitialize") orelse return;
    const vaTerminate = dlsym(*const fn (VADisplay) callconv(.c) VAStatus, va_lib, "vaTerminate") orelse return;
    const vaQueryConfigEntrypoints = dlsym(
        *const fn (VADisplay, c_int, [*]c_int, *c_int) callconv(.c) VAStatus,
        va_lib,
        "vaQueryConfigEntrypoints",
    ) orelse return;

    // Open the render node
    const path = candidate.render_node[0..candidate.render_node_len];
    const fd = posix.open(path, .{ .ACCMODE = .RDWR }, 0) catch return;
    defer posix.close(fd);

    const display = vaGetDisplayDRM(@intCast(fd));
    if (display == null) return;

    var major: c_int = 0;
    var minor: c_int = 0;
    if (vaInitialize(display, &major, &minor) != VA_STATUS_SUCCESS) return;
    defer _ = vaTerminate(display);

    // VA-API profile constants
    const VAProfileAV1Profile0: c_int = 32;
    const VAProfileHEVCMain: c_int = 17;
    const VAEntrypointEncSlice: c_int = 6;
    const VAEntrypointEncSliceLP: c_int = 8;

    // Probe AV1
    if (hasEncodeEntrypoint(vaQueryConfigEntrypoints, display, VAProfileAV1Profile0, VAEntrypointEncSlice, VAEntrypointEncSliceLP)) {
        candidate.has_av1 = true;
    }

    // Probe HEVC
    if (hasEncodeEntrypoint(vaQueryConfigEntrypoints, display, VAProfileHEVCMain, VAEntrypointEncSlice, VAEntrypointEncSliceLP)) {
        candidate.has_hevc = true;
    }
}

fn hasEncodeEntrypoint(
    queryFn: *const fn (?*anyopaque, c_int, [*]c_int, *c_int) callconv(.c) c_int,
    display: ?*anyopaque,
    profile: c_int,
    enc_slice: c_int,
    enc_slice_lp: c_int,
) bool {
    var entrypoints: [16]c_int = undefined;
    var num_ep: c_int = 0;
    if (queryFn(display, profile, &entrypoints, &num_ep) != 0) return false;

    for (entrypoints[0..@intCast(num_ep)]) |ep| {
        if (ep == enc_slice or ep == enc_slice_lp) return true;
    }
    return false;
}

// ── Helpers ─────────────────────────────────────────────────────────────

fn dlsym(comptime T: type, lib: *anyopaque, name: [*:0]const u8) ?T {
    const sym = std.c.dlsym(lib, name) orelse return null;
    return @ptrCast(sym);
}

fn sortCandidates(items: []GpuCandidate) void {
    // Simple insertion sort — at most 8 items
    for (1..items.len) |i| {
        const key = items[i];
        const key_score = key.score();
        var j: usize = i;
        while (j > 0 and items[j - 1].score() < key_score) {
            items[j] = items[j - 1];
            j -= 1;
        }
        items[j] = key;
    }
}

// ── Tests ────────────────────────────────────────────────────────────────

fn testCandidate(vendor: GpuVendor, av1: bool, hevc: bool) GpuCandidate {
    return .{
        .render_node = [_]u8{0} ** 32,
        .render_node_len = 0,
        .vendor = vendor,
        .best_codec = if (av1) .av1 else if (hevc) .hevc else null,
        .has_av1 = av1,
        .has_hevc = hevc,
    };
}

test "score: AV1 > HEVC > none" {
    const av1 = testCandidate(.nvidia, true, true);
    const hevc = testCandidate(.nvidia, false, true);
    const none = testCandidate(.nvidia, false, false);
    try std.testing.expect(av1.score() > hevc.score());
    try std.testing.expect(hevc.score() > none.score());
}

test "score: vendor priority breaks ties" {
    const nvidia_hevc = testCandidate(.nvidia, false, true);
    const intel_hevc = testCandidate(.intel, false, true);
    const amd_hevc = testCandidate(.amd, false, true);
    try std.testing.expect(nvidia_hevc.score() > intel_hevc.score());
    try std.testing.expect(intel_hevc.score() > amd_hevc.score());
}

test "score: AV1 on weaker vendor beats HEVC on stronger" {
    const amd_av1 = testCandidate(.amd, true, true);
    const nvidia_hevc = testCandidate(.nvidia, false, true);
    try std.testing.expect(amd_av1.score() > nvidia_hevc.score());
}

test "sortCandidates: best first" {
    var items = [_]GpuCandidate{
        testCandidate(.intel, false, true), // HEVC intel = 102
        testCandidate(.nvidia, true, true), // AV1 nvidia = 203
        testCandidate(.amd, false, false), // none amd = 1
    };
    sortCandidates(&items);
    try std.testing.expectEqual(GpuVendor.nvidia, items[0].vendor);
    try std.testing.expectEqual(GpuVendor.intel, items[1].vendor);
    try std.testing.expectEqual(GpuVendor.amd, items[2].vendor);
}

test "sortCandidates: single element" {
    var single = [_]GpuCandidate{testCandidate(.nvidia, true, true)};
    sortCandidates(&single);
    try std.testing.expectEqual(GpuVendor.nvidia, single[0].vendor);
}

test "vendor priority ordering" {
    try std.testing.expect(GpuVendor.nvidia.priority() > GpuVendor.intel.priority());
    try std.testing.expect(GpuVendor.intel.priority() > GpuVendor.amd.priority());
    try std.testing.expect(GpuVendor.amd.priority() > GpuVendor.unknown.priority());
}
