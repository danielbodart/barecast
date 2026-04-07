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
- **Resize handling** — full teardown/rebuild via atomic pending_resize, both viewer- and app-initiated
- **Recording** — SessionRecorder integration present
- **GPU auto-detection** — sysfs vendor probe + NVENC/VA-API capability check

---

## Gap 1: Damage Tracking (Priority 1)

### Problem

The wlroots headless backend runs an internal timer that fires `output.events.frame` at its default refresh rate (~60Hz). Our `handleFrame` callback fires on every tick, calls `wlr_scene_output_build_state`, and sets `has_new_frame = true` — even if the app hasn't committed new content. This means the encoder encodes every frame even when the screen is static, wasting GPU and bandwidth.

In contrast, the X11 path uses NvFBC's `dwCurrentFrame` counter which only increments on actual pixel changes, so the encoder naturally skips idle frames.

Additionally: the compositor's headless output refresh rate is NOT wired to the `fps` config. The fps CLI flag (`--fps 30`) flows through to the encode loop's sleep-based pacing, but the compositor output runs at wlroots' default rate independently. These two clocks are decoupled.

### Approach: Single Event Loop + Surface Commit Tracking

**Problem**: currently two competing clocks — our sleep-based encode loop AND the wlroots headless timer fire independently, drifting against each other.

**Fix**: remove our sleep-based pacing, let wlroots be the single clock.

#### Frame rate: compositor drives it

1. Pass `fps` to `Compositor.init(width, height, fps, render_device)`
2. Set headless output refresh rate: `wlr_output_state_set_custom_mode(state, w, h, fps * 1000)` (mHz)
3. `wl_event_loop_dispatch(loop, 100)` blocks until the next frame event (or 100ms timeout for housekeeping)
4. `handleFrame` fires synchronously inside dispatch — captures the buffer
5. After dispatch returns, encode if new, then check pings/meta/resize/app-alive

This also paces well-behaved Wayland clients via `frame_done`. No LD_PRELOAD FPS cap needed.

#### Damage detection: surface commit serial

Track `wlr_surface.current.seq` — increments on every `wl_surface.commit`. If unchanged since last frame, the app hasn't drawn anything new.

1. Add `last_surface_seq: u32` to `Compositor`
2. In `handleFrame`, compare `toplevel_surface.surface.current.seq` against `last_surface_seq`
3. Set `CapturedFrame.is_new` accordingly
4. `encoder.processFrame(false)` already handles idle skip (logs once, stops encoding, sends one keyframe on PLI for new viewers)

Equivalent to NvFBC's `dwCurrentFrame` — encode only when content changes.

#### Resulting loop (single clock)

```
while (!should_stop) {
    wl_event_loop_dispatch(loop, 100)     // blocks until frame event or timeout
      → handleFrame (synchronous)
        → check surface.current.seq → is_new
        → capture buffer (FBO or DMA-BUF)
        → commit, frame_done → paces app
    encoder.processFrame(is_new)          // skips if !is_new
    check pings, meta, resize, app alive  // housekeeping on elapsed time
}
```

### Files to Change
- `src/linux/wayland/compositor.zig` — add fps param, set output refresh rate, track surface seq, change dispatch to blocking
- `src/linux/wayland/app_share.zig` — pass fps to compositor, remove sleep-based pacing, simplify loop

---

## Gap 2: Input Injection (Priority 2)

### Problem

The Wayland compositor has a `wlr_seat` (required for keyboard focus) but no virtual input devices. Viewers cannot send mouse/keyboard/scroll events to shared apps. The X11 path uses XTEST for this. The `session.input_handler` field is never set in the Wayland app_share — it stays null, so all input from viewers is silently dropped.

### Approach: Virtual wlroots Input Devices

Create virtual input devices using the wlroots headless backend API, implement the `InputHandler` vtable, and wire it into the session. Full parity with X11: mouse move, click, scroll, keyboard.

### New File: `src/linux/wayland/input.zig`

**Init:**
1. Create virtual keyboard: `wlr_headless_add_input_device(backend, WLR_INPUT_DEVICE_KEYBOARD)`
2. Configure xkbcommon keymap on the keyboard (default layout)
3. Create virtual pointer: `wlr_headless_add_input_device(backend, WLR_INPUT_DEVICE_POINTER)`
4. Register both with the `wlr_seat` (set capabilities, attach devices)
5. When toplevel maps, call `wlr_seat_keyboard_enter` + `wlr_seat_pointer_enter` to give it focus

**InputHandler vtable implementation:**
- `moveFn` -> `wlr_seat_pointer_notify_motion_absolute` (coordinates relative to output)
- `mouseButtonFn` -> `wlr_seat_pointer_notify_button` (Linux BTN_LEFT/BTN_RIGHT/BTN_MIDDLE)
- `scrollFn` -> `wlr_seat_pointer_notify_axis` (WL_POINTER_AXIS_VERTICAL_SCROLL)
- `keyCodeFn` -> W3C code string -> evdev keycode via existing `keymap.zig` -> `wlr_seat_keyboard_notify_key`

### Thread Safety: Input Event Queue

Input events arrive from libdatachannel's network thread (via `InputHandler` callbacks), but wlroots is strictly single-threaded — all wlr_seat calls must happen on the thread that owns the `wl_display`.

Solution: ring buffer of input events. The `InputHandler` methods push events onto the queue (lock-free or mutex-protected). The encode loop drains the queue before each `compositor.dispatch()` call, applying events on the correct thread.

### Keyboard Focus

Since we only have one toplevel, focus management is trivial:
- On `handleToplevelMap`: `wlr_seat_keyboard_enter(seat, surface)` + `wlr_seat_pointer_enter(seat, surface, 0, 0)`
- No alt-tab, no window switching — the single app always has focus

### Key Differences from X11

| | X11 (XTEST) | Wayland (wlr_seat) |
|---|---|---|
| Keycodes | evdev + 8 offset | evdev directly |
| Coordinates | Display-global (absolute) | Surface-relative |
| Thread safety | Any thread (X11 handles it) | Single-threaded (needs queue) |
| Keymap | Not needed (raw keycodes) | xkbcommon keymap required |

### Files to Change
- `src/linux/wayland/input.zig` — new file, virtual input devices + InputHandler
- `src/linux/wayland/compositor.zig` — expose backend/seat for input init, focus management
- `src/linux/wayland/app_share.zig` — create WaylandInput, set `session.input_handler`
- `build_linux.zig` — add input.zig to wayland module, link xkbcommon (already linked for compositor)

---

## Gap 3: Configurable Rate Control — CQP vs VBR (Priority 3)

### Problem

Both pipelines use VBR with a custom bitrate formula. For screen sharing, Constant QP (CQP) may produce better results — consistent quality regardless of content complexity. We want to be able to switch between them at runtime to test experientially.

### Approach: CLI Flag

Add `--rc vbr|cqp` and optional `--qp N` flags to the `share app` command.

### Wire Path
1. **CLI** (`cli.zig`): parse `--rc` and `--qp` from share command args
2. **Control protocol** (`control.zig`): add `rc: RateControl` enum (`.vbr`, `.cqp`) and `qp: ?u32` to `ShareRequest`, serialize/parse in JSON
3. **Daemon** (`daemon.zig`): pass through to `AppShareConfig` / `WaylandAppShareConfig`
4. **NVENC init** (both `x11/nvenc.zig` and `wayland/nvenc.zig`):
   - If CQP: `rateControlMode = NV_ENC_PARAMS_RC_CONSTQP`, set `constQP = {qpIntra=N, qpInterP=N+4, qpInterB=N+4}`, skip bitrate/VBV fields
   - If VBR: current behavior unchanged
5. **VA-API** (`vaapi/vaapi.zig`): VA-API also supports CQP via `VA_RC_CQP` — same pattern, set QP on slice params instead of bitrate on rate control params

### Default Values
- `--rc vbr` (default — current behavior, safe for WebRTC congestion)
- `--qp 24` (default if CQP selected — good balance for screen sharing)
- Range: QP 16-32 reasonable for testing. QP 20 = high quality, QP 28 = lower quality/smaller

### Trade-offs
- **CQP pros**: Consistent quality, simpler, no bitrate formula tuning
- **CQP cons**: No bitrate ceiling — complex content can spike bandwidth, risk WebRTC congestion
- **VBR pros**: Bounded bandwidth, plays well with WebRTC congestion control
- **VBR cons**: Quality varies with content complexity

### Files to Change
- `src/shared/cli.zig` — parse `--rc` and `--qp` flags
- `src/shared/control.zig` — `RateControl` enum, add to `ShareRequest`
- `src/shared/daemon.zig` — pass rc/qp to configs
- `src/linux/x11/nvenc.zig` — CQP branch in init
- `src/linux/wayland/nvenc.zig` — same CQP branch (duplicate until deduped)
- `src/linux/vaapi/vaapi.zig` — CQP support for VA-API path

---

## Gap 4: Minor Items (Low Priority)

### Wayland Socket Naming
Socket name hardcoded to `"zerocast-0"`. Second concurrent session fails. Fix: use `"zerocast-{pid}"` or `"zerocast-{session_id_prefix}"`.

### NVENC Code Deduplication
`wayland/nvenc.zig` is a copy of `x11/nvenc.zig`. Any NVENC changes (CQP, buffer pool) must be made in both. Extract to a shared module — the build note says one `.zig` file can't be root of two modules, but it can be imported as a non-root dependency.

### Capture Timestamp
X11 gets `ulTimestampUs` from NvFBC for abs-capture-time RTP extension. Wayland has no capture timestamp from wlroots. Use `clock_gettime(CLOCK_MONOTONIC)` at frame callback time as approximation.

### NVENC Buffer Pool (Ghost Frames)
Single-buffer bug affects both X11 and Wayland NVENC paths. NVENC holds references to previous input buffers for reconstruction, causing ghost frames. Fix: pool of N surfaces. Not Wayland-specific — tracked separately.

---

## Execution Order

1. **Damage tracking + frame rate wiring** — biggest efficiency win, moderate change
2. **Input injection** — biggest feature gap, new file + wiring
3. **CQP rate control** — quality improvement, cross-cutting CLI/protocol/encoder change

Each item is independent and can be tested in isolation.
