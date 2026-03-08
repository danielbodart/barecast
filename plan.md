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
- Remaining: slight color differences between native app and stream (lossy
  RGB→YUV→RGB round-trip) and between different browser instances (browser
  color management differences). Needs deeper investigation.

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
- Color accuracy: investigate NVENC RGB→YUV conversion range, browser color
  management differences
