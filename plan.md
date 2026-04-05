# Intel VA-API + Embedded Wayland Compositor — Implementation Plan

## Context

We're adding a second encoder backend (Intel VA-API HEVC) alongside the existing NVIDIA NVENC pipeline, using an embedded Wayland compositor (wlroots) instead of X11 for headless app rendering and capture. This approach works on any GPU with EGL support and may eventually replace the X11+NvFBC pipeline for NVIDIA too.

## What's Done

### 1. VA-API encoder backend
- `src/linux/vaapi/vaapi.zig` — VA-API encoder: codec detection (AV1→HEVC fallback), double-buffered surfaces, encode lifecycle
- `src/linux/vaapi/encoder_backend.zig` — `EncodeBackend` vtable implementation (same interface as NVENC)
- `src/linux/vaapi/hevc_params.c/.h` — C helper for HEVC encode parameter submission (va_enc_hevc.h bitfield unions break Zig translate-c)
- Build system integration in `build_linux.zig` (links libva, libva-drm)
- `tools/test_vaapi.zig` — integration test binary

**FIXED (2026-04-05):** Encoder now produces valid HEVC bitstream (90 frames, 1920x1080, ffprobe validates).
Root cause: Intel iHD HEVC EncSliceLP requires GPB (Generalized P→B) encoding:
  1. Non-IDR frames must use B-slices (slice_type=0), NOT P-slices — L0=L1 (both ref lists same picture)
  2. Packed slice header (VAEncPackedHeaderSlice) required on every frame
  3. Packed VPS/SPS/PPS (VAEncPackedHeaderSequence) with start codes + emulation prevention bytes
  4. SPS dimensions must be CTU-aligned (64px), with conformance window for cropping

### 2. Embedded Wayland compositor
- `src/linux/wayland/compositor.zig` — wlroots-based headless compositor in Zig
- `wlroots/` git submodule at 0.17.4 (0.20 needs newer wayland-server than Ubuntu 24.04 ships)
- `.zig-cache/wlroots-build/libwlroots.a` — static lib built by meson+ninja
- Build system integration in `build_linux.zig`
- `tools/test_compositor.zig` — integration test binary

**Working:**
- Headless output at arbitrary resolution on any GPU (no display, no dongle)
- `WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128` selects Intel GPU
- Native Wayland apps connect and render (tested gnome-calculator)
- Frame events fire from the scene graph after output enable commit
- Frame callback mechanism in place (currently passes placeholder, not real DMA-BUF)
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

### 3. Hardware validated
- Intel Alder Lake GT1 (i9-12900K) UHD 770 at `/dev/dri/renderD128`
- VA-API HEVC encode via `VAEntrypointEncSliceLP` (iHD driver 24.1.0)
- No AV1 encode on this iGPU (needs Arc/Meteor Lake+)
- VA-API supports RGB32 input directly (XRGB/RGBX) — no NV12 conversion needed
- File capabilities (setcap) silently ignored on eCryptfs — install to /usr/local/bin

## What's Next (in order)

### Phase 1: Get DMA-BUF out of compositor frame
In `compositor.zig` `handleFrame`, replace the placeholder with real buffer extraction:
1. Use `wlr_scene_output_build_state` (not `wlr_scene_output_commit`) to render into a state
2. Extract `state.buffer` → `wlr_buffer_get_dmabuf` → `wlr_dmabuf_attributes`
3. Pass DMA-BUF fd/format/stride to the frame callback
4. Then commit the state to the output with `wlr_output_commit_state`
5. Verify with test binary: log format (expect XRGB or ARGB), fd, dimensions

### Phase 2: Fix VA-API encoder reference management
Update `hevc_params.c` to use the correct surface pattern:
1. Separate input surfaces (vaBeginPicture target) from reconstruction surfaces (decoded_curr_pic)
2. Allocate 4 input + 4 reconstruction surfaces
3. SPS only on IDR frames
4. Reference frames use reconstruction surface IDs with `VA_PICTURE_HEVC_RPS_ST_CURR_BEFORE`
5. Test: encode 90 frames of real content (from compositor), verify non-zero output, ffprobe validates

### Phase 3: Wire compositor → VA-API encoder end-to-end
1. Import compositor's DMA-BUF into VA-API as encode input surface
   - Use `vaCreateSurfaces` with `VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2` to import DMA-BUF
   - OR: if VA-API can accept the compositor buffer directly (same GPU, same allocator)
2. Frame loop: compositor renders → DMA-BUF → VA-API encode → `EncodedFrame`
3. Wire `EncodedFrame` to `BroadcastSession.sendFrame` (existing WebRTC pipeline)
4. Measure latency: compositor render → encode → send (target: comparable to NVENC's ~1ms)

### Phase 4: App share orchestration
Create `src/linux/wayland/app_share.zig` (parallel to `src/linux/x11/app_share.zig`):
1. Init compositor with target resolution
2. Set `WAYLAND_DISPLAY` env, launch app as child process
3. Wait for xdg_shell toplevel (app window appears)
4. Start encode loop: compositor frame callback → VA-API encode → WebRTC
5. Handle resize (compositor can resize output dynamically)
6. Wire into daemon.zig as new session type

### Phase 5: Encoder pool
1. Probe available GPUs at daemon startup:
   - NVIDIA: check for NVENC (existing detection)
   - Intel/AMD: check for VA-API encode profiles on each render node
   - Only include devices where encoding actually works (not just present)
2. Pool logic: prefer AV1 encoders, fall back to HEVC
3. Session creation picks encoder from pool
4. `--gpu` CLI override: `nvidia`, `intel`, `auto` (default)
5. Track concurrent session limits per device

### Phase 6: Clean up and test
1. Run existing tests + lint to verify nothing broke
2. End-to-end test: `zerocast share app gnome-calculator` on Intel
3. Playwright test: verify stream appears in browser with valid stats
4. Power measurement: compare Intel iGPU encode vs NVIDIA
5. Latency measurement: capture → encode → decode → render in Chrome
6. Consider: can the Wayland compositor path replace X11+NvFBC for NVIDIA?

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

# Test compositor on Intel
WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128 dist/bin/test-compositor
# In another terminal:
GDK_BACKEND=wayland WAYLAND_DISPLAY=wayland-0 gnome-calculator

# Test VA-API encoder
LIBVA_DRIVER_NAME=iHD dist/bin/test-vaapi
```

## File Map

```
src/linux/
├── vaapi/
│   ├── vaapi.zig              # VA-API encoder (libva bindings, codec detection)
│   ├── encoder_backend.zig    # EncodeBackend vtable for VA-API
│   ├── hevc_params.c          # C helper for HEVC encode params
│   └── hevc_params.h
├── wayland/
│   └── compositor.zig         # Embedded wlroots headless compositor
├── x11/                       # Existing NVIDIA pipeline (unchanged)
│   ├── app_share.zig
│   ├── encoder_backend.zig
│   ├── nvfbc.zig, cuda.zig, nvenc.zig
│   └── ...
└── kms/                       # KMS helper (unchanged, may be used later)

tools/
├── test_vaapi.zig             # VA-API encoder test
└── test_compositor.zig        # Compositor test

wlroots/                       # Git submodule (0.17.4)
```

## Key Design Decisions

1. **Zig over C** — Use Zig for everything except where C is forced (va_enc_hevc.h bitfield unions). Keep C helpers minimal.
2. **Wayland over X11** — Embedded compositor is simpler, more portable, and future-proof. No NvFBC, no DRM master, no dongle.
3. **No Xwayland** — Modern apps are Wayland-native. Simplifies compositor significantly.
4. **No color conversion** — VA-API on Intel accepts RGB32 directly, same as NVENC accepts ARGB.
5. **Codec-preferred pool** — AV1 first (any device), HEVC fallback. Device-agnostic.
6. **wlroots 0.17.4** — Matches Ubuntu 24.04 system libs. Upgrade to 0.20 when system catches up.
7. **Frame pacing by compositor** — Headless output refresh rate controls frame rate. No LD_PRELOAD hacks.
