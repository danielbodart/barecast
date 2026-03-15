# macOS Port Plan

Status: **Phase 2 complete — virtual display + window-level capture working**
Date: 2026-03-15
Minimum macOS: 14.0 (Sonoma) — required for CGVirtualDisplay
Minimum hardware: Apple Silicon M1 — required for VideoToolbox HEVC encode

## Goal

Port Zerocast's app sharing pipeline to macOS while preserving the same model: the shared application runs on a hidden display, only visible and interactive via the browser viewer. The pipeline must be zero-copy from capture through hardware encode, matching the Linux philosophy.

This is additive — the Linux pipeline is unchanged. Both platforms share the WebRTC transport, signaling, wire protocols, and browser viewer.

## Pipeline Overview

```
CGVirtualDisplay (hidden)        ← app runs here, invisible to host user
        |
ScreenCaptureKit (SCStream)      ← IOSurface-backed CVPixelBuffer (GPU-resident)
        |
VideoToolbox (VTCompressionSession) ← hardware HEVC encode, zero-copy from IOSurface
        |
libdatachannel                   ← RTP/WebRTC, same as Linux
        |
Browser viewer                   ← HEVC decode via WebCodecs
        ^
CGEvent                          ← input injection from remote viewers
```

Zero CPU-side pixel copies. ScreenCaptureKit delivers IOSurface-backed frames that VideoToolbox reads directly on the GPU.

## Key Design Decisions

### HEVC instead of AV1

Apple Silicon has no hardware AV1 encoder (M1 through M4 — decode only on M3+). HEVC (H.265) is hardware-accelerated on all Apple Silicon, supports the zero-copy IOSurface path, and has good browser support via WebCodecs (Chrome 107+, Safari 17+, Edge).

The viewer must be updated to negotiate HEVC alongside AV1. libdatachannel already supports H.265 RTP packetization. This change benefits both platforms — HEVC could be offered as a codec option on Linux too if desired.

### CGVirtualDisplay for hidden app display

The Linux pipeline uses a headless Xorg display to isolate the shared app. macOS has no public equivalent. CGVirtualDisplay is a private CoreGraphics API (macOS 14+) that creates a real virtual display recognized by the window server. It is the proven approach used by:

- [Lumen](https://github.com/trollzem/Lumen) (Sunshine fork — full pipeline: virtual display + ScreenCaptureKit + VideoToolbox + streaming)
- [BetterDisplay](https://github.com/waydabber/BetterDisplay)
- [Chromium test infrastructure](https://chromium.googlesource.com/chromium/src/+/d441ddf663e568fe8383d59a31e0dfacb9d9535b/ui/display/mac/test/virtual_display_mac_util.mm)
- [KhaosT/CGVirtualDisplay](https://github.com/KhaosT/CGVirtualDisplay)

**Risk:** Private API — could break between macOS versions. Mitigations: pin to tested macOS versions, Chromium's dependency on it provides early warning of breakage, migrate if Apple ships a public API.

**Architecture constraint:** CGVirtualDisplay must be created in a separate helper process (TCC/WindowServer registration requires a clean process context). This mirrors the `zerocast-xorg` pattern on Linux.

### CGEvent for input injection

CGEvent (Quartz Event Services) is the standard approach used by every shipping macOS remote control tool (RustDesk, Multi.app, VNC implementations). Pure C API, sub-millisecond latency, callable directly from Zig.

Requires Accessibility permission (TCC). Events target the virtual display's coordinate space — since the app is the only thing on that display, coordinates map 1:1.

### Thin ObjC wrapper for ScreenCaptureKit

ScreenCaptureKit is Objective-C only. VideoToolbox, CoreMedia, CoreVideo, and CoreGraphics are all pure C APIs callable directly from Zig. The ObjC surface area is limited to:

- Content enumeration (finding the virtual display)
- Stream configuration and start/stop
- Output delegate callback (receives CMSampleBuffer)

A thin `.m` file exposes a C API to Zig, keeping the ObjC isolated.

Prior art: [Frametap](https://injuly.in/blog/screen-capture/) — Zig screen capture library wrapping ScreenCaptureKit in ~350 lines of ObjC runtime calls.

## Component Mapping

| Concern | Linux | macOS |
|---|---|---|
| Hidden display | Headless Xorg via `zerocast-xorg` (setuid) | CGVirtualDisplay via `zerocast-vd` (helper process) |
| Screen capture | NvFBC → GL texture | ScreenCaptureKit → IOSurface-backed CVPixelBuffer |
| GPU transfer | CUDA/GL interop | Not needed — IOSurface is the shared GPU object |
| Encode | NVENC AV1 | VideoToolbox HEVC |
| Codec | AV1 only | HEVC (H.265) |
| Frame rate cap | `libfpscap.so` LD_PRELOAD | Not needed — ScreenCaptureKit has built-in rate limiting |
| Window manager | X11 SubstructureNotifyMask | AXObserver / CGWindowListCopyWindowInfo |
| Input injection | XTEST | CGEvent (pure C) |
| App resize | xrandr + XMoveResizeWindow | Virtual display resize + AXUIElement |
| Permissions | CAP_SYS_ADMIN, setuid | Screen Recording + Accessibility (TCC prompts) |
| WebRTC transport | libdatachannel (static) | Same |
| Signaling | Cloudflare Worker | Same |

## New Files

### macOS-specific source

| File | Purpose | API |
|---|---|---|
| `src/macos/virtual_display.m` | ObjC wrapper for CGVirtualDisplay — create, destroy, get display ID | ObjC exposing C functions |
| `src/macos/screen_capture.m` | ObjC wrapper for ScreenCaptureKit — SCStream setup, frame callback | ObjC exposing C functions |
| `src/macos/videotoolbox.zig` | VideoToolbox HEVC encoder — VTCompressionSession lifecycle, per-frame encode | Zig calling C (VideoToolbox/CoreMedia) |
| `src/macos/cgevent_input.zig` | CGEvent input injection — maps input_protocol events to CGEvent calls | Zig calling C (CoreGraphics) |
| `src/macos/app_share.zig` | macOS app share orchestrator — wires virtual display + capture + encode + session | Zig |
| `src/macos/permissions.zig` | TCC permission check/request (Screen Recording + Accessibility) | Zig calling C (CoreGraphics) |
| `src/macos/vd_main.zig` | Entry point for `zerocast-vd` helper binary | Zig + ObjC wrapper |

### Build system

| File | Purpose |
|---|---|
| `build_macos.zig` | macOS-specific build modules, framework linking (VideoToolbox, CoreMedia, CoreVideo, CoreGraphics, ScreenCaptureKit), ObjC source compilation |

`build.zig` gains an `@import("builtin").os.tag` switch to compose platform-specific modules. `run.ts` gains OS detection (`process.platform`) for dep checking (`brew` vs `apt`) and drops `-march=x86_64_v3` on macOS.

## Shared Code (unchanged)

These modules are already cross-platform:

- `session.zig` — WebRTC/libdatachannel
- `control.zig` — daemon-CLI protocol (needs minor `std.os.linux` → `std.posix` fix)
- `ivf.zig` — IVF container writer
- `input_protocol.zig` — binary wire format for input events
- `viewer_state.zig` — per-viewer cursor state
- `osc_parser.zig` — terminal title extraction
- `worker/` — Cloudflare Worker signaling server

## Minor Portability Fixes (shared code)

These are small changes needed for the shared code to compile on macOS:

| File | Line | Issue | Fix |
|---|---|---|---|
| `daemon.zig` | 645 | `std.os.linux.sockaddr.un` | Use `std.posix.sockaddr.un` or comptime OS switch |
| `cli.zig` | 237 | `std.os.linux.sockaddr.un` | Same |
| `control.zig` | 202 | `std.os.linux.getuid()` | Use `std.c.getuid()` |
| `terminal_share.zig` | 4 | `#include "pty.h"` | macOS uses `<util.h>` |
| `terminal_share.zig` | 269 | `O_NONBLOCK: usize = 0o4000` (Linux x86_64 value) | Use `std.posix.O.NONBLOCK` |
| `cli.zig` | 140 | `posix.execvpeZ("systemctl")` | Comptime switch: launchctl on macOS (or skip for PoC) |

## Permissions

macOS requires two TCC permissions:

1. **Screen Recording** — needed for ScreenCaptureKit to capture any content. Check with `CGPreflightScreenCaptureAccess()`, request with `CGRequestScreenCaptureAccess()`. Both are C functions.
2. **Accessibility** — needed for CGEvent input injection. Check with `AXIsProcessTrusted()`. No programmatic request — the user must grant it in System Settings.

For a CLI tool without a bundle ID, TCC persistence may be unreliable. A minimal `.app` bundle or Info.plist with a `CFBundleIdentifier` may be needed for reliable permission storage. This is a Phase 5+ concern.

## Viewer Changes

The browser viewer needs to handle HEVC alongside AV1:

- **SDP negotiation**: offer H.265 codec in the RTP track description
- **Codec detection**: the viewer should accept whichever codec the sharer offers (AV1 from Linux, HEVC from macOS)
- **No decoder changes needed**: WebRTC handles HEVC decode natively in supported browsers

libdatachannel's `rtcAddTrackEx` already supports H.265 payload type and packetizer. The change is in the track description string passed during peer connection setup.

## Implementation Phases

### Phase 1: Prove the pipeline (PoC) — DONE

Goal: Capture a window and encode to HEVC on disk.

Completed:
- VideoToolbox HEVC encoder (`src/macos/videotoolbox.m` + `encoder_videotoolbox.zig`)
  - VTCompressionSession with HEVC codec, low-latency mode
  - Accepts CVPixelBuffer, outputs Annex B NAL units (AVCC → Annex B conversion)
  - ~2 bits/pixel bitrate, no B-frames
- ScreenCaptureKit wrapper (`src/macos/screen_capture.m`)
  - Display-level and window-level capture modes
  - CVPixelBuffer retain/release lifecycle for thread safety
- Encoder abstraction (`src/encoder.zig` with `EncodeBackend` vtable)
  - `encoder_nvenc.zig` — NVIDIA backend
  - `encoder_videotoolbox.zig` — macOS backend
  - Both implement the same contract; encoder.zig has shared orchestration
- Build system split: `build.zig` + `build_shared.zig` + `build_linux.zig` + `build_macos.zig`
- `run.ts` platform detection (macOS deps via brew, no `-march=x86_64_v3`)
- Portability fixes: `control.zig` getuid, `terminal_share.zig` pty.h + O_NONBLOCK
- Raw Annex B `.hevc` output (IVF is AV1-specific; HEVC uses raw Annex B)
- Validated: ffprobe confirms HEVC Main profile, 1920x1080, yuv420p, correct frame count

### Phase 2: Virtual display + app isolation — DONE

Goal: Run an app on a hidden display and capture it.

**Key discovery: virtual display not needed for most apps.** ScreenCaptureKit supports
`SCContentFilter initWithDesktopIndependentWindow:` which captures just the window
content — no title bar, no desktop background, no decorations. Combined with moving
the window off-screen (`AXUIElementSetAttributeValue` with position `(-16000, 0)`),
this gives the same isolation as Linux's headless Xorg approach but simpler.

Completed:
- Window-level capture: `sc_capture_create_window(window_id, fps)` captures just the
  app content at the exact window size — no wasted pixels, no decorations
- App launcher: `sc_launch_app_offscreen(app_path, &pid)` launches an app via
  NSWorkspace, detects its window via CGWindowListCopyWindowInfo, moves it off-screen
  via AXUIElement (Accessibility API), returns the window ID for capture
- `capture_test.zig` — end-to-end test: launch Calculator → off-screen → window capture → HEVC
- CGVirtualDisplay helper (`zerocast-vd`) — also implemented as a fallback for apps
  that need a real display to render (games, OpenGL). Uses private CGVirtualDisplay API
  with helper process pattern (display lives as long as helper runs). Key findings:
  - `vendorID`/`productID` must be non-zero (macOS 15 rejects all-zero)
  - `terminationHandler` must be set
  - `dispatch_get_main_queue()` required (not global queue)
  - SkyLight framework not needed for basic functionality

**Virtual display kept as optional fallback**, not the default path. Window-level
capture is preferred because:
- No extra display in System Settings → Displays
- Captures exact window content (auto-sized, no decorations)
- Simpler (no helper process needed)
- Works for all standard macOS apps

### Phase 3: WebRTC streaming

Goal: Stream to the browser viewer.

- Wire VideoToolbox bitstream output into `BroadcastSession.sendFrame()`
- Build macOS app share orchestrator (`src/macos/app_share.zig`)
  - Owns app launcher + window lifecycle
  - Owns ScreenCaptureKit window-level capture
  - Owns VideoToolbox encoder
  - Connects to BroadcastSession
- HEVC WebRTC support is now on trunk (added to NVIDIA pipeline too) — rebase to pick up
  session.zig H.265 track support and viewer.ts HEVC codec negotiation
- End-to-end: off-screen app → window capture → HEVC → WebRTC → browser viewer

### Phase 4: Input injection

Goal: Remote viewers can interact with the shared app.

- Build CGEvent input handler (`src/macos/cgevent_input.zig`)
  - Implement `InputHandler` interface (same vtable as XTestInput)
  - Map input_protocol mouse/keyboard events to CGEvent calls
  - Post events at virtual display coordinate space
  - Map W3C KeyboardEvent.code to macOS virtual keycodes (new keymap needed)
- Wire into session's input callback path
- Test: viewer mouse/keyboard → data channel → CGEvent → app responds

### Phase 5: Resize + polish

Goal: Dynamic resize and permission UX.

- Viewer resize → resize virtual display → resize app window → reinit capture + encoder
- App self-resize detection via AXObserver geometry change notifications
- Permission checking on startup (`permissions.zig`)
  - Screen Recording: `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()`
  - Accessibility: `AXIsProcessTrusted()`
  - Clear error messages if denied
- Encoder pipeline reinit (same teardown/rebuild pattern as Linux)

### Phase 6: Daemon + CLI

Goal: Background daemon with CLI control.

- Port `daemon.zig` sockaddr to cross-platform
- Port `cli.zig` sockaddr + remove systemctl on macOS
- Port `control.zig` getuid
- launchctl / LaunchAgent plist for daemon management (optional)

## Dependencies

### macOS system frameworks (linked, not installed)

- VideoToolbox.framework
- CoreMedia.framework
- CoreVideo.framework
- CoreGraphics.framework (CGEvent, CGVirtualDisplay)
- ScreenCaptureKit.framework
- ApplicationServices.framework (Accessibility APIs)

### Homebrew packages (installed by `run.ts`)

- `openssl` — for libdatachannel TLS
- `cmake` — for building libdatachannel
- `pkg-config` — build tooling

### Toolchain (unchanged)

- Zig 0.15.2 (mise)
- Bun (mise)
- libdatachannel submodule (cmake build, works on macOS — drop `-march=x86_64_v3`)

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| CGVirtualDisplay is a private API | Could break on macOS updates | Pin to tested versions; Chromium depends on it (early warning); migrate to public API if shipped |
| ScreenCaptureKit bug with multiple virtual displays | Stream may capture wrong display | Create only one virtual display per session; filter by display ID carefully |
| Zig framework linking bugs on macOS | Build failures | Use `-framework` linker flags as fallback; track zig#17294 |
| TCC permission UX for CLI tools | Permissions may not persist without bundle ID | Add minimal Info.plist with CFBundleIdentifier |
| HEVC browser support gaps | Some browsers may not decode | Firefox added HEVC in WebRTC (v128+); provide clear browser requirements |
| CGEvent requires Accessibility permission | Users must grant manually | Clear first-run guidance; check AXIsProcessTrusted() on startup |

## Reference Implementations

- [Lumen](https://github.com/trollzem/Lumen) — Sunshine fork with CGVirtualDisplay + ScreenCaptureKit + VideoToolbox. The most complete reference for the full pipeline.
- [Frametap](https://injuly.in/blog/screen-capture/) — Zig + ScreenCaptureKit in ~350 lines. Proves the Zig-ObjC integration pattern.
- [Chromium virtual_display_mac_util.mm](https://chromium.googlesource.com/chromium/src/+/d441ddf663e568fe8383d59a31e0dfacb9d9535b/ui/display/mac/test/virtual_display_mac_util.mm) — Clean CGVirtualDisplay implementation in C++/ObjC.
- [KhaosT/CGVirtualDisplay](https://github.com/KhaosT/CGVirtualDisplay) — Minimal CGVirtualDisplay example.
- [Multi.app blog](https://multi.app/blog/building-a-macos-remote-control-engine) — Practical notes on CGEvent input injection for remote control.
