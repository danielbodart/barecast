const std = @import("std");
const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("GL/glx.h");
});

// ============================================================================
// NvFBC type definitions (pure Zig, matching C ABI from NvFBC.h v1.7)
// ============================================================================

const api_version: u32 = 0x07 | (0x01 << 8); // minor=7, major=1

fn structVersion(comptime T: type, ver: u32) u32 {
    return @sizeOf(T) | (ver << 16) | (api_version << 24);
}

pub const Status = enum(c_int) {
    success = 0,
    err_api_version = 1,
    err_internal = 2,
    err_invalid_param = 3,
    err_invalid_ptr = 4,
    err_invalid_handle = 5,
    err_max_clients = 6,
    err_unsupported = 7,
    err_out_of_memory = 8,
    err_bad_request = 9,
    err_x = 10,
    err_glx = 11,
    err_gl = 12,
    err_cuda = 13,
    err_encoder = 14,
    err_context = 15,
    err_must_recreate = 16,
    err_vulkan = 17,
};

pub const Bool = enum(c_int) {
    false_ = 0,
    true_ = 1,
};

pub const CaptureType = enum(c_int) {
    to_sys = 0,
    shared_cuda = 1,
    // 2 is retired
    to_gl = 3,
};

pub const TrackingType = enum(c_int) {
    default = 0,
    output = 1,
    screen = 2,
};

pub const BufferFormat = enum(c_int) {
    argb = 0,
    rgb = 1,
    nv12 = 2,
    yuv444p = 3,
    rgba = 4,
    bgra = 5,
};

pub const Box = extern struct {
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
};

pub const Size = extern struct {
    w: u32 = 0,
    h: u32 = 0,
};

const output_max = 5;
const output_name_len = 128;

pub const RandrOutputInfo = extern struct {
    dwId: u32 = 0,
    name: [output_name_len]u8 = [_]u8{0} ** output_name_len,
    trackedBox: Box = .{},
};

pub const FrameGrabInfo = extern struct {
    dwWidth: u32 = 0,
    dwHeight: u32 = 0,
    dwByteSize: u32 = 0,
    dwCurrentFrame: u32 = 0,
    bIsNewFrame: Bool = .false_,
    ulTimestampUs: u64 = 0,
    dwMissedFrames: u32 = 0,
    bRequiredPostProcessing: Bool = .false_,
    bDirectCapture: Bool = .false_,
};

pub const CreateHandleParams = extern struct {
    dwVersion: u32 = structVersion(CreateHandleParams, 2),
    privateData: ?*const anyopaque = null,
    privateDataSize: u32 = 0,
    bExternallyManagedContext: Bool = .false_,
    glxCtx: ?*anyopaque = null,
    glxFBConfig: ?*anyopaque = null,
};

pub const DestroyHandleParams = extern struct {
    dwVersion: u32 = structVersion(DestroyHandleParams, 1),
};

pub const GetStatusParams = extern struct {
    dwVersion: u32 = structVersion(GetStatusParams, 2),
    bIsCapturePossible: Bool = .false_,
    bCurrentlyCapturing: Bool = .false_,
    bCanCreateNow: Bool = .false_,
    screenSize: Size = .{},
    bXRandRAvailable: Bool = .false_,
    outputs: [output_max]RandrOutputInfo = [_]RandrOutputInfo{.{}} ** output_max,
    dwOutputNum: u32 = 0,
    dwNvFBCVersion: u32 = 0,
    bInModeset: Bool = .false_,
};

pub const CreateCaptureSessionParams = extern struct {
    dwVersion: u32 = structVersion(CreateCaptureSessionParams, 6),
    eCaptureType: CaptureType = .to_gl,
    eTrackingType: TrackingType = .screen,
    dwOutputId: u32 = 0,
    captureBox: Box = .{},
    frameSize: Size = .{},
    bWithCursor: Bool = .true_,
    bDisableAutoModesetRecovery: Bool = .false_,
    bRoundFrameSize: Bool = .false_,
    dwSamplingRateMs: u32 = 0,
    bPushModel: Bool = .false_,
    bAllowDirectCapture: Bool = .false_,
};

pub const DestroyCaptureSessionParams = extern struct {
    dwVersion: u32 = structVersion(DestroyCaptureSessionParams, 1),
};

pub const BindContextParams = extern struct {
    dwVersion: u32 = structVersion(BindContextParams, 1),
};

pub const ReleaseContextParams = extern struct {
    dwVersion: u32 = structVersion(ReleaseContextParams, 1),
};

const togl_textures_max = 2;

pub const ToGlSetupParams = extern struct {
    dwVersion: u32 = structVersion(ToGlSetupParams, 2),
    eBufferFormat: BufferFormat = .bgra,
    bWithDiffMap: Bool = .false_,
    ppDiffMap: ?*?*anyopaque = null,
    dwDiffMapScalingFactor: u32 = 0,
    dwTextures: [togl_textures_max]u32 = .{ 0, 0 },
    dwTexTarget: u32 = 0,
    dwTexFormat: u32 = 0,
    dwTexType: u32 = 0,
    diffMapSize: Size = .{},
};

pub const ToGlGrabFrameParams = extern struct {
    dwVersion: u32 = structVersion(ToGlGrabFrameParams, 2),
    dwFlags: u32 = 0,
    dwTextureIndex: u32 = 0,
    pFrameGrabInfo: ?*FrameGrabInfo = null,
    dwTimeoutMs: u32 = 0,
};

pub const SessionHandle = u64;

// Function pointer types matching the C API
const GetLastErrorStrFn = *const fn (SessionHandle) callconv(.c) ?[*:0]const u8;
const CreateHandleFn = *const fn (*SessionHandle, *CreateHandleParams) callconv(.c) Status;
const DestroyHandleFn = *const fn (SessionHandle, *DestroyHandleParams) callconv(.c) Status;
const GetStatusFn = *const fn (SessionHandle, *GetStatusParams) callconv(.c) Status;
const CreateCaptureSessionFn = *const fn (SessionHandle, *CreateCaptureSessionParams) callconv(.c) Status;
const DestroyCaptureSessionFn = *const fn (SessionHandle, *DestroyCaptureSessionParams) callconv(.c) Status;
const BindContextFn = *const fn (SessionHandle, *BindContextParams) callconv(.c) Status;
const ReleaseContextFn = *const fn (SessionHandle, *ReleaseContextParams) callconv(.c) Status;
const ToGlSetUpFn = *const fn (SessionHandle, *ToGlSetupParams) callconv(.c) Status;
const ToGlGrabFrameFn = *const fn (SessionHandle, *ToGlGrabFrameParams) callconv(.c) Status;

// Retired / unused function slots use the same shape for padding
const PadFn = ?*anyopaque;
// ToSys/ToCuda slots — we don't call them but need them for layout
const VoidFnPtr = ?*anyopaque;

pub const ApiFunctionList = extern struct {
    dwVersion: u32 = api_version,
    nvFBCGetLastErrorStr: ?GetLastErrorStrFn = null,
    nvFBCCreateHandle: ?CreateHandleFn = null,
    nvFBCDestroyHandle: ?DestroyHandleFn = null,
    nvFBCGetStatus: ?GetStatusFn = null,
    nvFBCCreateCaptureSession: ?CreateCaptureSessionFn = null,
    nvFBCDestroyCaptureSession: ?DestroyCaptureSessionFn = null,
    nvFBCToSysSetUp: VoidFnPtr = null,
    nvFBCToSysGrabFrame: VoidFnPtr = null,
    nvFBCToCudaSetUp: VoidFnPtr = null,
    nvFBCToCudaGrabFrame: VoidFnPtr = null,
    pad1: PadFn = null,
    pad2: PadFn = null,
    pad3: PadFn = null,
    nvFBCBindContext: ?BindContextFn = null,
    nvFBCReleaseContext: ?ReleaseContextFn = null,
    pad4: PadFn = null,
    pad5: PadFn = null,
    pad6: PadFn = null,
    pad7: PadFn = null,
    nvFBCToGLSetUp: ?ToGlSetUpFn = null,
    nvFBCToGLGrabFrame: ?ToGlGrabFrameFn = null,
};

const CreateInstanceFn = *const fn (*ApiFunctionList) callconv(.c) Status;

// ============================================================================
// GLX context helper
// ============================================================================

pub const GlxContext = struct {
    display: *c.Display,
    context: c.GLXContext,
    fb_config: c.GLXFBConfig,
    pixmap: c.Pixmap = 0,
    glx_pixmap: c.GLXPixmap = 0,

    pub fn init(display_name: ?[*:0]const u8) error{GlxFailed}!GlxContext {
        const display = c.XOpenDisplay(display_name) orelse return error.GlxFailed;

        const attrs = [_]c_int{
            c.GLX_RENDER_TYPE,                   c.GLX_RGBA_BIT,
            c.GLX_DRAWABLE_TYPE,                 c.GLX_PIXMAP_BIT | c.GLX_WINDOW_BIT,
            c.GLX_BIND_TO_TEXTURE_RGBA_EXT,      1,
            c.GLX_BIND_TO_TEXTURE_TARGETS_EXT,   c.GLX_TEXTURE_2D_BIT_EXT,
            c.GLX_DOUBLEBUFFER,                  0,
            c.GLX_RED_SIZE,                      8,
            c.GLX_GREEN_SIZE,                    8,
            c.GLX_BLUE_SIZE,                     8,
            c.None,
        };

        var n_configs: c_int = 0;
        const configs = c.glXChooseFBConfig(display, c.DefaultScreen(display), &attrs, &n_configs);
        if (configs == null or n_configs < 1) return error.GlxFailed;

        const fb_config = configs.?[0];
        _ = c.XFree(@ptrCast(configs));

        const ctx = c.glXCreateNewContext(display, fb_config, c.GLX_RGBA_TYPE, null, 1) orelse return error.GlxFailed;

        // Create a 1x1 pixmap drawable so we can make the context current
        const root = c.DefaultRootWindow(display);
        const visual_info = c.glXGetVisualFromFBConfig(display, fb_config);
        if (visual_info == null) {
            c.glXDestroyContext(display, ctx);
            return error.GlxFailed;
        }
        const depth: c_uint = @intCast(visual_info.*.depth);
        _ = c.XFree(visual_info);
        const pixmap = c.XCreatePixmap(display, root, 1, 1, depth);
        if (pixmap == 0) {
            c.glXDestroyContext(display, ctx);
            return error.GlxFailed;
        }

        const glx_pixmap_attrs = [_]c_int{ c.None };
        const glx_pixmap = c.glXCreatePixmap(display, fb_config, pixmap, &glx_pixmap_attrs);
        if (glx_pixmap == 0) {
            _ = c.XFreePixmap(display, pixmap);
            c.glXDestroyContext(display, ctx);
            return error.GlxFailed;
        }

        if (c.glXMakeContextCurrent(display, glx_pixmap, glx_pixmap, ctx) == 0) {
            c.glXDestroyPixmap(display, glx_pixmap);
            _ = c.XFreePixmap(display, pixmap);
            c.glXDestroyContext(display, ctx);
            return error.GlxFailed;
        }

        return .{
            .display = display,
            .context = ctx,
            .fb_config = fb_config,
            .pixmap = pixmap,
            .glx_pixmap = glx_pixmap,
        };
    }

    pub fn deinit(self: *GlxContext) void {
        _ = c.glXMakeContextCurrent(self.display, 0, 0, null);
        if (self.glx_pixmap != 0) c.glXDestroyPixmap(self.display, self.glx_pixmap);
        if (self.pixmap != 0) _ = c.XFreePixmap(self.display, self.pixmap);
        c.glXDestroyContext(self.display, self.context);
        _ = c.XCloseDisplay(self.display);
    }
};

// ============================================================================
// High-level NvFbc capture wrapper
// ============================================================================

pub const FrameResult = struct {
    texture_id: u32,
    width: u32,
    height: u32,
    is_new: bool,
    /// NvFBC hardware capture timestamp (microseconds). Populated for future
    /// use in end-to-end latency measurement (abs-capture-time RTP extension).
    capture_timestamp_us: u64,
};

pub const NvFbc = struct {
    lib: *anyopaque,
    fns: ApiFunctionList,
    handle: SessionHandle,
    glx: GlxContext,
    setup_params: ToGlSetupParams,
    session_created: bool,
    screen_size: Size,
    last_frame_id: u32 = 0,
    /// Heap-allocated stable storage for the diff map pointer. NvFBC writes
    /// the address of its internal diff map buffer here on each grab.
    diff_map_storage: ?*?[*]u8 = null,
    diff_map_size: usize = 0,

    pub const InitOptions = struct {
        display_name: ?[*:0]const u8 = null,
        /// Headless mode: use push model + direct capture + no cursor.
        /// Optimized for headless displays with a compositor (picom).
        headless: bool = false,
    };

    pub fn init(capture_box: Box, fps: u32) !NvFbc {
        return initWithOptions(capture_box, fps, .{});
    }

    pub fn initDisplay(capture_box: Box, fps: u32, display_name: ?[*:0]const u8) !NvFbc {
        return initWithOptions(capture_box, fps, .{ .display_name = display_name, .headless = true });
    }

    pub fn initWithOptions(capture_box: Box, fps: u32, options: InitOptions) !NvFbc {
        const display_name = options.display_name;
        var glx = GlxContext.init(display_name) catch {
            std.debug.print("NvFBC: failed to create GLX context\n", .{});
            return error.NvFbcInitFailed;
        };
        errdefer glx.deinit();

        // dlopen
        const lib = std.c.dlopen("libnvidia-fbc.so.1", .{ .LAZY = true }) orelse {
            std.debug.print("NvFBC: failed to load libnvidia-fbc.so.1\n", .{});
            return error.NvFbcInitFailed;
        };
        errdefer _ = std.c.dlclose(lib);

        const create_instance_sym = std.c.dlsym(lib, "NvFBCCreateInstance") orelse {
            std.debug.print("NvFBC: symbol NvFBCCreateInstance not found\n", .{});
            return error.NvFbcInitFailed;
        };
        const createInstance: CreateInstanceFn = @ptrCast(create_instance_sym);

        var fns = ApiFunctionList{};
        var status = createInstance(&fns);
        if (status != .success) {
            std.debug.print("NvFBC: NvFBCCreateInstance failed: {}\n", .{status});
            return error.NvFbcInitFailed;
        }

        const createHandle = fns.nvFBCCreateHandle orelse return error.NvFbcInitFailed;
        const getStatus = fns.nvFBCGetStatus orelse return error.NvFbcInitFailed;

        // Create handle — try without key first, then with enable_key fallback
        var session: SessionHandle = 0;
        var create_params = CreateHandleParams{
            .bExternallyManagedContext = .true_,
            .glxCtx = glx.context,
            .glxFBConfig = glx.fb_config,
        };

        status = createHandle(&session, &create_params);
        if (status != .success) {
            const enable_key = [_]u8{ 0xac, 0x10, 0xc9, 0x2e, 0xa5, 0xe6, 0x87, 0x4f, 0x8f, 0x4b, 0xf4, 0x61, 0xf8, 0x56, 0x27, 0xe9 };
            create_params.privateData = &enable_key;
            create_params.privateDataSize = 16;

            status = createHandle(&session, &create_params);
            if (status != .success) {
                const err_str = if (fns.nvFBCGetLastErrorStr) |f| f(session) else null;
                std.debug.print("NvFBC: CreateHandle failed ({s}): {s}\n", .{
                    @tagName(status),
                    err_str orelse "unknown",
                });
                if (status == .err_max_clients) {
                    std.debug.print("NvFBC: Another capture session is already running. Kill it with: pkill -f zerocast\n", .{});
                }
                return error.NvFbcInitFailed;
            }
        }

        // Get status
        var status_params = GetStatusParams{};
        status = getStatus(session, &status_params);
        if (status != .success) {
            const err_str = if (fns.nvFBCGetLastErrorStr) |f| f(session) else null;
            std.debug.print("NvFBC: GetStatus failed: {s}\n", .{err_str orelse "unknown"});
            var dp = DestroyHandleParams{};
            _ = (fns.nvFBCDestroyHandle orelse unreachable)(session, &dp);
            return error.NvFbcInitFailed;
        }

        if (status_params.bCanCreateNow != .true_) {
            std.debug.print("NvFBC: cannot create capture session on this system\n", .{});
            var dp = DestroyHandleParams{};
            _ = (fns.nvFBCDestroyHandle orelse unreachable)(session, &dp);
            return error.NvFbcInitFailed;
        }

        std.debug.print("NvFBC: screen {}x{}\n", .{ status_params.screenSize.w, status_params.screenSize.h });
        if (capture_box.w != 0) {
            std.debug.print("NvFBC: capture region {}x{}+{}+{}\n", .{
                capture_box.w, capture_box.h, capture_box.x, capture_box.y,
            });
        }

        // Create capture session — sampling rate derived from fps
        // When captureBox is set, also set frameSize to match so the output
        // texture is sized to the crop region (not the full screen).
        const frame_size: Size = if (capture_box.w != 0)
            .{ .w = capture_box.w, .h = capture_box.h }
        else
            .{};
        var cap_params = CreateCaptureSessionParams{
            .dwSamplingRateMs = (999 + fps) / fps,
            .captureBox = capture_box,
            .frameSize = frame_size,
        };

        if (options.headless) {
            cap_params.bWithCursor = .false_;
            std.debug.print("NvFBC: headless mode (polling, no compositor)\n", .{});
        }
        status = (fns.nvFBCCreateCaptureSession orelse return error.NvFbcInitFailed)(session, &cap_params);
        if (status != .success) {
            const err_str = if (fns.nvFBCGetLastErrorStr) |f| f(session) else null;
            std.debug.print("NvFBC: CreateCaptureSession failed: {s}\n", .{err_str orelse "unknown"});
            var dp = DestroyHandleParams{};
            _ = (fns.nvFBCDestroyHandle orelse unreachable)(session, &dp);
            return error.NvFbcInitFailed;
        }

        // GL setup — enable diff map for pixel-level change detection.
        // NvFBC writes the diff map address into *ppDiffMap on each grab,
        // so the storage must outlive the stack frame. Heap-allocate one pointer.
        const diff_map_storage = std.heap.c_allocator.create(?[*]u8) catch return error.NvFbcInitFailed;
        diff_map_storage.* = null;
        var setup_params = ToGlSetupParams{
            .bWithDiffMap = .true_,
            .ppDiffMap = @ptrCast(diff_map_storage),
            .dwDiffMapScalingFactor = 128, // one byte per 128x128 block
        };
        status = (fns.nvFBCToGLSetUp orelse return error.NvFbcInitFailed)(session, &setup_params);
        if (status != .success) {
            const err_str = if (fns.nvFBCGetLastErrorStr) |f| f(session) else null;
            std.debug.print("NvFBC: ToGLSetUp failed: {s}\n", .{err_str orelse "unknown"});
            std.heap.c_allocator.destroy(diff_map_storage);
            var dsp = DestroyCaptureSessionParams{};
            _ = (fns.nvFBCDestroyCaptureSession orelse unreachable)(session, &dsp);
            var dp = DestroyHandleParams{};
            _ = (fns.nvFBCDestroyHandle orelse unreachable)(session, &dp);
            return error.NvFbcInitFailed;
        }

        const dm_size: usize = @as(usize, setup_params.diffMapSize.w) * @as(usize, setup_params.diffMapSize.h);
        std.debug.print("NvFBC: textures=[{}, {}], target=0x{X}, format=0x{X}, diffmap={}x{} ({} bytes)\n", .{
            setup_params.dwTextures[0], setup_params.dwTextures[1],
            setup_params.dwTexTarget,   setup_params.dwTexFormat,
            setup_params.diffMapSize.w, setup_params.diffMapSize.h, dm_size,
        });

        return .{
            .lib = lib,
            .fns = fns,
            .handle = session,
            .glx = glx,
            .setup_params = setup_params,
            .session_created = true,
            .screen_size = status_params.screenSize,
            .diff_map_storage = diff_map_storage,
            .diff_map_size = dm_size,
        };
    }

    pub fn grabFrame(self: *NvFbc) !FrameResult {
        var frame_info = FrameGrabInfo{};
        var grab_params = ToGlGrabFrameParams{
            .dwFlags = 0x00, // blocking grab, no FORCE_REFRESH
            .pFrameGrabInfo = &frame_info,
            .dwTimeoutMs = 100,
        };

        const status = (self.fns.nvFBCToGLGrabFrame orelse return error.NvFbcGrabFailed)(self.handle, &grab_params);
        if (status == .err_must_recreate) {
            std.debug.print("NvFBC: display changed, must recreate capture session\n", .{});
            return error.NvFbcMustRecreate;
        }
        if (status != .success) {
            const err_str = if (self.fns.nvFBCGetLastErrorStr) |f| f(self.handle) else null;
            std.debug.print("NvFBC: GrabFrame failed: {s}\n", .{err_str orelse "unknown"});
            return error.NvFbcGrabFailed;
        }

        // Determine if frame has new content via frame ID counter.
        // The diff map is unreliable with frame pacing (fixed-interval sampling
        // vs damage-event-driven captures), so we rely solely on the compositor's
        // frame counter. If the frame ID hasn't changed, no new content was
        // composited since the last grab.
        const is_new = frame_info.dwCurrentFrame != self.last_frame_id;
        self.last_frame_id = frame_info.dwCurrentFrame;

        return .{
            .texture_id = self.setup_params.dwTextures[grab_params.dwTextureIndex],
            .width = frame_info.dwWidth,
            .height = frame_info.dwHeight,
            .is_new = is_new,
            .capture_timestamp_us = frame_info.ulTimestampUs,
        };
    }

    pub fn deinit(self: *NvFbc) void {
        if (self.session_created) {
            var dsp = DestroyCaptureSessionParams{};
            _ = (self.fns.nvFBCDestroyCaptureSession orelse unreachable)(self.handle, &dsp);
        }
        var dp = DestroyHandleParams{};
        _ = (self.fns.nvFBCDestroyHandle orelse unreachable)(self.handle, &dp);
        if (self.diff_map_storage) |s| std.heap.c_allocator.destroy(s);
        _ = std.c.dlclose(self.lib);
        self.glx.deinit();
    }
};
