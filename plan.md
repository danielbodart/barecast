# Viewer resize — FIXED 2026-03-08

## What was broken

`zerocast share app glxgears` — gears animated briefly then froze when the
browser viewer sent a resize message. Multiple root causes:

1. **Thread safety**: `appResizeCallback` ran on the libdatachannel thread,
   calling X11 and GPU functions concurrently with the capture loop thread.
2. **picom compositor breaking on xrandr**: xrandr invalidated picom's
   compositing state. picom's "unredirect" optimization would stop forwarding
   damage events after ~8 seconds, even without resize.
3. **Resize loop**: viewer's ResizeObserver sent back the native video
   resolution, causing a no-op resize that still tore down the pipeline.
4. **Window shrinking**: `window.open` and `window.resizeTo` set outer window
   size, but video element measured inner content area. Each open shrank by
   the window decoration offset.

## What we did

### 1. Full pipeline teardown/rebuild on resize (replacing surgical reinit)
- `appResizeCallback` now just sets an atomic `pending_resize` (u32: w<<16|h)
- Capture loop checks the flag each iteration
- On resize: `encoder.deinit → fbc.deinit → display.resize → wm.resizeApp → fbc.initDisplay → grabFrame → encoder.init`
- Per-stage timing logged (~300ms total)
- Removed surgical methods: `recreateSession`, `reinitBuffers`, `reconfigure`, `encoder.reinit`
  (to be reintroduced one-at-a-time clean-room style if needed for performance)

### 2. Removed picom entirely
- Switched NvFBC from push model (`bPushModel=true` + `bAllowDirectCapture=true`)
  to polling mode (`bPushModel=false`)
- `bIsNewFrame=true` sustained indefinitely without compositor
- Eliminates 500ms picom startup sleep, fragile state management, external dependency
- Key learning: `dwCurrentFrame` is just a grab counter, NOT a content-change signal.
  `bIsNewFrame` is the real content-change indicator.

### 3. No-op resize suppression (both sides)
- Server: `appResizeCallback` skips if size matches `display.width/height`
- Browser: `ResizeObserver` skips if size matches `video.videoWidth/videoHeight`

### 4. Window decoration offset
- `window.open` in hub.ts adds `outerWidth-innerWidth` / `outerHeight-innerHeight`
- `window.resizeTo` in viewer.ts adds same decoration offset
- Prevents shrink-on-every-open loop

### 5. Video fills viewport
- Changed `video` CSS from `max-width/max-height` to `width: 100vw; height: 100vh`
- Enables resize-up: making browser window bigger triggers app resize to match

# Headless display improvements — 2026-03-08

## Frame rate capping (fpscap.so)
- `UseDisplayDevice "none"` has no vblank — OpenGL apps spin at 100% CPU
- `ConnectedMonitor` requires exclusive DRM master — fails on shared GPU
  (every cloud gaming project that uses it assumes a dedicated GPU)
- Software-only alternatives (VKMS, evdi, NV-CONTROL runtime injection) do not
  work with NVIDIA proprietary driver — it has its own isolated DRM/KMS stack
- Solution: `fpscap.so` — tiny LD_PRELOAD that hooks `glXSwapBuffers` with
  `clock_nanosleep` to cap at target FPS. No vblank dependency.
- `src/fpscap.c` built by `run.ts build`, output to `dist/bin/fpscap.so`
- `app_share.zig` sets `LD_PRELOAD` + `FPS` env vars in child before exec
- Result: glxgears CPU 100% → 1.4%

## Headless Xorg input isolation (AutoAddDevices)
- `-sharevts` on same VT caused physical keyboard events to reach headless Xorg
- Arrow keys in host terminal rotated glxgears on headless display
- Also caused intermittent animation stalls (input events disrupting render loop)
- Fix: `AutoAddDevices "false"` in xorg.conf ServerFlags section
- Input now only reaches app via XTEST injection from viewer data channel

## AV1 color metadata
- NVENC was not setting color space metadata (all zeros = "unspecified" per AV1 spec)
- Browsers guessed differently → inconsistent colors across viewers
- Set BT.709 primaries/transfer/matrix in ConfigAv1
- `colorRange = 0` (limited) — matches NVENC's internal RGB→YUV conversion

## Color accuracy investigation — 2026-03-08

### Research findings
- **Every major project** (Sunshine, gpu-screen-recorder, OBS, Moonlight, Parsec)
  uses BT.709 limited range for screen content via NVENC. Our settings match.
- NVENC's internal ARGB→YUV conversion matrix is **undocumented** by NVIDIA.
  Community consensus: BT.709 limited range for HD content, but no official docs.
- gpu-screen-recorder uses an **explicit GPU shader** for RGB→NV12 conversion
  with a known BT.709 limited range matrix, avoiding the undocumented conversion.
- Remaining color differences are inherent: lossy RGB→YUV→RGB round-trip
  (~220 luma levels vs 256), plus browser color management (sRGB vs display ICC).

### Explicit NV12 color conversion — attempted
Built a complete GL shader pipeline (BT.709 limited range, same matrix as
gpu-screen-recorder) to replace NVENC's undocumented internal conversion:

- `src/color_conversion.zig`: GLSL 330 shaders, two-pass (Y + UV FBOs)
- Modified `cuda.zig`: NV12 buffer allocation, two-texture CUDA copy
- Modified `nvenc.zig`: NV_ENC_BUFFER_FORMAT_NV12
- Modified `encoder.zig`: shader → CUDA copy → NVENC pipeline

**Verification:**
- NV12 buffer dump (cuMemcpyDtoH) decoded correctly by ffmpeg — single image, correct colors
- IVF recording from NVENC decoded correctly by ffmpeg (dav1d, NVDEC, libaom)
- IVF→WebM played correctly in Chrome and Firefox
- AV1 sequence headers identical between ARGB and NV12 paths (same color metadata)
- Frame OBU structure identical (TD + SEQ_HDR + FRAME)

**Bug: doubled/ghosted image in browser via WebRTC**
- Chrome AND Firefox show a ghosted overlay (small gears on top of large gears)
- Same bitstream plays correctly from a WebM file in Chrome — NOT a decoder bug
- Same bitstream plays correctly when re-encoded by ffmpeg's av1_nvenc — NOT an NV12 data issue
- Issue is specifically: our NVENC NV12 AV1 bitstream + libdatachannel AV1 RTP packetizer
  → browser AV1 depacketizer produces corrupt frames
- ARGB path: same NVENC settings, same libdatachannel packetizer → works perfectly
- The NV12-encoded frames have different compressed byte patterns (same OBU structure)
  which apparently trigger a bug in the browser's AV1 RTP depacketizer/reassembly

**Tested combinations:**
| Input format | Tuning | Buffer method | WebM | WebRTC |
|---|---|---|---|---|
| ARGB | LOW_LATENCY | RegisterResource | ✓ | ✓ |
| ARGB | HIGH_QUALITY | RegisterResource | ✓ | ✓ |
| NV12 | LOW_LATENCY | RegisterResource | ✓ | ✗ (doubled) |
| NV12 | HIGH_QUALITY | RegisterResource | ✓ | ✗ (doubled) |
| NV12 | HIGH_QUALITY | CreateInputBuffer | ✓ | ✗ (doubled) |
| NV12 (ffmpeg re-encode) | HIGH_QUALITY | CreateInputBuffer | ✓ | n/a |
| NV12 (ffmpeg `-tune ll`) | LOW_LATENCY | (ffmpeg internal) | ✓ | n/a |

### Next steps
- Investigate libdatachannel AV1 RTP packetizer — compare RTP packet dumps
  between ARGB and NV12 encoded frames to find the depacketization difference
- Alternatively: try packetizing with `RTC_OBU_PACKETIZED_OBU` instead of
  `RTC_OBU_PACKETIZED_TEMPORAL_UNIT`
- Or: fork approach — keep ARGB for encoding but set explicit AV1 color metadata
  (current working approach, NVENC's internal conversion matches BT.709 limited)

## `__GL_YIELD=USLEEP` — rejected
- Reduced CPU (100% → 40%) but caused bursty rendering — glxgears would
  animate for a few seconds then freeze, repeat. Bitrate dropped to 4kbps
  during freezes. The usleep(0) in the driver's swap path stalls the app's
  render loop intermittently on headless displays without vblank.

## Remaining work

### Resize performance
- Current: ~300ms (dominated by GPU init: fbc_init=70ms, encoder_init=90ms, grab=30-100ms)
- Could reintroduce surgical reinit one stage at a time to reduce this

### Other
- DISPLAY env race for concurrent app shares (setenv is process-global)
- Startup time optimization (currently ~10-15s)
- NV12 color conversion: blocked by WebRTC packetizer bug (see above)
