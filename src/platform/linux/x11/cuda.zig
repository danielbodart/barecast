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
// Function pointer types
// ============================================================================

const InitFn = *const fn (u32) callconv(.c) CUresult;
const DeviceGetCountFn = *const fn (*c_int) callconv(.c) CUresult;
const DeviceGetFn = *const fn (*CUdevice, c_int) callconv(.c) CUresult;
const CtxCreateFn = *const fn (*?CUcontext, u32, CUdevice) callconv(.c) CUresult;
const CtxDestroyFn = *const fn (CUcontext) callconv(.c) CUresult;
const GetErrorStringFn = *const fn (CUresult, *?[*:0]const u8) callconv(.c) CUresult;
const MemAllocFn = *const fn (*CUdeviceptr, usize) callconv(.c) CUresult;
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
// CUDA context + GL interop
// ============================================================================

pub const Cuda = struct {
    lib: *anyopaque,
    ctx: CUcontext,
    device_ptr: CUdeviceptr,
    device_pitch: usize,
    device_size: usize,
    frame_width: u32,
    frame_height: u32,
    graphics_resource: ?*anyopaque,

    // Function pointers
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

    pub fn init(texture_id: u32, width: u32, height: u32) !Cuda {
        // dlopen libcuda
        const lib = std.c.dlopen("libcuda.so.1", .{ .LAZY = true }) orelse blk: {
            break :blk std.c.dlopen("libcuda.so", .{ .LAZY = true }) orelse {
                std.debug.print("CUDA: failed to load libcuda.so.1 or libcuda.so\n", .{});
                return error.CudaInitFailed;
            };
        };
        errdefer _ = std.c.dlclose(lib);

        // Resolve symbols
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

        // cuInit
        var res = cuInit(0);
        if (res != CUDA_SUCCESS) {
            logCudaError(cuGetErrorString, res, "cuInit");
            return error.CudaInitFailed;
        }

        // Find device
        var device_count: c_int = 0;
        res = cuDeviceGetCount(&device_count);
        if (res != CUDA_SUCCESS or device_count <= 0) {
            std.debug.print("CUDA: no devices found\n", .{});
            return error.CudaInitFailed;
        }

        var device: CUdevice = 0;
        res = cuDeviceGet(&device, 0);
        if (res != CUDA_SUCCESS) {
            logCudaError(cuGetErrorString, res, "cuDeviceGet");
            return error.CudaInitFailed;
        }

        // Create context
        var ctx: ?CUcontext = null;
        res = cuCtxCreate(&ctx, CU_CTX_SCHED_AUTO, device);
        if (res != CUDA_SUCCESS or ctx == null) {
            logCudaError(cuGetErrorString, res, "cuCtxCreate_v2");
            return error.CudaInitFailed;
        }
        errdefer _ = cuCtxDestroy(ctx.?);

        // Allocate BGRA device buffer with pitch alignment.
        // BGRA = 4 bytes per pixel. Allocate width*4 x height.
        var device_ptr: CUdeviceptr = 0;
        var pitch: usize = 0;
        res = cuMemAllocPitch(&device_ptr, &pitch, @as(usize, width) * 4, height, 16);
        if (res != CUDA_SUCCESS) {
            logCudaError(cuGetErrorString, res, "cuMemAllocPitch_v2");
            return error.CudaInitFailed;
        }
        errdefer _ = cuMemFree(device_ptr);

        std.debug.print("CUDA: allocated {}x{} BGRA buffer, pitch={}\n", .{ width, height, pitch });

        // Register NvFBC GL texture for CUDA access
        var graphics_resource: ?*anyopaque = null;
        res = cuGraphicsGLRegisterImage(&graphics_resource, texture_id, GL_TEXTURE_2D, CU_GRAPHICS_REGISTER_FLAGS_READ_ONLY);
        if (res != CUDA_SUCCESS) {
            logCudaError(cuGetErrorString, res, "cuGraphicsGLRegisterImage");
            return error.CudaInitFailed;
        }
        errdefer _ = cuGraphicsUnregisterResource(graphics_resource.?);

        // Set map flags to read-only
        res = cuGraphicsResourceSetMapFlags(graphics_resource.?, CU_GRAPHICS_MAP_RESOURCE_FLAGS_READ_ONLY);
        if (res != CUDA_SUCCESS) {
            logCudaError(cuGetErrorString, res, "cuGraphicsResourceSetMapFlags");
            return error.CudaInitFailed;
        }

        return .{
            .lib = lib,
            .ctx = ctx.?,
            .device_ptr = device_ptr,
            .device_pitch = pitch,
            .device_size = pitch * height,
            .frame_width = width,
            .frame_height = height,
            .graphics_resource = graphics_resource,
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

    /// Copy the registered GL texture contents to the linear CUDA device buffer.
    /// Must be called after NvFBC.grabFrame() while the GL context is current.
    pub fn copyGlTexture(self: *Cuda) !void {
        // Map GL texture into CUDA
        var res = self.cuGraphicsMapResources(1, @ptrCast(&self.graphics_resource), null);
        if (res != CUDA_SUCCESS) {
            logCudaError(self.cuGetErrorString, res, "cuGraphicsMapResources");
            return error.CudaCopyFailed;
        }
        defer _ = self.cuGraphicsUnmapResources(1, @ptrCast(&self.graphics_resource), null);

        // Get the mapped CUarray
        var mapped_array: ?*anyopaque = null;
        res = self.cuGraphicsSubResourceGetMappedArray(&mapped_array, self.graphics_resource.?, 0, 0);
        if (res != CUDA_SUCCESS) {
            logCudaError(self.cuGetErrorString, res, "cuGraphicsSubResourceGetMappedArray");
            return error.CudaCopyFailed;
        }

        // Copy CUarray → linear device memory (BGRA, 4 bytes/pixel)
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
        if (self.graphics_resource) |res| {
            _ = self.cuGraphicsUnregisterResource(res);
        }
        if (self.device_ptr != 0) {
            _ = self.cuMemFree_v2(self.device_ptr);
        }
        _ = self.cuCtxDestroy_v2(self.ctx);
        _ = std.c.dlclose(self.lib);
    }
};

// ============================================================================
// Helpers
// ============================================================================

fn resolve(comptime T: type, lib: *anyopaque, name: [*:0]const u8) ?T {
    const sym = std.c.dlsym(lib, name) orelse {
        std.debug.print("CUDA: symbol {s} not found\n", .{name});
        return null;
    };
    return @ptrCast(sym);
}

fn logCudaError(getErrorString: GetErrorStringFn, result: CUresult, context: [*:0]const u8) void {
    var err_str: ?[*:0]const u8 = null;
    _ = getErrorString(result, &err_str);
    std.debug.print("CUDA: {s} failed: {s} ({})\n", .{
        context,
        if (err_str) |s| std.mem.span(s) else "unknown",
        result,
    });
}
