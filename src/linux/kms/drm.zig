/// libdrm C bindings for KMS framebuffer capture.
///
/// Uses @cImport for the DRM headers. If this fails on some systems,
/// the fallback is to manually declare the ~15 externs we need.

const c = @cImport({
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
    @cInclude("drm_fourcc.h");
});

// Re-export the types and functions we use

// ─── Constants ──────────────────────────────────────────────────────────────

pub const DRM_CLIENT_CAP_UNIVERSAL_PLANES = c.DRM_CLIENT_CAP_UNIVERSAL_PLANES;
pub const DRM_CLIENT_CAP_ATOMIC = c.DRM_CLIENT_CAP_ATOMIC;
pub const DRM_MODE_OBJECT_PLANE = c.DRM_MODE_OBJECT_PLANE;
pub const DRM_MODE_FB_MODIFIERS = c.DRM_MODE_FB_MODIFIERS;
// DRM_FORMAT_MOD_INVALID = fourcc_mod_code(NONE, DRM_FORMAT_RESERVED)
// Zig's C translator can't handle the nested macros, so hardcode the value.
pub const DRM_FORMAT_MOD_INVALID: u64 = 0x00ffffffffffffff;

// Property type flags
pub const DRM_MODE_PROP_LEGACY_TYPE = c.DRM_MODE_PROP_LEGACY_TYPE;
pub const DRM_MODE_PROP_EXTENDED_TYPE = c.DRM_MODE_PROP_EXTENDED_TYPE;
pub const DRM_MODE_PROP_SIGNED_RANGE = c.DRM_MODE_PROP_SIGNED_RANGE;
pub const DRM_MODE_PROP_RANGE = c.DRM_MODE_PROP_RANGE;
pub const DRM_MODE_PROP_ENUM = c.DRM_MODE_PROP_ENUM;
pub const DRM_MODE_PROP_BITMASK = c.DRM_MODE_PROP_BITMASK;

// ─── Types ──────────────────────────────────────────────────────────────────

pub const ModeRes = c.drmModeRes;
pub const ModeConnector = c.drmModeConnector;
pub const ModeProperty = c.drmModePropertyRes;
pub const ModePlaneRes = c.drmModePlaneRes;
pub const ModePlane = c.drmModePlane;
pub const ModeFB2 = c.drmModeFB2;
pub const ModeObjectProperties = c.drmModeObjectProperties;
pub const ModePropertyEnum = c.struct_drm_mode_property_enum;

// ─── Functions ──────────────────────────────────────────────────────────────

pub const setClientCap = c.drmSetClientCap;
pub const modeGetResources = c.drmModeGetResources;
pub const modeFreeResources = c.drmModeFreeResources;
pub const modeGetConnectorCurrent = c.drmModeGetConnectorCurrent;
pub const modeFreeConnector = c.drmModeFreeConnector;
pub const modeGetProperty = c.drmModeGetProperty;
pub const modeFreeProperty = c.drmModeFreeProperty;
pub const modeGetPlaneResources = c.drmModeGetPlaneResources;
pub const modeFreePlaneResources = c.drmModeFreePlaneResources;
pub const modeGetPlane = c.drmModeGetPlane;
pub const modeFreePlane = c.drmModeFreePlane;
pub const modeGetFB2 = c.drmModeGetFB2;
pub const modeFreeFB2 = c.drmModeFreeFB2;
pub const primeHandleToFD = c.drmPrimeHandleToFD;
pub const closeBufferHandle = c.drmCloseBufferHandle;
pub const modeObjectGetProperties = c.drmModeObjectGetProperties;
pub const modeFreeObjectProperties = c.drmModeFreeObjectProperties;
