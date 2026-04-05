# Intel VA-API + Embedded Wayland Compositor — Implementation Plan

## Context

We're adding a second encoder backend (Intel VA-API HEVC) alongside the existing NVIDIA NVENC pipeline, using an embedded Wayland compositor (wlroots) instead of X11 for headless app rendering and capture. This approach works on any GPU with EGL support. NVIDIA cannot use this path today (DMA-BUF → CUDA import not supported on desktop GPUs), so the X11+NvFBC pipeline remains for NVIDIA.

## What's Done

### 1. VA-API encoder backend
- `src/linux/vaapi/vaapi.zig` — VA-API encoder: codec detection (AV1→HEVC fallback), double-buffered recon surfaces, DMA-BUF import, encode lifecycle
- `src/linux/vaapi/encoder_backend.zig` — `EncodeBackend` vtable with DMA-BUF input mode and LRU surface cache
- `src/linux/vaapi/hevc_params.c/.h` — C helper for HEVC encode parameter submission (va_enc_hevc.h bitfield unions break Zig translate-c)
- Build system integration in `build_linux.zig` (links libva, libva-drm)

**FIXED (2026-04-05):** Encoder now produces valid HEVC bitstream (90 frames, 1920x1080, ffprobe validates).
Root cause: Intel iHD HEVC EncSliceLP requires GPB (Generalized P→B) encoding:
  1. Non-IDR frames must use B-slices (slice_type=0), NOT P-slices — L0=L1 (both ref lists same picture)
  2. Packed slice header (VAEncPackedHeaderSlice) required on every frame
  3. Packed VPS/SPS/PPS (VAEncPackedHeaderSequence) with start codes + emulation prevention bytes
  4. SPS dimensions must be CTU-aligned (64px), with conformance window for cropping

**Key VA-API patterns:**
- `vaCreateContext` only needs reconstruction surfaces (not input surfaces) — matches FFmpeg's pattern
- Input surfaces can come from any source (pre-allocated, DMA-BUF import) and are passed to `vaBeginPicture` independently
- DMA-BUF import via `vaCreateSurfaces` with `VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2` + `VADRMPRIMESurfaceDescriptor`
- wlroots swapchain reuses 2-3 fds, so surface cache is tiny (4 entries, LRU eviction)

### 2. Embedded Wayland compositor
- `src/linux/wayland/compositor.zig` — wlroots-based headless compositor in Zig
- `wlroots/` git submodule at 0.17.4 (0.20 needs newer wayland-server than Ubuntu 24.04 ships)
- `libs/wlroots/` — pre-built static lib + generated headers (committed to repo, rebuild only on submodule update)
- Build system integration in `build_linux.zig`

**Working:**
- Headless output at arbitrary resolution on any GPU (no display, no dongle)
- `WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128` selects Intel GPU
- Native Wayland apps connect and render (tested gnome-calculator)
- DMA-BUF extraction from scene graph via `wlr_scene_output_build_state` → `wlr_buffer_get_dmabuf`
- Frame callback delivers real `CapturedFrame` with DMA-BUF attributes
- xdg_shell for window management, seat for input focus
- No Xwayland needed — modern apps (GTK, Qt, Electron) are native Wayland

**Key wlroots patterns (0.17):**
- `wlr_output_init_render(output, allocator, renderer)` MUST be called before any commit
- Headless frame loop: enable commit → timer → frame signal → scene commit → timer → ...
- `wlr_scene_output_build_state` renders scene into `wlr_output_state` with buffer
- `wlr_buffer_get_dmabuf` exports buffer as DMA-BUF (fd, format, modifier, stride)
- xdg_shell event is `new_surface` in 0.17 (renamed to `new_toplevel` in 0.20)
- Listener callbacks need `callconv(.c)` in Zig
- `@fieldParentPtr` returns allowzero — use manual offset calculation for container_of pattern

### 3. End-to-end pipeline wiring
- `src/linux/wayland/app_share.zig` — Wayland app share orchestrator (parallel to `src/linux/x11/app_share.zig`)
- Compositor init → WAYLAND_DISPLAY env → fork+exec app → frame callback → DMA-BUF → VA-API encode → WebRTC
- DMA-BUF import into VA-API as encode input surface (zero-copy, same GPU)
- `--gpu intel` CLI flag dispatches to Wayland/VA-API path in daemon
- `GpuBackend` enum in control.zig: `auto`, `nvidia`, `intel`
- Full resize support (compositor resize → encoder teardown/rebuild)
- Same `EncodeBackend` vtable — shared `Encoder.processFrame` and `BroadcastSession` unchanged

### 4. Hardware validated
- Intel Alder Lake GT1 (i9-12900K) UHD 770 at `/dev/dri/renderD128`
- VA-API HEVC encode via `VAEntrypointEncSliceLP` (iHD driver 24.1.0)
- No AV1 encode on this iGPU (needs Arc/Meteor Lake+)
- VA-API supports RGB32 input directly (XRGB/RGBX) — no NV12 conversion needed
- File capabilities (setcap) silently ignored on eCryptfs — install to /usr/local/bin

### 5. NVIDIA on Wayland — researched, not viable today
- DMA-BUF → CUDA import (`cuImportExternalMemory`) is Jetson-only, not desktop GPUs
- wlroots headless works on NVIDIA (driver 535+) but implicit sync bug causes flickering
- NvFBC PipeWire backend (Capture SDK 9.0, driver 570+) is the future path but not ready
- **Decision: keep X11+NvFBC for NVIDIA, Wayland+VA-API for Intel/AMD**

## What's Next (in order)

### Phase 1: Test end-to-end on Intel hardware
1. `./run.ts build` then `dist/bin/zerocast daemon` + `zerocast share app gnome-calculator --gpu intel`
2. Verify stream appears in browser with valid stats (bitrate, fps, resolution)
3. Debug any DMA-BUF format mismatches, surface import failures, or encode errors
4. Measure latency: compositor render → encode → send

### Phase 2: Input injection
1. Set seat capabilities (keyboard + pointer) in compositor
2. Forward input events from WebRTC data channel → Wayland seat
3. Wayland equivalent of XTEST — `wlr_seat_keyboard_notify_key`, `wlr_seat_pointer_notify_motion`
4. Wire into existing `InputHandler` interface

### Phase 3: Auto-detect GPU
1. Probe `/dev/dri/renderD*` for VA-API encode profiles at daemon startup
2. Check for NVIDIA (existing NvFBC detection)
3. `--gpu auto` (default): prefer NVIDIA if available, fall back to Intel/AMD VA-API
4. `--gpu intel` / `--gpu nvidia`: explicit override

### Phase 4: Replace wlroots (incremental)
Now that we understand what wlroots does for us (~8,000 lines of C for our use case), replace pieces bottom-up:
1. Headless backend (trivial, ~50 lines of Zig replaces 237 lines of C)
2. GBM allocator (thin libgbm wrapper, ~100 lines)
3. EGL/GLES2 renderer (~400-600 lines for single-buffer rendering)
4. Scene graph (hardest — damage tracking, visibility, transforms)
5. xdg_shell + wl_surface (Wayland protocol handling, ~600-800 lines)
Target: ~1,500-2,000 lines of Zig replacing 8,000 lines of C, purpose-built for our use case.

### Phase 5: Foveated encoding (ROI)
- Intel HEVC supports `VAEncROI` (rectangle-based, 32px granularity, works with VBR)
- Track cursor position / high-activity regions → submit as ROI rectangles
- AV1 ROI unverified on Intel — likely unsupported in current drivers
- NVENC emphasis map is H.264-only (dead end for AV1/HEVC)

### Phase 6: Clean up and test
1. Playwright test: verify stream appears in browser with valid stats
2. Power measurement: compare Intel iGPU encode vs NVIDIA
3. Latency measurement: capture → encode → decode → render in Chrome
4. Test with real apps (VS Code, Firefox, Electron apps)

## Build Commands

```bash
# Rebuild wlroots static lib (only after submodule update)
meson setup .zig-cache/wlroots-build wlroots \
  --default-library=static \
  -Dbackends=[] -Drenderers=gles2 -Dallocators=gbm \
  -Dxwayland=disabled -Dexamples=false -Dsession=disabled -Dxcb-errors=disabled
ninja -C .zig-cache/wlroots-build
cp .zig-cache/wlroots-build/libwlroots.a libs/wlroots/
cp -r .zig-cache/wlroots-build/include libs/wlroots/
cp .zig-cache/wlroots-build/protocol/*.h libs/wlroots/protocol/

# Build everything
./run.ts build

# Share an app on Intel GPU
ZEROCAST_URL=http://localhost:8787 dist/bin/zerocast daemon
# In another terminal:
dist/bin/zerocast share app gnome-calculator --gpu intel
```

## File Map

```
src/linux/
├── vaapi/
│   ├── vaapi.zig              # VA-API encoder (DMA-BUF import, codec detection, encode)
│   ├── encoder_backend.zig    # EncodeBackend vtable with DMA-BUF surface cache
│   ├── hevc_params.c          # C helper for HEVC encode params
│   └── hevc_params.h
├── wayland/
│   ├── app_share.zig          # Wayland app share orchestrator (compositor → VA-API → WebRTC)
│   └── compositor.zig         # Embedded wlroots headless compositor
├── x11/                       # Existing NVIDIA pipeline (unchanged)
│   ├── app_share.zig
│   ├── encoder_backend.zig
│   ├── nvfbc.zig, cuda.zig, nvenc.zig
│   └── ...
└── kms/                       # KMS helper (unchanged)

libs/wlroots/                  # Pre-built wlroots static lib + headers
wlroots/                       # Git submodule (0.17.4)
```

## Key Design Decisions

1. **Zig over C** — Use Zig for everything except where C is forced (va_enc_hevc.h bitfield unions). Keep C helpers minimal.
2. **Wayland over X11** — Embedded compositor is simpler, more portable, and future-proof. No NvFBC, no DRM master, no dongle.
3. **No Xwayland** — Modern apps are Wayland-native. Simplifies compositor significantly.
4. **No color conversion** — VA-API on Intel accepts RGB32 directly, same as NVENC accepts ARGB.
5. **DMA-BUF import (not export)** — Compositor produces buffers, VA-API consumes them. Goes with the natural flow of both wlroots and VA-API.
6. **Recon-only context** — `vaCreateContext` gets only reconstruction surfaces; input surfaces (including DMA-BUF imports) are passed separately to `vaBeginPicture`. Matches FFmpeg's proven pattern.
7. **wlroots 0.17.4** — Matches Ubuntu 24.04 system libs. Pre-built lib committed to repo; rebuild only on submodule update.
8. **NVIDIA stays on X11** — DMA-BUF → CUDA not supported on desktop GPUs. No forced unification.
9. **Frame pacing by compositor** — Headless output refresh rate controls frame rate. No LD_PRELOAD hacks needed (unlike X11 path).
