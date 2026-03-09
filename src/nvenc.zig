const std = @import("std");
const cuda = @import("cuda");

// ============================================================================
// NVENC API version constants (SDK 12.0)
// ============================================================================

const nvenc_api_major: u32 = 12;
const nvenc_api_minor: u32 = 0;
const nvenc_api_version: u32 = nvenc_api_major | (nvenc_api_minor << 24);

fn structVersion(ver: u32) u32 {
    return nvenc_api_version | (ver << 16) | (0x7 << 28);
}

fn structVersionHigh(ver: u32) u32 {
    return structVersion(ver) | (1 << 31);
}

// ============================================================================
// Status
// ============================================================================

pub const Status = enum(c_int) {
    success = 0,
    err_no_encode_device = 1,
    err_unsupported_device = 2,
    err_invalid_encoderdevice = 3,
    err_invalid_device = 4,
    err_device_not_exist = 5,
    err_invalid_ptr = 6,
    err_invalid_event = 7,
    err_invalid_param = 8,
    err_invalid_call = 9,
    err_out_of_memory = 10,
    err_encoder_not_initialized = 11,
    err_unsupported_param = 12,
    err_lock_busy = 13,
    err_not_enough_buffer = 14,
    err_invalid_version = 15,
    err_map_failed = 16,
    err_need_more_input = 17,
    err_encoder_busy = 18,
    _,
};

// ============================================================================
// GUIDs
// ============================================================================

pub const Guid = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

pub const codec_av1_guid = Guid{
    .data1 = 0x0a352289, .data2 = 0x0aa7, .data3 = 0x4759,
    .data4 = .{ 0x86, 0x2d, 0x5d, 0x15, 0xcd, 0x16, 0xd2, 0x54 },
};

pub const profile_av1_main_guid = Guid{
    .data1 = 0x5f2a39f5, .data2 = 0xf14e, .data3 = 0x4f95,
    .data4 = .{ 0x9a, 0x9e, 0xb7, 0x6d, 0x56, 0x8f, 0xcf, 0x97 },
};

pub const preset_p4_guid = Guid{
    .data1 = 0x90a7b826, .data2 = 0xdf06, .data3 = 0x4862,
    .data4 = .{ 0xb9, 0xd2, 0xcd, 0x6d, 0x73, 0xa0, 0x86, 0x81 },
};

pub const preset_p5_guid = Guid{
    .data1 = 0x532e2bca, .data2 = 0xaacd, .data3 = 0x4b60,
    .data4 = .{ 0xa6, 0x79, 0xbf, 0xa8, 0x5d, 0x02, 0x99, 0xb2 },
};

// ============================================================================
// Constants
// ============================================================================

const NV_ENC_DEVICE_TYPE_CUDA: u32 = 0x1;
const NV_ENC_INPUT_RESOURCE_TYPE_CUDADEVICEPTR: u32 = 0x1;

pub const NV_ENC_BUFFER_FORMAT_NV12: u32 = 0x00000001;
pub const NV_ENC_BUFFER_FORMAT_ARGB: u32 = 0x01000000;
pub const NV_ENC_BUFFER_FORMAT_ABGR: u32 = 0x10000000;

const NV_ENC_TUNING_INFO_HIGH_QUALITY: u32 = 1;
const NV_ENC_TUNING_INFO_LOW_LATENCY: u32 = 2;
const NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY: u32 = 3;
const NV_ENC_PARAMS_RC_CONSTQP: u32 = 0x0;
const NV_ENC_PARAMS_RC_VBR: u32 = 0x1;
const NV_ENC_PARAMS_RC_CBR: u32 = 0x2;
const NV_ENC_MULTI_PASS_DISABLED: u32 = 0x0;

const NV_ENC_PIC_FLAG_FORCEIDR: u32 = 0x2;
const NV_ENC_PIC_FLAG_EOS: u32 = 0x8;

// Encode capability indices (NV_ENC_CAPS)
const NV_ENC_CAPS_NUM_MAX_BFRAMES: u32 = 0;
const NV_ENC_CAPS_WIDTH_MAX: u32 = 2;
const NV_ENC_CAPS_HEIGHT_MAX: u32 = 3;
const NV_ENC_CAPS_NUM_MAX_TEMPORAL_LAYERS: u32 = 7;
const NV_ENC_CAPS_SUPPORT_WEIGHTED_PREDICTION: u32 = 14;
const NV_ENC_CAPS_SUPPORT_BFRAME_REF_MODE: u32 = 15;
const NV_ENC_CAPS_SUPPORT_LOOKAHEAD: u32 = 18;
const NV_ENC_CAPS_SUPPORT_CONSTRAINED_ENCODING: u32 = 19;
const NV_ENC_CAPS_SUPPORT_INTRA_REFRESH: u32 = 20;
const NV_ENC_CAPS_SUPPORT_10BIT_ENCODE: u32 = 21;
const NV_ENC_CAPS_SUPPORT_TEMPORAL_AQ: u32 = 22;
const NV_ENC_CAPS_SUPPORT_EMPHASIS_LEVEL_MAP: u32 = 23;
const NV_ENC_CAPS_SUPPORT_MULTIPLE_REF_FRAMES: u32 = 29;
const NV_ENC_CAPS_SUPPORT_ALPHA_LAYER: u32 = 34;

const EncodeCapsParam = extern struct {
    version: u32 = structVersionHigh(1),
    capsToQuery: u32 = 0,
    _reserved: [62]u32 = [_]u32{0} ** 62,
};
const NV_ENC_PIC_STRUCT_FRAME: u32 = 0x01;

// ============================================================================
// NV_ENC_QP (12 bytes)
// ============================================================================

const QP = extern struct {
    qpInterP: u32 = 0,
    qpInterB: u32 = 0,
    qpIntra: u32 = 0,
};

// ============================================================================
// NV_ENC_RC_PARAMS — 128 bytes, align 4
// ============================================================================

const RcParams = extern struct {
    version: u32 = structVersion(1),
    rateControlMode: u32 = NV_ENC_PARAMS_RC_CONSTQP,
    constQP: QP = .{ .qpInterP = 28, .qpInterB = 28, .qpIntra = 24 },
    averageBitRate: u32 = 0,
    maxBitRate: u32 = 0,
    vbvBufferSize: u32 = 0,
    vbvInitialDelay: u32 = 0,
    bitfield_flags: packed struct(u32) {
        enableMinQP: u1 = 0,
        enableMaxQP: u1 = 0,
        enableInitialRCQP: u1 = 0,
        enableAQ: u1 = 0,
        reservedBitField1: u1 = 0,
        enableLookahead: u1 = 0,
        disableIadapt: u1 = 0,
        disableBadapt: u1 = 0,
        enableTemporalAQ: u1 = 0,
        zeroReorderDelay: u1 = 0,
        enableNonRefP: u1 = 0,
        strictGOPTarget: u1 = 0,
        aqStrength: u4 = 0,
        reservedBitFields: u16 = 0,
    } = .{},
    minQP: QP = .{},
    maxQP: QP = .{},
    initialRCQP: QP = .{},
    temporallayerIdxMask: u32 = 0,
    temporalLayerQP: [8]u8 = [_]u8{0} ** 8,
    targetQuality: u8 = 0,
    targetQualityLSB: u8 = 0,
    lookaheadDepth: u16 = 0,
    lowDelayKeyFrameScale: u8 = 0,
    yDcQPIndexOffset: i8 = 0,
    uDcQPIndexOffset: i8 = 0,
    vDcQPIndexOffset: i8 = 0,
    qpMapMode: u32 = 0,
    multiPass: u32 = NV_ENC_MULTI_PASS_DISABLED,
    alphaLayerBitrateRatio: u32 = 0,
    cbQPIndexOffset: i8 = 0,
    crQPIndexOffset: i8 = 0,
    _reserved2: u16 = 0,
    _reserved: [4]u32 = [_]u32{0} ** 4,

    comptime {
        if (@sizeOf(RcParams) != 128) @compileError("RcParams size mismatch");
    }
};

// ============================================================================
// NV_ENC_CONFIG_AV1 — 1552 bytes, align 8
// ============================================================================

const ConfigAv1 = extern struct {
    level: u32 = 0,
    tier: u32 = 0,
    minPartSize: u32 = 0,
    maxPartSize: u32 = 0,
    bitfield_flags: packed struct(u32) {
        outputAnnexBFormat: u1 = 0,
        enableTimingInfo: u1 = 0,
        enableDecoderModelInfo: u1 = 0,
        enableFrameIdNumbers: u1 = 0,
        disableSeqHdr: u1 = 0,
        repeatSeqHdr: u1 = 0,
        enableIntraRefresh: u1 = 0,
        chromaFormatIDC: u2 = 0,
        enableBitstreamPadding: u1 = 0,
        enableCustomTileConfig: u1 = 0,
        enableFilmGrainParams: u1 = 0,
        inputPixelBitDepthMinus8: u3 = 0,
        pixelBitDepthMinus8: u3 = 0,
        reserved: u14 = 0,
    } = .{},
    idrPeriod: u32 = 120,
    intraRefreshPeriod: u32 = 0,
    intraRefreshCnt: u32 = 0,
    maxNumRefFramesInDPB: u32 = 0,
    numTileColumns: u32 = 0,
    numTileRows: u32 = 0,
    _pad0: u32 = 0,
    tileWidths: ?*u32 = null,
    tileHeights: ?*u32 = null,
    maxTemporalLayersMinus1: u32 = 0,
    colorPrimaries: u32 = 0,
    transferCharacteristics: u32 = 0,
    matrixCoefficients: u32 = 0,
    colorRange: u32 = 0,
    chromaSamplePosition: u32 = 0,
    useBFramesAsRef: u32 = 0,
    _pad1: u32 = 0,
    filmGrainParams: ?*anyopaque = null,
    numFwdRefs: u32 = 0,
    numBwdRefs: u32 = 0,
    _reserved1: [235]u32 = [_]u32{0} ** 235,
    _pad2: u32 = 0,
    _reserved2: [62]?*anyopaque = [_]?*anyopaque{null} ** 62,

    comptime {
        if (@sizeOf(ConfigAv1) != 1552) @compileError("ConfigAv1 size mismatch");
    }
};

// ============================================================================
// NV_ENC_CODEC_CONFIG (union) — 1792 bytes, align 8
// We represent it as a byte array and cast to ConfigAv1 when needed.
// ============================================================================

const CodecConfig = [1792]u8;

// ============================================================================
// NV_ENC_CONFIG — 3584 bytes, align 8
// ============================================================================

const Config = extern struct {
    version: u32 = structVersionHigh(8),
    profileGUID: Guid = profile_av1_main_guid,
    gopLength: u32 = 120,
    frameIntervalP: i32 = 1,
    monoChromeEncoding: u32 = 0,
    frameFieldMode: u32 = 1, // FRAME
    mvPrecision: u32 = 0,
    rcParams: RcParams = .{},
    encodeCodecConfig: CodecConfig = [_]u8{0} ** 1792,
    _reserved: [278]u32 = [_]u32{0} ** 278,
    _reserved2: [64]?*anyopaque = [_]?*anyopaque{null} ** 64,

    comptime {
        if (@sizeOf(Config) != 3584) @compileError("Config size mismatch");
    }

    /// Get a typed pointer to the AV1 config within encodeCodecConfig.
    pub fn av1Config(self: *Config) *ConfigAv1 {
        return @ptrCast(@alignCast(&self.encodeCodecConfig));
    }
};

// ============================================================================
// NVENC_EXTERNAL_ME_HINT_COUNTS_PER_BLOCKTYPE — 16 bytes
// ============================================================================

const MeHintCounts = extern struct {
    bitfield: u32 = 0,
    _reserved: [3]u32 = [_]u32{0} ** 3,
};

// ============================================================================
// NV_ENC_INITIALIZE_PARAMS — 1808 bytes, align 8
// ============================================================================

const InitializeParams = extern struct {
    version: u32 = structVersionHigh(5),
    encodeGUID: Guid = codec_av1_guid,
    presetGUID: Guid = preset_p4_guid,
    encodeWidth: u32,
    encodeHeight: u32,
    darWidth: u32,
    darHeight: u32,
    frameRateNum: u32 = 0,
    frameRateDen: u32 = 0,
    enableEncodeAsync: u32 = 0,
    enablePTD: u32 = 1,
    bitfield_flags: packed struct(u32) {
        reportSliceOffsets: u1 = 0,
        enableSubFrameWrite: u1 = 0,
        enableExternalMEHints: u1 = 0,
        enableMEOnlyMode: u1 = 0,
        enableWeightedPrediction: u1 = 0,
        enableOutputInVidmem: u1 = 0,
        reservedBitFields: u26 = 0,
    } = .{},
    privDataSize: u32 = 0,
    _pad0: u32 = 0,
    privData: ?*anyopaque = null,
    encodeConfig: ?*Config = null,
    maxEncodeWidth: u32 = 0,
    maxEncodeHeight: u32 = 0,
    meHintCounts: [2]MeHintCounts = [_]MeHintCounts{.{}} ** 2,
    tuningInfo: u32 = NV_ENC_TUNING_INFO_HIGH_QUALITY,
    bufferFormat: u32 = 0,
    _reserved: [287]u32 = [_]u32{0} ** 287,
    _pad1: u32 = 0,
    _reserved2: [64]?*anyopaque = [_]?*anyopaque{null} ** 64,

    comptime {
        if (@sizeOf(InitializeParams) != 1808) @compileError("InitializeParams size mismatch");
    }
};

// ============================================================================
// NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS — 1552 bytes, align 8
// ============================================================================

const OpenEncodeSessionExParams = extern struct {
    version: u32 = structVersion(1),
    deviceType: u32 = NV_ENC_DEVICE_TYPE_CUDA,
    device: ?*anyopaque, // CUcontext
    _reserved_ptr: ?*anyopaque = null,
    apiVersion: u32 = nvenc_api_version,
    _reserved1: [253]u32 = [_]u32{0} ** 253,
    _reserved2: [64]?*anyopaque = [_]?*anyopaque{null} ** 64,

    comptime {
        if (@sizeOf(OpenEncodeSessionExParams) != 1552) @compileError("OpenEncodeSessionExParams size mismatch");
    }
};

// ============================================================================
// NV_ENC_REGISTER_RESOURCE — 1536 bytes, align 8
// ============================================================================

const RegisterResource = extern struct {
    version: u32 = structVersion(4),
    resourceType: u32 = NV_ENC_INPUT_RESOURCE_TYPE_CUDADEVICEPTR,
    width: u32,
    height: u32,
    pitch: u32,
    subResourceIndex: u32 = 0,
    resourceToRegister: ?*anyopaque, // CUdeviceptr cast to ptr
    registeredResource: ?*anyopaque = null, // [out]
    bufferFormat: u32 = NV_ENC_BUFFER_FORMAT_ARGB,
    bufferUsage: u32 = 0, // NV_ENC_INPUT_IMAGE = 0
    pInputFencePoint: ?*anyopaque = null,
    _reserved1: [247]u32 = [_]u32{0} ** 247,
    _pad0: u32 = 0,
    _reserved2: [61]?*anyopaque = [_]?*anyopaque{null} ** 61,

    comptime {
        if (@sizeOf(RegisterResource) != 1536) @compileError("RegisterResource size mismatch");
    }
};

// ============================================================================
// NV_ENC_MAP_INPUT_RESOURCE — 1544 bytes, align 8
// ============================================================================

const MapInputResource = extern struct {
    version: u32 = structVersion(4),
    subResourceIndex: u32 = 0,
    inputResource: ?*anyopaque = null,
    registeredResource: ?*anyopaque, // NV_ENC_REGISTERED_PTR
    mappedResource: ?*anyopaque = null, // [out] NV_ENC_INPUT_PTR
    mappedBufferFmt: u32 = 0, // [out]
    _reserved1: [251]u32 = [_]u32{0} ** 251,
    _reserved2: [63]?*anyopaque = [_]?*anyopaque{null} ** 63,

    comptime {
        if (@sizeOf(MapInputResource) != 1544) @compileError("MapInputResource size mismatch");
    }
};

// ============================================================================
// NV_ENC_PIC_PARAMS — 3360 bytes, align 8
// ============================================================================

const CodecPicParams = [1552]u8;

const PicParams = extern struct {
    version: u32 = structVersionHigh(6),
    inputWidth: u32,
    inputHeight: u32,
    inputPitch: u32,
    encodePicFlags: u32 = 0,
    frameIdx: u32 = 0,
    inputTimeStamp: u64 = 0,
    inputDuration: u64 = 0,
    inputBuffer: ?*anyopaque = null, // NV_ENC_INPUT_PTR
    outputBitstream: ?*anyopaque = null, // NV_ENC_OUTPUT_PTR
    completionEvent: ?*anyopaque = null,
    bufferFmt: u32 = NV_ENC_BUFFER_FORMAT_ARGB,
    pictureStruct: u32 = NV_ENC_PIC_STRUCT_FRAME,
    pictureType: u32 = 0,
    _pad0: u32 = 0,
    codecPicParams: CodecPicParams = [_]u8{0} ** 1552,
    meHintCounts: [2]MeHintCounts = [_]MeHintCounts{.{}} ** 2,
    meExternalHints: ?*anyopaque = null,
    _reserved1: [6]u32 = [_]u32{0} ** 6,
    _reserved2: [2]?*anyopaque = [_]?*anyopaque{null} ** 2,
    qpDeltaMap: ?*i8 = null,
    qpDeltaMapSize: u32 = 0,
    reservedBitFields: u32 = 0,
    meHintRefPicDist: [2]u16 = .{ 0, 0 },
    _pad1: u32 = 0,
    alphaBuffer: ?*anyopaque = null,
    meExternalSbHints: ?*anyopaque = null,
    meSbHintsCount: u32 = 0,
    _reserved3: [285]u32 = [_]u32{0} ** 285,
    _reserved4: [58]?*anyopaque = [_]?*anyopaque{null} ** 58,

    comptime {
        if (@sizeOf(PicParams) != 3360) @compileError("PicParams size mismatch");
    }
};

// ============================================================================
// NV_ENC_LOCK_BITSTREAM — 1544 bytes, align 8
// ============================================================================

const LockBitstream = extern struct {
    version: u32 = structVersion(2),
    doNotWaitFlags: u32 = 0, // bitfield
    outputBitstream: ?*anyopaque, // NV_ENC_OUTPUT_PTR
    sliceOffsets: ?*u32 = null,
    frameIdx: u32 = 0,
    hwEncodeStatus: u32 = 0,
    numSlices: u32 = 0,
    bitstreamSizeInBytes: u32 = 0, // [out]
    outputTimeStamp: u64 = 0,
    outputDuration: u64 = 0,
    bitstreamBufferPtr: ?*anyopaque = null, // [out]
    pictureType: u32 = 0, // [out]
    pictureStruct: u32 = 0,
    frameAvgQP: u32 = 0,
    frameSatd: u32 = 0,
    ltrFrameIdx: u32 = 0,
    ltrFrameBitmap: u32 = 0,
    temporalId: u32 = 0,
    _reserved: [12]u32 = [_]u32{0} ** 12,
    intraMBCount: u32 = 0,
    interMBCount: u32 = 0,
    averageMVX: i32 = 0,
    averageMVY: i32 = 0,
    alphaLayerSizeInBytes: u32 = 0,
    _reserved1: [218]u32 = [_]u32{0} ** 218,
    _reserved2: [64]?*anyopaque = [_]?*anyopaque{null} ** 64,

    comptime {
        if (@sizeOf(LockBitstream) != 1544) @compileError("LockBitstream size mismatch");
    }
};

// ============================================================================
// NV_ENC_CREATE_BITSTREAM_BUFFER — 776 bytes, align 8
// ============================================================================

const CreateBitstreamBuffer = extern struct {
    version: u32 = structVersion(1),
    size: u32 = 0,
    memoryHeap: u32 = 0,
    _reserved: u32 = 0,
    bitstreamBuffer: ?*anyopaque = null, // [out] NV_ENC_OUTPUT_PTR
    _bitstreamBufferPtr: ?*anyopaque = null,
    _reserved1: [58]u32 = [_]u32{0} ** 58,
    _reserved2: [64]?*anyopaque = [_]?*anyopaque{null} ** 64,

    comptime {
        if (@sizeOf(CreateBitstreamBuffer) != 776) @compileError("CreateBitstreamBuffer size mismatch");
    }
};

// ============================================================================
// NV_ENC_PRESET_CONFIG — 5128 bytes, align 8
// ============================================================================

const PresetConfig = extern struct {
    version: u32 = structVersionHigh(4),
    _pad0: u32 = 0,
    presetCfg: Config = .{},
    _reserved1: [255]u32 = [_]u32{0} ** 255,
    _pad1: u32 = 0,
    _reserved2: [64]?*anyopaque = [_]?*anyopaque{null} ** 64,

    comptime {
        if (@sizeOf(PresetConfig) != 5128) @compileError("PresetConfig size mismatch");
    }
};


// ============================================================================
// NV_ENCODE_API_FUNCTION_LIST — 2552 bytes, align 8
// ============================================================================

const ApiFunctionList = extern struct {
    version: u32 = structVersion(2),
    _reserved: u32 = 0,
    nvEncOpenEncodeSession: ?*anyopaque = null,
    nvEncGetEncodeGUIDCount: ?*anyopaque = null,
    nvEncGetEncodeProfileGUIDCount: ?*anyopaque = null,
    nvEncGetEncodeProfileGUIDs: ?*anyopaque = null,
    nvEncGetEncodeGUIDs: ?*anyopaque = null,
    nvEncGetInputFormatCount: ?*anyopaque = null,
    nvEncGetInputFormats: ?GetInputFormatsFn = null,
    nvEncGetEncodeCaps: ?GetEncodeCapsF = null,
    nvEncGetEncodePresetCount: ?*anyopaque = null,
    nvEncGetEncodePresetGUIDs: ?*anyopaque = null,
    nvEncGetEncodePresetConfig: ?*anyopaque = null,
    nvEncInitializeEncoder: ?InitializeEncoderFn = null,
    nvEncCreateInputBuffer: ?*anyopaque = null,
    nvEncDestroyInputBuffer: ?*anyopaque = null,
    nvEncCreateBitstreamBuffer: ?CreateBitstreamBufferFn = null,
    nvEncDestroyBitstreamBuffer: ?DestroyBitstreamBufferFn = null,
    nvEncEncodePicture: ?EncodePictureFn = null,
    nvEncLockBitstream: ?LockBitstreamFn = null,
    nvEncUnlockBitstream: ?UnlockBitstreamFn = null,
    nvEncLockInputBuffer: ?*anyopaque = null,
    nvEncUnlockInputBuffer: ?*anyopaque = null,
    nvEncGetEncodeStats: ?*anyopaque = null,
    nvEncGetSequenceParams: ?*anyopaque = null,
    nvEncRegisterAsyncEvent: ?*anyopaque = null,
    nvEncUnregisterAsyncEvent: ?*anyopaque = null,
    nvEncMapInputResource: ?MapInputResourceFn = null,
    nvEncUnmapInputResource: ?UnmapInputResourceFn = null,
    nvEncDestroyEncoder: ?DestroyEncoderFn = null,
    nvEncInvalidateRefFrames: ?*anyopaque = null,
    nvEncOpenEncodeSessionEx: ?OpenEncodeSessionExFn = null,
    nvEncRegisterResource: ?RegisterResourceFn = null,
    nvEncUnregisterResource: ?UnregisterResourceFn = null,
    nvEncReconfigureEncoder: ?*anyopaque = null,
    _reserved1: ?*anyopaque = null,
    nvEncCreateMVBuffer: ?*anyopaque = null,
    nvEncDestroyMVBuffer: ?*anyopaque = null,
    nvEncRunMotionEstimationOnly: ?*anyopaque = null,
    nvEncGetLastErrorString: ?GetLastErrorStringFn = null,
    nvEncSetIOCudaStreams: ?*anyopaque = null,
    nvEncGetEncodePresetConfigEx: ?GetEncodePresetConfigExFn = null,
    nvEncGetSequenceParamEx: ?*anyopaque = null,
    _reserved2: [277]?*anyopaque = [_]?*anyopaque{null} ** 277,

    comptime {
        if (@sizeOf(ApiFunctionList) != 2552) @compileError("ApiFunctionList size mismatch");
    }
};

// ============================================================================
// Function pointer types (Linux ABI — no stdcall)
// ============================================================================

const OpenEncodeSessionExFn = *const fn (*OpenEncodeSessionExParams, *?*anyopaque) callconv(.c) Status;
const InitializeEncoderFn = *const fn (?*anyopaque, *InitializeParams) callconv(.c) Status;
const CreateBitstreamBufferFn = *const fn (?*anyopaque, *CreateBitstreamBuffer) callconv(.c) Status;
const DestroyBitstreamBufferFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) Status;
const EncodePictureFn = *const fn (?*anyopaque, *PicParams) callconv(.c) Status;
const LockBitstreamFn = *const fn (?*anyopaque, *LockBitstream) callconv(.c) Status;
const UnlockBitstreamFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) Status;
const MapInputResourceFn = *const fn (?*anyopaque, *MapInputResource) callconv(.c) Status;
const UnmapInputResourceFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) Status;
const RegisterResourceFn = *const fn (?*anyopaque, *RegisterResource) callconv(.c) Status;
const UnregisterResourceFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) Status;
const DestroyEncoderFn = *const fn (?*anyopaque) callconv(.c) Status;
const GetLastErrorStringFn = *const fn (?*anyopaque) callconv(.c) ?[*:0]const u8;
const GetEncodePresetConfigExFn = *const fn (?*anyopaque, Guid, Guid, u32, *PresetConfig) callconv(.c) Status;
const GetInputFormatsFn = *const fn (?*anyopaque, Guid, *u32, u32, *u32) callconv(.c) Status;
const GetEncodeCapsF = *const fn (?*anyopaque, Guid, *EncodeCapsParam, *i32) callconv(.c) Status;
const CreateInstanceFn = *const fn (*ApiFunctionList) callconv(.c) Status;

// ============================================================================
// Encoded frame result
// ============================================================================

pub const EncodedFrame = struct {
    data: []const u8,
    is_key: bool,
    pts: u64,
};

// ============================================================================
// NVENC encoder
// ============================================================================

pub const Nvenc = struct {
    lib: *anyopaque,
    fns: ApiFunctionList,
    encoder: ?*anyopaque,
    registered_resource: ?*anyopaque,
    bitstream_buffer: ?*anyopaque,
    config: Config,
    width: u32,
    height: u32,
    pitch: u32,
    frame_idx: u64,
    buffer_format: u32,

    pub fn init(cu: *const cuda.Cuda, fps: u32) !Nvenc {
        // dlopen libnvidia-encode
        const lib = std.c.dlopen("libnvidia-encode.so.1", .{ .LAZY = true }) orelse blk: {
            break :blk std.c.dlopen("libnvidia-encode.so", .{ .LAZY = true }) orelse {
                std.debug.print("NVENC: failed to load libnvidia-encode.so\n", .{});
                return error.NvencInitFailed;
            };
        };
        errdefer _ = std.c.dlclose(lib);

        // Get NvEncodeAPICreateInstance
        const create_instance_sym = std.c.dlsym(lib, "NvEncodeAPICreateInstance") orelse {
            std.debug.print("NVENC: NvEncodeAPICreateInstance not found\n", .{});
            return error.NvencInitFailed;
        };
        const createInstance: CreateInstanceFn = @ptrCast(create_instance_sym);

        // Populate function table
        var fns = ApiFunctionList{};
        var status = createInstance(&fns);
        if (status != .success) {
            std.debug.print("NVENC: NvEncodeAPICreateInstance failed: {}\n", .{@intFromEnum(status)});
            return error.NvencInitFailed;
        }

        // Open encode session with CUDA context
        var session_params = OpenEncodeSessionExParams{
            .device = @ptrCast(cu.ctx),
        };
        var encoder_handle: ?*anyopaque = null;
        const openSession = fns.nvEncOpenEncodeSessionEx orelse return error.NvencInitFailed;
        status = openSession(&session_params, &encoder_handle);
        if (status != .success or encoder_handle == null) {
            logNvencError(&fns, encoder_handle, "nvEncOpenEncodeSessionEx", status);
            return error.NvencInitFailed;
        }

        // Query encoder capabilities
        if (fns.nvEncGetEncodeCaps) |getCaps| {
            const caps = [_]struct { id: u32, name: []const u8 }{
                .{ .id = NV_ENC_CAPS_NUM_MAX_BFRAMES, .name = "max_bframes" },
                .{ .id = NV_ENC_CAPS_WIDTH_MAX, .name = "width_max" },
                .{ .id = NV_ENC_CAPS_HEIGHT_MAX, .name = "height_max" },
                .{ .id = NV_ENC_CAPS_NUM_MAX_TEMPORAL_LAYERS, .name = "max_temporal_layers" },
                .{ .id = NV_ENC_CAPS_SUPPORT_WEIGHTED_PREDICTION, .name = "weighted_prediction" },
                .{ .id = NV_ENC_CAPS_SUPPORT_BFRAME_REF_MODE, .name = "bframe_ref_mode" },
                .{ .id = NV_ENC_CAPS_SUPPORT_LOOKAHEAD, .name = "lookahead" },
                .{ .id = NV_ENC_CAPS_SUPPORT_CONSTRAINED_ENCODING, .name = "constrained_encoding" },
                .{ .id = NV_ENC_CAPS_SUPPORT_INTRA_REFRESH, .name = "intra_refresh" },
                .{ .id = NV_ENC_CAPS_SUPPORT_10BIT_ENCODE, .name = "10bit" },
                .{ .id = NV_ENC_CAPS_SUPPORT_TEMPORAL_AQ, .name = "temporal_aq" },
                .{ .id = NV_ENC_CAPS_SUPPORT_EMPHASIS_LEVEL_MAP, .name = "emphasis_level_map" },
                .{ .id = NV_ENC_CAPS_SUPPORT_MULTIPLE_REF_FRAMES, .name = "multiple_ref_frames" },
                .{ .id = NV_ENC_CAPS_SUPPORT_ALPHA_LAYER, .name = "alpha_layer" },
            };
            for (caps) |cap| {
                var param = EncodeCapsParam{ .capsToQuery = cap.id };
                var val: i32 = 0;
                status = getCaps(encoder_handle, codec_av1_guid, &param, &val);
                if (status == .success) {
                    std.log.info("NVENC cap {s}: {d}", .{ cap.name, val });
                } else {
                    std.log.info("NVENC cap {s}: query failed", .{cap.name});
                }
            }
        }

        // Query preset config for good defaults
        const getPresetConfigEx = fns.nvEncGetEncodePresetConfigEx orelse return error.NvencInitFailed;
        var preset_config = PresetConfig{};
        status = getPresetConfigEx(encoder_handle, codec_av1_guid, preset_p4_guid, NV_ENC_TUNING_INFO_HIGH_QUALITY, &preset_config);
        if (status != .success) {
            logNvencError(&fns, encoder_handle, "nvEncGetEncodePresetConfigEx", status);
            _ = (fns.nvEncDestroyEncoder orelse unreachable)(encoder_handle);
            return error.NvencInitFailed;
        }

        // Start with preset defaults, override what we need
        var config = preset_config.presetCfg;
        config.version = structVersionHigh(8);
        config.profileGUID = profile_av1_main_guid;
        config.gopLength = 0xFFFFFFFF; // infinite — keyframes only on PLI request
        config.frameIntervalP = 1; // no B-frames
        config.rcParams.rateControlMode = NV_ENC_PARAMS_RC_VBR;
        config.rcParams.averageBitRate = 500_000; // 500 kbps target
        config.rcParams.maxBitRate = 1_000_000; // 1 Mbps ceiling
        config.rcParams.vbvBufferSize = 500_000; // 1 second of average bitrate
        config.rcParams.vbvInitialDelay = 250_000; // half buffer

        // AV1 specific config
        const av1 = config.av1Config();
        av1.idrPeriod = 0xFFFFFFFF; // infinite — matches gopLength
        av1.bitfield_flags.repeatSeqHdr = 1;
        av1.bitfield_flags.enableIntraRefresh = 1;
        av1.intraRefreshPeriod = fps; // refresh over 1 second of frames
        av1.intraRefreshCnt = fps / 5; // 6 frames of intra bands per cycle at 30fps
        av1.bitfield_flags.chromaFormatIDC = 1; // 4:2:0
        // Color metadata — NvFBC captures sRGB framebuffer, signal BT.709 so browsers
        // decode consistently instead of guessing (0 = "unspecified" per AV1 spec).
        av1.colorPrimaries = 1; // BT.709
        av1.transferCharacteristics = 1; // BT.709
        av1.matrixCoefficients = 1; // BT.709
        av1.colorRange = 0; // limited range — NVENC's internal RGB→YUV uses limited (16-235)

        const buffer_format: u32 = NV_ENC_BUFFER_FORMAT_ARGB;

        // Initialize encoder — ARGB input matches NvFBC BGRA byte order on LE.
        const initEncoder = fns.nvEncInitializeEncoder orelse return error.NvencInitFailed;
        var init_params = InitializeParams{
            .encodeWidth = cu.frame_width,
            .encodeHeight = cu.frame_height,
            .darWidth = cu.frame_width,
            .darHeight = cu.frame_height,
            .frameRateNum = fps,
            .frameRateDen = 1,
            .encodeConfig = &config,
        };

        status = initEncoder(encoder_handle, &init_params);
        if (status != .success) {
            logNvencError(&fns, encoder_handle, "nvEncInitializeEncoder", status);
            _ = (fns.nvEncDestroyEncoder orelse unreachable)(encoder_handle);
            return error.NvencInitFailed;
        }

        std.debug.print("NVENC: initialized AV1 encoder {}x{}\n", .{ cu.frame_width, cu.frame_height });

        // Register CUDA device pointer as NVENC input
        const registerResource = fns.nvEncRegisterResource orelse return error.NvencInitFailed;
        var reg = RegisterResource{
            .width = cu.frame_width,
            .height = cu.frame_height,
            .pitch = @intCast(cu.device_pitch),
            .resourceToRegister = @ptrFromInt(cu.device_ptr),
            .bufferFormat = buffer_format,
        };
        status = registerResource(encoder_handle, &reg);
        if (status != .success) {
            logNvencError(&fns, encoder_handle, "nvEncRegisterResource", status);
            _ = (fns.nvEncDestroyEncoder orelse unreachable)(encoder_handle);
            return error.NvencInitFailed;
        }

        // Create bitstream output buffer
        const createBitstream = fns.nvEncCreateBitstreamBuffer orelse return error.NvencInitFailed;
        var bs = CreateBitstreamBuffer{};
        status = createBitstream(encoder_handle, &bs);
        if (status != .success) {
            logNvencError(&fns, encoder_handle, "nvEncCreateBitstreamBuffer", status);
            _ = (fns.nvEncUnregisterResource orelse unreachable)(encoder_handle, reg.registeredResource);
            _ = (fns.nvEncDestroyEncoder orelse unreachable)(encoder_handle);
            return error.NvencInitFailed;
        }

        return .{
            .lib = lib,
            .fns = fns,
            .encoder = encoder_handle,
            .registered_resource = reg.registeredResource,
            .bitstream_buffer = bs.bitstreamBuffer,
            .config = config,
            .width = cu.frame_width,
            .height = cu.frame_height,
            .pitch = @intCast(cu.device_pitch),
            .frame_idx = 0,
            .buffer_format = buffer_format,
        };
    }

    /// Encode one frame. Returns the encoded bitstream or null if the encoder
    /// needs more input (shouldn't happen with no B-frames, but handled).
    /// The returned EncodedFrame.data is valid until the next encodeFrame call.
    pub fn encodeFrame(self: *Nvenc, force_keyframe: bool) !?EncodedFrame {
        // Map the registered CUDA resource
        var map = MapInputResource{ .registeredResource = self.registered_resource };
        var status = (self.fns.nvEncMapInputResource orelse return error.NvencEncodeFailed)(self.encoder, &map);
        if (status != .success) {
            logNvencError(&self.fns, self.encoder, "nvEncMapInputResource", status);
            return error.NvencEncodeFailed;
        }

        // Build pic params
        var pic = PicParams{
            .inputWidth = self.width,
            .inputHeight = self.height,
            .inputPitch = self.pitch,
            .inputBuffer = map.mappedResource,
            .outputBitstream = self.bitstream_buffer,
            .bufferFmt = self.buffer_format,
            .inputTimeStamp = self.frame_idx,
        };
        if (force_keyframe) {
            pic.encodePicFlags = NV_ENC_PIC_FLAG_FORCEIDR;
        }

        // Encode
        status = (self.fns.nvEncEncodePicture orelse return error.NvencEncodeFailed)(self.encoder, &pic);

        if (status == .err_need_more_input) {
            _ = (self.fns.nvEncUnmapInputResource orelse unreachable)(self.encoder, map.mappedResource);
            self.frame_idx += 1;
            return null;
        }
        if (status != .success) {
            _ = (self.fns.nvEncUnmapInputResource orelse unreachable)(self.encoder, map.mappedResource);
            logNvencError(&self.fns, self.encoder, "nvEncEncodePicture", status);
            return error.NvencEncodeFailed;
        }

        // Lock bitstream to read encoded data
        var lock = LockBitstream{ .outputBitstream = self.bitstream_buffer };
        status = (self.fns.nvEncLockBitstream orelse return error.NvencEncodeFailed)(self.encoder, &lock);

        // Unmap now that bitstream is ready
        _ = (self.fns.nvEncUnmapInputResource orelse unreachable)(self.encoder, map.mappedResource);

        if (status != .success) {
            logNvencError(&self.fns, self.encoder, "nvEncLockBitstream", status);
            return error.NvencEncodeFailed;
        }

        const data_ptr: [*]const u8 = @ptrCast(lock.bitstreamBufferPtr orelse {
            self.unlockBitstream();
            return error.NvencEncodeFailed;
        });
        const frame = EncodedFrame{
            .data = data_ptr[0..lock.bitstreamSizeInBytes],
            .is_key = lock.pictureType == 3, // NV_ENC_PIC_TYPE_IDR = 3
            .pts = self.frame_idx,
        };

        self.frame_idx += 1;
        return frame;
    }

    /// Unlock the bitstream after reading. Must be called after each successful encodeFrame.
    pub fn unlockBitstream(self: *Nvenc) void {
        _ = (self.fns.nvEncUnlockBitstream orelse unreachable)(self.encoder, self.bitstream_buffer);
    }

    /// Send EOS to signal end of stream. Call drainFrame() afterwards to
    /// retrieve any buffered output.
    pub fn flush(self: *Nvenc) !void {
        var pic = PicParams{
            .inputWidth = self.width,
            .inputHeight = self.height,
            .inputPitch = self.pitch,
            .encodePicFlags = NV_ENC_PIC_FLAG_EOS,
        };
        const status = (self.fns.nvEncEncodePicture orelse return error.NvencEncodeFailed)(self.encoder, &pic);
        if (status != .success and status != .err_need_more_input) {
            logNvencError(&self.fns, self.encoder, "nvEncEncodePicture (EOS)", status);
            return error.NvencEncodeFailed;
        }
    }

    /// Retrieve one buffered frame after flush(). Returns null when drained.
    /// Caller must call unlockBitstream() after consuming each returned frame.
    pub fn drainFrame(self: *Nvenc) !?EncodedFrame {
        var lock = LockBitstream{
            .outputBitstream = self.bitstream_buffer,
            .doNotWaitFlags = 1, // NV_ENC_LOCK_BITSTREAM_DO_NOT_WAIT
        };
        const status = (self.fns.nvEncLockBitstream orelse return error.NvencEncodeFailed)(self.encoder, &lock);
        if (status == .err_need_more_input) return null;
        if (status == .err_lock_busy) return null;
        if (status != .success) return null;
        if (lock.bitstreamSizeInBytes == 0) {
            self.unlockBitstream();
            return null;
        }

        const data_ptr: [*]const u8 = @ptrCast(lock.bitstreamBufferPtr orelse {
            self.unlockBitstream();
            return null;
        });
        const frame = EncodedFrame{
            .data = data_ptr[0..lock.bitstreamSizeInBytes],
            .is_key = lock.pictureType == 3,
            .pts = self.frame_idx,
        };
        self.frame_idx += 1;
        return frame;
    }

    pub fn deinit(self: *Nvenc) void {
        if (self.bitstream_buffer) |bs| {
            _ = (self.fns.nvEncDestroyBitstreamBuffer orelse unreachable)(self.encoder, bs);
        }
        if (self.registered_resource) |rr| {
            _ = (self.fns.nvEncUnregisterResource orelse unreachable)(self.encoder, rr);
        }
        _ = (self.fns.nvEncDestroyEncoder orelse unreachable)(self.encoder);
        _ = std.c.dlclose(self.lib);
    }
};

fn logNvencError(fns: *const ApiFunctionList, encoder: ?*anyopaque, context: []const u8, status: Status) void {
    const err_str = if (fns.nvEncGetLastErrorString) |f| f(encoder) else null;
    std.debug.print("NVENC: {s} failed: {s} ({})\n", .{
        context,
        if (err_str) |s| std.mem.span(s) else "unknown",
        @intFromEnum(status),
    });
}

// ============================================================================
// Comptime assertions
// ============================================================================

comptime {
    if (@sizeOf(Guid) != 16) @compileError("Guid size mismatch");
    if (@sizeOf(QP) != 12) @compileError("QP size mismatch");
    if (@sizeOf(MeHintCounts) != 16) @compileError("MeHintCounts size mismatch");
}
