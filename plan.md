# Wayland Pipeline Gap Closure Plan

Status: in-progress
Date: 2026-04-07

## Context

The Wayland compositor pipeline (wlroots headless) is the new primary capture path. It works end-to-end (compositor -> GL FBO -> CUDA -> NVENC -> WebRTC for NVIDIA, compositor -> DMA-BUF -> VA-API for Intel/AMD) but has several gaps compared to the mature X11 path. This plan covers closing those gaps.

## Confirmed: Already in Place

- **Infinite GOP** — `gopLength = 0xFFFFFFFF`, keyframes only on PLI request
- **No B-frames** — `frameIntervalP = 1`, P-frames only
- **VBR rate control** — same formula as X11: `90_000 + pixels * fps * 12 / 1000`
- **BT.709 color metadata** — matching X11 exactly
- **Recording** — SessionRecorder integration present
- **GPU auto-detection** — sysfs vendor probe + NVENC/VA-API capability check

---

## Gap 1: Damage Tracking + Single Event Loop — DONE (2026-04-07)

Replaced dual-clock architecture (sleep-based encode loop + wlroots timer) with a single compositor-driven event loop. The compositor's headless output refresh rate is set to the target fps, and `wl_event_loop_dispatch(loop, 100)` blocks until the next frame event.

Damage detection via `wlr_surface.current.seq` (surface commit serial) — encoder skips frames when the app is idle. Equivalent to NvFBC's `dwCurrentFrame`.

**Changes:**
- `compositor.zig`: fps param, `wlr_output_state_set_custom_mode(w, h, fps*1000)`, blocking dispatch, surface seq tracking
- `app_share.zig`: removed sleep-based pacing, single loop driven by compositor

---

## Gap 2: Input Injection — DONE (2026-04-07)

Full remote input via virtual wlroots devices. Parity with X11's XTEST-based injection.

**Implementation:**
- `src/linux/wayland/input.zig` — virtual keyboard (`wlr_keyboard_init` + xkbcommon keymap) and pointer (`wlr_pointer_init`), `InputHandler` vtable, SPSC ring buffer for thread safety
- Events queued from libdatachannel network thread, drained on compositor thread after each `dispatch()`, followed by a non-blocking flush to deliver to clients
- Focus set via `wlr_seat_keyboard_notify_enter` + `wlr_seat_pointer_notify_enter` when toplevel maps
- `build_linux.zig` — wayland_input module linked to wlroots + xkbcommon

**Bugs fixed during testing:**
1. **CSD geometry offset** — video coordinates are content-area relative, but wlr_seat expects surface-local (including GTK header bar). XDG geometry offset (e.g. 26,23 for gnome-calculator) added to all pointer coords.
2. **Instant keyframe on connect** — browser needs at least one RTP packet before sending PLI. Force keyframe when peer state transitions to connected.
3. **Viewer-initiated resize disabled** — app's native size is authoritative. Prevents compositor/app size mismatch that caused coordinate errors.
4. **Honour every PLI** — removed `idle_keyframe_sent` gate that blocked subsequent PLIs while idle. Browser stops sending PLIs once it decodes a frame, so the "burst" is self-limiting.
5. **Mouse move forwarding** — mouse_move events were only updating cursor overlay, not forwarded to wlr_seat. Drawing apps only saw start/end points (straight lines). Now forwarded for drag/draw support.
6. **`--gpu nvidia+x11`** — CLI flag to force X11/NvFBC pipeline for A/B testing.

---

## Gap 3: Configurable Rate Control — CQP vs VBR — DONE (2026-04-07)

Switched from VBR to Constant QP (CQP) as default. CQP gives consistent quality regardless of content complexity — critical for text-heavy screen sharing where VBR would aggressively quantize static P-frames.

**Implementation:**
- `--rc vbr|cqp` and `--qp N` CLI flags on `share app` command
- Wire path: `cli.zig` → `control.zig` (RateControl enum + ShareRequest fields) → `daemon.zig` → both `AppShareConfig` structs → `NvencBackend.init` → `Nvenc.init`
- CQP: `NV_ENC_PARAMS_RC_CONSTQP`, equal QP for all frame types (no I/P offset — P-frame residuals on static content are near-zero, so offset just degrades quality for no bandwidth saving)
- VBR: unchanged (original adaptive bitrate formula)
- Build deps: `control` module added to `nvenc`, `nvenc_backend`, and `encoder_backend` modules in `build_linux.zig`
- VA-API CQP deferred — requires C code changes in `hevc_params.c`

**Defaults:**
- `--rc cqp` (default — consistent quality for screen sharing)
- `--qp 20` (default — sharp text, ~40kbps idle on drawing app, ~4kbps on calculator)

**Idle PLI suppression:**
- VBR had a blur oscillation bug: browser sends periodic PLIs during idle, each triggering a full keyframe. With VBR, P-frames on static content got aggressive quantization (blurry), then keyframe reset (crisp), repeating every few seconds.
- CQP fixed the quality oscillation, but PLI keyframes were still 60KB each on idle.
- Fix: `idle_keyframe_sent` flag in `encoder.zig` — after sending one keyframe during idle, suppress further PLIs until content actually changes. Browser already has the current frame; identical keyframes are wasteful.

---

## Gap 4: Resize (Priority: Next)

### Current State
Viewer-initiated resize is disabled. The app's native size is authoritative and the viewer window matches it.

### Remaining Work
- App-initiated resize works (compositor detects via `handleToplevelCommit`, triggers encoder rebuild)
- Viewer-initiated resize needs rethinking: should only resize after the app confirms the new size (commit at new geometry), not on the compositor output alone
- Multi-toplevel support: drawing app showed a popup dialog before main window — need to handle multiple XDG surfaces without crashing

---

## Gap 5: Minor Items (Low Priority)

### Wayland Socket Naming
Socket name hardcoded to `"zerocast-0"`. Second concurrent session fails. Fix: use `"zerocast-{pid}"` or `"zerocast-{session_id_prefix}"`.

### NVENC Code Deduplication
`wayland/nvenc.zig` is a copy of `x11/nvenc.zig`. Any NVENC changes (CQP, buffer pool) must be made in both. Extract to a shared module.

### Capture Timestamp
X11 gets `ulTimestampUs` from NvFBC for abs-capture-time RTP extension. Wayland has no capture timestamp from wlroots. Use `clock_gettime(CLOCK_MONOTONIC)` at frame callback time as approximation.

### NVENC Buffer Pool (Ghost Frames)
Single-buffer bug affects both X11 and Wayland NVENC paths. Fix: pool of N surfaces. Not Wayland-specific — tracked separately.

### Debug Logging Cleanup
`session.zig` has info-level DC mouse_down/mouse_up logging and `input.ts` has console.log for clicks. Remove or demote to debug before release.
