# VAAPI AV1 Encoding on Linux — Research Summary

## What is VAAPI?

**Video Acceleration API (VA-API)** is an open-source library and API specification (originally by Intel, now freedesktop.org) that provides a uniform interface to GPU hardware video acceleration on Linux. Unlike NVENC (NVIDIA-proprietary), VAAPI is vendor-neutral — the same C API works across Intel and AMD GPUs via different driver backends.

**Key components:**
- **libva** — The core C library (`va.h`, `va_enc_av1.h`, etc.)
- **Driver backends** — `intel-media-driver` (iHD) for Intel, `libva-mesa-driver` (radeonsi) for AMD
- **libva-utils** — Test/sample programs including AV1 encode samples

---

## GPU Support Matrix for AV1 Encoding via VAAPI

| GPU Family | AV1 Encode? | Media Engine | VAAPI Driver | Min Requirements |
|---|---|---|---|---|
| **Intel Arc A-series** (A310, A380, A580, A750, A770) | Yes | Xe HPG (Gen 12.5), 2x MFX engines | `intel-media-driver` (iHD) | Kernel 6.2+, libva 2.14+ |
| **Intel Arc B-series** (B570, B580) | Yes | Xe2, improved speed | `intel-media-driver` (iHD) | Kernel 6.12+ |
| **Intel Meteor Lake / Core Ultra** (14th Gen mobile+) | Yes | Gen 12.7 iGPU | `intel-media-driver` (iHD) | Kernel 6.2+ |
| **AMD RX 7000** (7600, 7700XT, 7800XT, 7900XT/XTX) | Yes | VCN 4.0 | `libva-mesa-driver` (radeonsi) | Mesa 23.3+, recent kernel |
| **AMD RX 9000** (RDNA4) | Yes | VCN 5.0 (improved quality) | `libva-mesa-driver` (radeonsi) | Mesa 25.x+ |
| **AMD RX 6000** (RDNA2) and older | **No** (decode only) | VCN 3.0 | — | — |
| **NVIDIA (any)** | **No** | — | — | NVIDIA uses NVENC, not VAAPI. `nvidia-vaapi-driver` is decode-only shim |

### Caveats
- Some distros (Manjaro, Fedora) build Mesa without non-free codec support — AV1 may be the only encoder available, but H.264/HEVC encode could be missing
- AMD VCN 4.0 had a bug requiring frame height aligned to 64px (fixed in VCN 5.0)
- Intel HuC firmware must be loaded for proper bitrate control (`options i915 enable_guc=2`)

---

## Quality & Performance Comparison (AV1 HW Encoders)

**Ranking by encoding quality (VMAF scores):**
1. **NVIDIA NVENC (RTX 40/50 series)** — Best quality, most mature ecosystem. Dual encoders on RTX 4070 Ti+. Years of OBS/streaming integration.
2. **Intel Arc QSV/VAAPI** — Remarkably close to NVENC at a fraction of GPU cost. Best value for dedicated AV1 encoding. VAAPI-native on Linux.
3. **AMD VCN 4.0 (RX 7000)** — Competitive, sits between Intel and NVIDIA. Rapidly improving. VCN 5.0 (RX 9000) closes the gap further.

**For real-time streaming specifically:**
- All three can do 1080p60 AV1 encoding in real-time
- AMD struggles at 4K60 with high-quality presets
- AV1 delivers ~30-50% bitrate savings over H.264 at equal quality
- Software SVT-AV1 still beats all HW encoders on quality, but is too slow for real-time

---

## VAAPI C API for AV1 Encoding

### Core API Flow

```
vaInitialize()
  → vaQueryConfigEntrypoints()     // check AV1 encode support
  → vaCreateConfig(VAProfileAV1*)  // create encoder config
  → vaCreateSurfaces()             // allocate input surfaces (can import DMA-BUF)
  → vaCreateContext()              // create encoding context

Per-frame loop:
  → vaBeginPicture()
  → vaRenderPicture() with:
      - VAEncSequenceParameterBufferAV1  (sequence header, once/on change)
      - VAEncPictureParameterBufferAV1   (per-frame: refs, QP, filters, tiles)
      - VAEncTileGroupBufferAV1          (tile boundaries)
  → vaEndPicture()
  → vaSyncSurface()                // wait for encode to finish
  → vaMapBuffer() / vaUnmapBuffer() // retrieve encoded bitstream
```

### Key Structs (from `va_enc_av1.h`)

- **VAEncSequenceParameterBufferAV1** — Profile, level, tier, GOP, bitrate, superblock size, tool enables
- **VAEncPictureParameterBufferAV1** — Frame dimensions, reference frames, QP, loop filter, CDEF, restoration, tiles
- **VAEncTileGroupBufferAV1** — Tile group start/end positions
- **VAEncSegParamAV1** — Segmentation parameters (up to 8 segments)
- **VAConfigAttribValEncAV1/Ext1/Ext2** — Capability queries (supported features, tile constraints)

### Low-Latency Configuration
- Use `VAEntrypointEncSliceLP` (low-power encoding entry point) for minimum latency
- Set high `quality_level` (1=best quality/slow, 7=fastest/lowest quality on Intel)
- Disable B-frames (P-only GOP, matching Zerocast's current NVENC config)
- Use CBR or constrained VBR rate control
- Single tile for simplicity, or 2 tiles for parallelism

### DMA-BUF Surface Import
VAAPI can import DMA-BUF file descriptors directly as encoding input surfaces via `vaCreateSurfaces()` with `VASurfaceAttribExternalBuffers`. This enables zero-copy pipelines:

```
KMS framebuffer → DMA-BUF fd → VAAPI surface import → HW encode
```

This is directly analogous to Zerocast's current pipeline:
```
KMS framebuffer → DMA-BUF fd → EGL import → CUDA copy → NVENC
```

The VAAPI path could potentially be **shorter** (no EGL→CUDA hop) since VAAPI natively understands DMA-BUF.

---

## Screen Capture Paths: X11 vs Wayland

### X11 Capture Options

| Method | Zero-copy? | Privileged? | Notes |
|---|---|---|---|
| **DRI3 `BufferFromPixmap`** | Yes | **No** | Best path. Exports any X pixmap as DMA-BUF fd. No KMS needed. Works on AMD/Intel Mesa drivers. |
| **KMS framebuffer grab** | Yes | Yes (`CAP_SYS_ADMIN`) | Captures CRTC framebuffer directly. Needed for NVIDIA (no DRI3 DMA-BUF). Needed for Wayland-on-NVIDIA future. |
| **NvFBC** | Yes | No (but NVIDIA-only) | NVIDIA's proprietary capture API. What Zerocast uses today. |
| **XShm** | No (GPU→CPU→GPU) | No | Legacy. ~10fps at high res, lags X server. Terrible for real-time. |
| **XComposite** | Partial | No | Window-only (not full screen). Crashes under EGL. Breaks with EGL-based apps. |

**Winner for VAAPI on X11: DRI3 `BufferFromPixmap`** — unprivileged, zero-copy, no KMS helper needed.

#### DRI3 BufferFromPixmap Pipeline
```
X11 root window (composite) → DRI3 BufferFromPixmap → DMA-BUF fd → VAAPI surface import → AV1 encode
```

How it works:
1. Call `xcb_dri3_buffers_from_pixmap()` on the composite overlay window's pixmap
2. Receive DMA-BUF fd(s) + format/modifier info
3. Import directly into VAAPI as encoding input surface
4. **No privileges, no KMS helper, no EGL hop**

Caveats:
- Requires the X server to use DRI3 (standard on modern Mesa-based setups)
- Does NOT work on NVIDIA proprietary drivers (they don't expose DRI3 DMA-BUF)
- The composite extension must be active (it is by default on all modern X servers with compositing WMs)

### Wayland Capture Options

| Method | Status | DMA-BUF? | Compositor Support |
|---|---|---|---|
| **`ext-image-copy-capture-v1`** | Official (merged Aug 2024) | Yes, first-class | wlroots-based (Sway, Hyprland, etc.). KDE/GNOME adoption pending. |
| **`wlr-screencopy-unstable-v1`** | Deprecated | Yes | wlroots-based only. Being replaced by the above. |
| **PipeWire + xdg-desktop-portal** | Stable | Yes (DMA-BUF frames) | GNOME, KDE, wlroots (via portal backends). Most portable today. |
| **`zcosmic-screencopy-v2`** | COSMIC-only | Yes | System76's COSMIC desktop only. Similar API to ext-image-copy-capture. |

**Best Wayland paths:**

1. **`ext-image-copy-capture-v1`** (new official protocol) — Direct DMA-BUF capture, zero-copy, no portal indirection. The compositor advertises supported DMA-BUF formats and the DRM device to allocate on. Most aligned with Zerocast's philosophy (direct, minimal, zero-copy). But adoption is still rolling out.

2. **PipeWire** — Most portable today (works on GNOME, KDE, wlroots). Frames delivered as DMA-BUF when supported, enabling zero-copy to VAAPI. More moving parts (portal daemon, PipeWire daemon, D-Bus).

#### ext-image-copy-capture Pipeline (Wayland, preferred)
```
Compositor → ext-image-copy-capture-v1 → DMA-BUF buffer → VAAPI surface import → AV1 encode
```

#### PipeWire Pipeline (Wayland, most portable)
```
Compositor → xdg-desktop-portal → PipeWire stream → DMA-BUF frame → VAAPI surface import → AV1 encode
```

### Reference Implementation: wl-screenrec

[wl-screenrec](https://github.com/russelltg/wl-screenrec) is a Rust tool that does exactly this pattern:
- Uses `wlr-screencopy` (and `ext-image-copy-capture`) for DMA-BUF capture
- GPU-side pixel format conversion
- VAAPI hardware encoding
- **Raw video data never touches the CPU**

This is the closest existing open-source implementation to what a VAAPI Zerocast path would look like.

---

## Complete Pipeline Summary

### Current: NVIDIA (X11)
```
NvFBC → GL texture → CUDA copy → NVENC AV1 → WebRTC
```
- 4 hops, NVIDIA-only, unprivileged

### Option A: VAAPI on X11 (AMD/Intel) — No KMS needed
```
DRI3 BufferFromPixmap → DMA-BUF fd → VAAPI import → VAAPI AV1 encode → WebRTC
```
- 3 hops, unprivileged, zero-copy, fewest moving parts

### Option B: VAAPI on Wayland (AMD/Intel) — ext-image-copy-capture
```
ext-image-copy-capture-v1 → DMA-BUF buffer → VAAPI import → VAAPI AV1 encode → WebRTC
```
- 3 hops, unprivileged (compositor grants access), zero-copy

### Option C: VAAPI on Wayland (AMD/Intel) — PipeWire
```
xdg-desktop-portal → PipeWire → DMA-BUF frame → VAAPI import → VAAPI AV1 encode → WebRTC
```
- 4 hops, most portable across compositors, still zero-copy with DMA-BUF

### Option D: KMS capture (any display server, privileged)
```
zerocast-kms (CAP_SYS_ADMIN) → DMA-BUF fd → VAAPI import → VAAPI AV1 encode → WebRTC
```
- 3 hops, works on X11 AND Wayland AND headless, but needs the privileged helper

---

## What This Means for Zerocast

### Key Architectural Differences

| Aspect | Current (NVENC) | VAAPI Path |
|---|---|---|
| X11 Capture | NvFBC (NVIDIA-only) | DRI3 BufferFromPixmap (unprivileged, zero-copy) |
| Wayland Capture | Not supported yet | ext-image-copy-capture or PipeWire |
| Memory model | CUDA device memory | DMA-BUF / VAAPI surfaces |
| Encoder API | NVENC SDK (C) | libva (C) |
| Color input | ARGB direct | NV12 typically (may need GPU-side conversion) |
| GPU binding | NVIDIA-only | Intel + AMD |
| KMS helper needed? | No (uses NvFBC) | No on X11 (DRI3). No on Wayland (protocol). Optional for headless/fallback. |
| Session limit | NVENC has limits | No concurrent session limit on AMD |

### What Would Need to Change
1. **New `vaapi.zig` module** — parallel to `nvenc.zig`, wrapping libva C API
2. **New `dri3_capture.zig` module** — X11 capture via DRI3 BufferFromPixmap (replaces NvFBC for AMD/Intel)
3. **New `wayland_capture.zig` module** — ext-image-copy-capture-v1 client (for Wayland)
4. **Encoder abstraction** — currently none exists; `encoder.zig` hardcodes NVENC. Need a union or interface type
5. **Color space** — VAAPI typically expects NV12; may need GPU-side ARGB→NV12 conversion via `vpp` (VAAPI video processing)
6. **Build system** — link against `libva`, `libva-drm`, `xcb-dri3` conditionally
7. **Runtime detection** — query display server (X11 vs Wayland), query VAAPI encode support, select pipeline

### What Stays the Same
- WebRTC transport layer (libdatachannel, codec-agnostic at transport level)
- AV1-only policy (VAAPI supports AV1 encode on target GPUs)
- Session/signaling infrastructure (unchanged)
- `zerocast-kms` helper (kept as optional fallback / NVIDIA-Wayland path, not needed for VAAPI)

---

## References

- [Arch Wiki: Hardware Video Acceleration](https://wiki.archlinux.org/title/Hardware_video_acceleration)
- [libva API Documentation](https://intel.github.io/libva/)
- [libva AV1 Encode Header (va_enc_av1.h)](https://github.com/intel/libva/blob/master/va/va_enc_av1.h)
- [libva-utils Encode Samples](https://github.com/intel/libva-utils/tree/master/encode)
- [intel-media-driver](https://github.com/intel/media-driver)
- [AMD Mesa AV1 VA-API Encode (Phoronix)](https://www.phoronix.com/news/AMD-Mesa-AV1-VA-API-Encode)
- [VA-API Library 2.14 — AV1 Encode Interface (Phoronix)](https://www.phoronix.com/news/VA-API-libva-2.14-Released)
- [Intel VAAPI Overview](https://www.intel.com/content/www/us/en/developer/articles/technical/linuxmedia-vaapi.html)
- [OBS Zero-Copy KMS Capture](https://obsproject.com/forum/threads/experimental-zero-copy-screen-capture-on-linux.101262/)
- [obs-kmsgrab (DRM/DMA-BUF capture)](https://github.com/rhenium/obs-kmsgrab)
- [AV1 Encoder Quality Comparison (Gianni Rosato)](https://giannirosato.com/blog/post/nvenc-v-qsv/)
- [Intel Arc AV1 vs AMD vs NVIDIA (Tom's Hardware)](https://www.tomshardware.com/news/intel-arc-av1-encoder-dominates-nvenc)
- [AMD RX 7900 AV1 Encoder (TechSpot)](https://www.techspot.com/news/96945-amd-radeon-rx-7900-av1-encoder-almost-par.html)
- [Real-Time Video Pipelines with V4L2/DRM/KMS (OpenLib)](https://openlib.io/real-time-video-processing-pipelines-with-v4l2-drm-kms-and-hardware-encoders-in-linux/)
