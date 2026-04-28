const std = @import("std");

// ============================================================================
// CUDA type definitions (pure Zig, matching CUDA Driver API)
// ============================================================================

pub const CUresult = c_int;
pub const CUdevice = c_int;
pub const CUcontext = *opaque {};
pub const CUstream = ?*opaque {};
pub const CUarray = *opaque {};
pub const CUgraphicsResource = *opaque {};
pub const CUdeviceptr = u64;

pub const CUDA_SUCCESS: CUresult = 0;

const CU_CTX_SCHED_AUTO: u32 = 0;
const CU_GRAPHICS_REGISTER_FLAGS_READ_ONLY: u32 = 0x01;
const CU_GRAPHICS_MAP_RESOURCE_FLAGS_READ_ONLY: u32 = 0x01;
const CU_MEMORYTYPE_ARRAY: u32 = 0x03;
const CU_MEMORYTYPE_DEVICE: u32 = 0x02;

const GL_TEXTURE_2D: u32 = 0x0DE1;
const GL_RGBA8: u32 = 0x8058;
const GL_FRAMEBUFFER: u32 = 0x8D40;
const GL_READ_FRAMEBUFFER: u32 = 0x8CA8;
const GL_DRAW_FRAMEBUFFER: u32 = 0x8CA9;
const GL_COLOR_ATTACHMENT0: u32 = 0x8CE0;
const GL_COLOR_BUFFER_BIT: u32 = 0x00004000;
const GL_NEAREST: u32 = 0x2600;
const GL_FRAMEBUFFER_COMPLETE: u32 = 0x8CD5;

const log = std.log.scoped(.wayland_cuda);

pub const Memcpy2D = extern struct {
    srcXInBytes: usize = 0,
    srcY: usize = 0,
    srcMemoryType: u32,
    srcHost: ?*const anyopaque = null,
    srcDevice: CUdeviceptr = 0,
    srcArray: ?*anyopaque = null,
    srcPitch: usize = 0,
    dstXInBytes: usize = 0,
    dstY: usize = 0,
    dstMemoryType: u32,
    dstHost: ?*anyopaque = null,
    dstDevice: CUdeviceptr = 0,
    dstArray: ?*anyopaque = null,
    dstPitch: usize = 0,
    WidthInBytes: usize,
    Height: usize,
};

// ============================================================================
// CUDA function pointer types
// ============================================================================

const InitFn = *const fn (u32) callconv(.c) CUresult;
const DeviceGetCountFn = *const fn (*c_int) callconv(.c) CUresult;
const DeviceGetFn = *const fn (*CUdevice, c_int) callconv(.c) CUresult;
const CtxCreateFn = *const fn (*?CUcontext, u32, CUdevice) callconv(.c) CUresult;
const CtxDestroyFn = *const fn (CUcontext) callconv(.c) CUresult;
const GetErrorStringFn = *const fn (CUresult, *?[*:0]const u8) callconv(.c) CUresult;
const MemAllocPitchFn = *const fn (*CUdeviceptr, *usize, usize, usize, u32) callconv(.c) CUresult;
const MemFreeFn = *const fn (CUdeviceptr) callconv(.c) CUresult;
const Memcpy2DFn = *const fn (*const Memcpy2D) callconv(.c) CUresult;
const GraphicsGLRegisterImageFn = *const fn (*?*anyopaque, u32, u32, u32) callconv(.c) CUresult;
const GraphicsResourceSetMapFlagsFn = *const fn (*anyopaque, u32) callconv(.c) CUresult;
const GraphicsMapResourcesFn = *const fn (u32, *?*anyopaque, CUstream) callconv(.c) CUresult;
const GraphicsUnmapResourcesFn = *const fn (u32, *?*anyopaque, CUstream) callconv(.c) CUresult;
const GraphicsUnregisterResourceFn = *const fn (*anyopaque) callconv(.c) CUresult;
const GraphicsSubResourceGetMappedArrayFn = *const fn (*?*anyopaque, *anyopaque, u32, u32) callconv(.c) CUresult;

// ============================================================================
// GL function pointer types (resolved via dlsym from libGLESv2)
// ============================================================================

const GlGenTexturesFn = *const fn (c_int, *u32) callconv(.c) void;
const GlDeleteTexturesFn = *const fn (c_int, *const u32) callconv(.c) void;
const GlBindTextureFn = *const fn (u32, u32) callconv(.c) void;
const GlTexStorage2DFn = *const fn (u32, c_int, u32, c_int, c_int) callconv(.c) void;
const GlGenFramebuffersFn = *const fn (c_int, *u32) callconv(.c) void;
const GlDeleteFramebuffersFn = *const fn (c_int, *const u32) callconv(.c) void;
const GlBindFramebufferFn = *const fn (u32, u32) callconv(.c) void;
const GlFramebufferTexture2DFn = *const fn (u32, u32, u32, u32, c_int) callconv(.c) void;
const GlCheckFramebufferStatusFn = *const fn (u32) callconv(.c) u32;
const GlBlitFramebufferFn = *const fn (c_int, c_int, c_int, c_int, c_int, c_int, c_int, c_int, u32, u32) callconv(.c) void;
const GlFlushFn = *const fn () callconv(.c) void;

// ============================================================================
// CUDA context + GL texture interop
// ============================================================================

pub const Cuda = struct {
    lib: *anyopaque,
    gl_lib: *anyopaque,
    ctx: CUcontext,
    device_ptr: CUdeviceptr,
    device_pitch: usize,
    device_size: usize,
    frame_width: u32,
    frame_height: u32,

    // Our GL texture + FBO for blitting from wlroots' FBO
    blit_texture: u32,
    blit_fbo: u32,

    // CUDA graphics resource for the blit texture (registered once)
    graphics_resource: ?*anyopaque,

    // GL function pointers
    glBindFramebuffer: GlBindFramebufferFn,
    glBlitFramebuffer: GlBlitFramebufferFn,
    glFlush: GlFlushFn,

    // CUDA function pointers
    cuGetErrorString: GetErrorStringFn,
    cuCtxDestroy_v2: CtxDestroyFn,
    cuMemAllocPitch: MemAllocPitchFn,
    cuMemFree_v2: MemFreeFn,
    cuMemcpy2D_v2: Memcpy2DFn,
    cuGraphicsGLRegisterImage: GraphicsGLRegisterImageFn,
    cuGraphicsResourceSetMapFlags: GraphicsResourceSetMapFlagsFn,
    cuGraphicsMapResources: GraphicsMapResourcesFn,
    cuGraphicsUnmapResources: GraphicsUnmapResourcesFn,
    cuGraphicsUnregisterResource: GraphicsUnregisterResourceFn,
    cuGraphicsSubResourceGetMappedArray: GraphicsSubResourceGetMappedArrayFn,

    /// Initialize CUDA context, GL blit texture, and pitched BGRA device buffer.
    /// Must be called while the wlroots EGL/GL context is current on this thread.
    pub fn init(width: u32, height: u32) !Cuda {
        // ── Load GL functions ──────────────────────────────────────────
        const gl_lib = std.c.dlopen("libGLESv2.so.2", .{ .LAZY = true }) orelse blk: {
            break :blk std.c.dlopen("libGLESv2.so", .{ .LAZY = true }) orelse {
                log.err("failed to load libGLESv2.so", .{});
                return error.GlInitFailed;
            };
        };
        errdefer _ = std.c.dlclose(gl_lib);

        const glGenTextures = resolveGL(GlGenTexturesFn, gl_lib, "glGenTextures") orelse return error.GlInitFailed;
        const glBindTexture = resolveGL(GlBindTextureFn, gl_lib, "glBindTexture") orelse return error.GlInitFailed;
        const glTexStorage2D = resolveGL(GlTexStorage2DFn, gl_lib, "glTexStorage2D") orelse return error.GlInitFailed;
        const glGenFramebuffers = resolveGL(GlGenFramebuffersFn, gl_lib, "glGenFramebuffers") orelse return error.GlInitFailed;
        const glBindFramebuffer = resolveGL(GlBindFramebufferFn, gl_lib, "glBindFramebuffer") orelse return error.GlInitFailed;
        const glFramebufferTexture2D = resolveGL(GlFramebufferTexture2DFn, gl_lib, "glFramebufferTexture2D") orelse return error.GlInitFailed;
        const glCheckFramebufferStatus = resolveGL(GlCheckFramebufferStatusFn, gl_lib, "glCheckFramebufferStatus") orelse return error.GlInitFailed;
        const glBlitFramebuffer = resolveGL(GlBlitFramebufferFn, gl_lib, "glBlitFramebuffer") orelse return error.GlInitFailed;
        const glFlush = resolveGL(GlFlushFn, gl_lib, "glFlush") orelse return error.GlInitFailed;

        // ── Create GL texture + FBO for blit target ────────────────────
        // glTexStorage2D creates immutable storage — required for cuGraphicsGLRegisterImage
        var blit_texture: u32 = 0;
        glGenTextures(1, &blit_texture);
        glBindTexture(GL_TEXTURE_2D, blit_texture);
        glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, @intCast(width), @intCast(height));
        glBindTexture(GL_TEXTURE_2D, 0);

        var blit_fbo: u32 = 0;
        glGenFramebuffers(1, &blit_fbo);
        glBindFramebuffer(GL_FRAMEBUFFER, blit_fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, blit_texture, 0);

        const fb_status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);

        if (fb_status != GL_FRAMEBUFFER_COMPLETE) {
            log.err("blit FBO incomplete: 0x{x}", .{fb_status});
            return error.GlInitFailed;
        }

        log.info("GL blit texture={d} fbo={d} ({d}x{d} RGBA8)", .{ blit_texture, blit_fbo, width, height });

        // ── Load CUDA ──────────────────────────────────────────────────
        const lib = std.c.dlopen("libcuda.so.1", .{ .LAZY = true }) orelse blk: {
            break :blk std.c.dlopen("libcuda.so", .{ .LAZY = true }) orelse {
                log.err("failed to load libcuda.so", .{});
                return error.CudaInitFailed;
            };
        };
        errdefer _ = std.c.dlclose(lib);

        const cuInit = resolve(InitFn, lib, "cuInit") orelse return error.CudaInitFailed;
        const cuDeviceGetCount = resolve(DeviceGetCountFn, lib, "cuDeviceGetCount") orelse return error.CudaInitFailed;
        const cuDeviceGet = resolve(DeviceGetFn, lib, "cuDeviceGet") orelse return error.CudaInitFailed;
        const cuCtxCreate = resolve(CtxCreateFn, lib, "cuCtxCreate_v2") orelse return error.CudaInitFailed;
        const cuCtxDestroy = resolve(CtxDestroyFn, lib, "cuCtxDestroy_v2") orelse return error.CudaInitFailed;
        const cuGetErrorString = resolve(GetErrorStringFn, lib, "cuGetErrorString") orelse return error.CudaInitFailed;
        const cuMemAllocPitch = resolve(MemAllocPitchFn, lib, "cuMemAllocPitch_v2") orelse return error.CudaInitFailed;
        const cuMemFree = resolve(MemFreeFn, lib, "cuMemFree_v2") orelse return error.CudaInitFailed;
        const cuMemcpy2D = resolve(Memcpy2DFn, lib, "cuMemcpy2D_v2") orelse return error.CudaInitFailed;
        const cuGraphicsGLRegisterImage = resolve(GraphicsGLRegisterImageFn, lib, "cuGraphicsGLRegisterImage") orelse return error.CudaInitFailed;
        const cuGraphicsResourceSetMapFlags = resolve(GraphicsResourceSetMapFlagsFn, lib, "cuGraphicsResourceSetMapFlags") orelse return error.CudaInitFailed;
        const cuGraphicsMapResources = resolve(GraphicsMapResourcesFn, lib, "cuGraphicsMapResources") orelse return error.CudaInitFailed;
        const cuGraphicsUnmapResources = resolve(GraphicsUnmapResourcesFn, lib, "cuGraphicsUnmapResources") orelse return error.CudaInitFailed;
        const cuGraphicsUnregisterResource = resolve(GraphicsUnregisterResourceFn, lib, "cuGraphicsUnregisterResource") orelse return error.CudaInitFailed;
        const cuGraphicsSubResourceGetMappedArray = resolve(GraphicsSubResourceGetMappedArrayFn, lib, "cuGraphicsSubResourceGetMappedArray") orelse return error.CudaInitFailed;

        // ── Init CUDA ──────────────────────────────────────────────────
        var res = cuInit(0);
        if (res != CUDA_SUCCESS) {
            logCudaError(cuGetErrorString, res, "cuInit");
            return error.CudaInitFailed;
        }

        var device_count: c_int = 0;
        res = cuDeviceGetCount(&device_count);
        if (res != CUDA_SUCCESS or device_count <= 0) {
            log.err("no CUDA devices found", .{});
            return error.CudaInitFailed;
        }

        var device: CUdevice = 0;
        res = cuDeviceGet(&device, 0);
        if (res != CUDA_SUCCESS) {
            logCudaError(cuGetErrorString, res, "cuDeviceGet");
            return error.CudaInitFailed;
        }

        var ctx: ?CUcontext = null;
        res = cuCtxCreate(&ctx, CU_CTX_SCHED_AUTO, device);
        if (res != CUDA_SUCCESS or ctx == null) {
            logCudaError(cuGetErrorString, res, "cuCtxCreate_v2");
            return error.CudaInitFailed;
        }
        errdefer _ = cuCtxDestroy(ctx.?);

        // Allocate pitched BGRA device buffer for NVENC input
        var device_ptr: CUdeviceptr = 0;
        var pitch: usize = 0;
        res = cuMemAllocPitch(&device_ptr, &pitch, @as(usize, width) * 4, height, 16);
        if (res != CUDA_SUCCESS) {
            logCudaError(cuGetErrorString, res, "cuMemAllocPitch_v2");
            return error.CudaInitFailed;
        }
        errdefer _ = cuMemFree(device_ptr);

        // ── Register the blit texture with CUDA ────────────────────────
        var graphics_resource: ?*anyopaque = null;
        res = cuGraphicsGLRegisterImage(&graphics_resource, blit_texture, GL_TEXTURE_2D, CU_GRAPHICS_REGISTER_FLAGS_READ_ONLY);
        if (res != CUDA_SUCCESS) {
            logCudaError(cuGetErrorString, res, "cuGraphicsGLRegisterImage(GL_TEXTURE_2D)");
            return error.CudaInitFailed;
        }

        res = cuGraphicsResourceSetMapFlags(graphics_resource.?, CU_GRAPHICS_MAP_RESOURCE_FLAGS_READ_ONLY);
        if (res != CUDA_SUCCESS) {
            logCudaError(cuGetErrorString, res, "cuGraphicsResourceSetMapFlags");
            _ = cuGraphicsUnregisterResource(graphics_resource.?);
            return error.CudaInitFailed;
        }

        log.info("CUDA init: {d}x{d} BGRA buffer pitch={d}, GL texture registered", .{ width, height, pitch });

        return .{
            .lib = lib,
            .gl_lib = gl_lib,
            .ctx = ctx.?,
            .device_ptr = device_ptr,
            .device_pitch = pitch,
            .device_size = pitch * height,
            .frame_width = width,
            .frame_height = height,
            .blit_texture = blit_texture,
            .blit_fbo = blit_fbo,
            .graphics_resource = graphics_resource,
            .glBindFramebuffer = glBindFramebuffer,
            .glBlitFramebuffer = glBlitFramebuffer,
            .glFlush = glFlush,
            .cuGetErrorString = cuGetErrorString,
            .cuCtxDestroy_v2 = cuCtxDestroy,
            .cuMemAllocPitch = cuMemAllocPitch,
            .cuMemFree_v2 = cuMemFree,
            .cuMemcpy2D_v2 = cuMemcpy2D,
            .cuGraphicsGLRegisterImage = cuGraphicsGLRegisterImage,
            .cuGraphicsResourceSetMapFlags = cuGraphicsResourceSetMapFlags,
            .cuGraphicsMapResources = cuGraphicsMapResources,
            .cuGraphicsUnmapResources = cuGraphicsUnmapResources,
            .cuGraphicsUnregisterResource = cuGraphicsUnregisterResource,
            .cuGraphicsSubResourceGetMappedArray = cuGraphicsSubResourceGetMappedArray,
        };
    }

    /// Blit from the wlroots FBO into our texture, then copy to CUDA device memory.
    /// Must be called while the EGL/GL context is current.
    pub fn copyFromFbo(self: *Cuda, src_fbo: u32) !void {
        if (src_fbo == 0) return error.InvalidFbo;

        const w: c_int = @intCast(self.frame_width);
        const h: c_int = @intCast(self.frame_height);

        // Blit from wlroots FBO → our texture FBO
        self.glBindFramebuffer(GL_READ_FRAMEBUFFER, src_fbo);
        self.glBindFramebuffer(GL_DRAW_FRAMEBUFFER, self.blit_fbo);
        self.glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
        self.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        self.glFlush();

        // Map the CUDA-registered texture
        var resource = self.graphics_resource;
        var res = self.cuGraphicsMapResources(1, @ptrCast(&resource), null);
        if (res != CUDA_SUCCESS) {
            logCudaError(self.cuGetErrorString, res, "cuGraphicsMapResources");
            return error.CudaCopyFailed;
        }
        defer _ = self.cuGraphicsUnmapResources(1, @ptrCast(&resource), null);

        var mapped_array: ?*anyopaque = null;
        res = self.cuGraphicsSubResourceGetMappedArray(&mapped_array, resource.?, 0, 0);
        if (res != CUDA_SUCCESS) {
            logCudaError(self.cuGetErrorString, res, "cuGraphicsSubResourceGetMappedArray");
            return error.CudaCopyFailed;
        }

        // Copy CUarray → linear device memory (RGBA, 4 bytes/pixel)
        const copy = Memcpy2D{
            .srcMemoryType = CU_MEMORYTYPE_ARRAY,
            .srcArray = mapped_array,
            .dstMemoryType = CU_MEMORYTYPE_DEVICE,
            .dstDevice = self.device_ptr,
            .dstPitch = self.device_pitch,
            .WidthInBytes = @as(usize, self.frame_width) * 4,
            .Height = self.frame_height,
        };

        res = self.cuMemcpy2D_v2(&copy);
        if (res != CUDA_SUCCESS) {
            logCudaError(self.cuGetErrorString, res, "cuMemcpy2D_v2");
            return error.CudaCopyFailed;
        }
    }

    pub fn deinit(self: *Cuda) void {
        if (self.graphics_resource) |r| {
            _ = self.cuGraphicsUnregisterResource(r);
        }
        if (self.device_ptr != 0) {
            _ = self.cuMemFree_v2(self.device_ptr);
        }
        _ = self.cuCtxDestroy_v2(self.ctx);

        // Clean up GL resources (FBO and texture)
        const glDeleteFramebuffers = resolveGL(GlDeleteFramebuffersFn, self.gl_lib, "glDeleteFramebuffers");
        const glDeleteTextures = resolveGL(GlDeleteTexturesFn, self.gl_lib, "glDeleteTextures");
        if (glDeleteFramebuffers) |f| f(1, &self.blit_fbo);
        if (glDeleteTextures) |f| f(1, &self.blit_texture);

        _ = std.c.dlclose(self.gl_lib);
        _ = std.c.dlclose(self.lib);
    }
};

// ============================================================================
// Helpers
// ============================================================================

fn resolve(comptime T: type, lib: *anyopaque, name: [*:0]const u8) ?T {
    const sym = std.c.dlsym(lib, name) orelse {
        log.err("CUDA symbol {s} not found", .{name});
        return null;
    };
    return @ptrCast(sym);
}

fn resolveGL(comptime T: type, lib: *anyopaque, name: [*:0]const u8) ?T {
    const sym = std.c.dlsym(lib, name) orelse {
        log.err("GL symbol {s} not found", .{name});
        return null;
    };
    return @ptrCast(sym);
}

fn logCudaError(getErrorString: GetErrorStringFn, result: CUresult, context: [*:0]const u8) void {
    var err_str: ?[*:0]const u8 = null;
    _ = getErrorString(result, &err_str);
    log.err("{s} failed: {s} ({d})", .{
        context,
        if (err_str) |s| std.mem.span(s) else "unknown",
        result,
    });
}
