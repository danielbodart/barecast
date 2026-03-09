# zerocast

Highly opinionated application sharing for developers.

- **Zero latency\*** — GPU-direct capture, hardware AV1 encode, P2P WebRTC with zero jitter buffer. End-to-end latency measured as low as 1ms on a local network. (\*We use the [abs-capture-time](https://webrtc.googlesource.com/src/+/refs/heads/main/docs/native-code/rtp-hdrext/abs-capture-time/) RTP extension to measure true capture-to-render latency, and [playout-delay](https://webrtc.googlesource.com/src/+/refs/heads/main/docs/native-code/rtp-hdrext/playout-delay/) set to zero to eliminate the browser's jitter buffer entirely.)
- **Zero CPU copy** — Pixels never leave the GPU. NvFBC capture, CUDA interop, NVENC AV1 encode — all on GPU hardware. The CPU only sees the encoded bitstream.
- **Zero audio, zero webcam** — Screen only. This is a collaboration tool, not a video call. Use your existing voice chat.
- **Zero legacy hardware** — Requires AV1 hardware encode (NVIDIA RTX 40-series+) to share. Requires AV1 hardware decode (most GPUs from 2020+, Apple M1+) to view. No software fallback.
- **Zero install for viewers** — Open a URL, see the application. No native app, no extension, no plugin.
- **Zero shaders** — NvFBC gives a GPU texture. CUDA copies it to linear device memory. NVENC encodes with internal ARGB→NV12 color space conversion. No GL shaders, no compute passes.
- **Zero codec negotiation** — AV1 only. One codec path, simpler pipeline, fewer bugs.
- **Zero infrastructure** — Signaling runs on Cloudflare Workers (serverless, hibernating Durable Objects). Media flows P2P via STUN. Cloudflare TURN as a last resort.
- **Zero config** — Run the binary, share the URL. That's it.

Built in Zig. Linux + NVIDIA today, macOS + Apple Silicon next.

> This project is a work in progress. The core capture and streaming pipeline is working end-to-end. See [Current Status](#current-status) for details.

## What It Does

Two sharing modes, both streaming over WebRTC to a browser viewer:

### Application Sharing (`zerocast share app <command>`)

Launches your application in an isolated headless Xorg display, captures it via NvFBC, and streams AV1 over WebRTC. Each app gets its own X server — no compositor needed, no interference with your host desktop.

- **Isolated display** — One headless Xorg per app (`:10`, `:11`, etc.), `UseDisplayDevice "none"` avoids modesetting conflicts with the host GPU
- **Viewer-initiated resize** — Viewer resizes their browser window, the pipeline tears down and rebuilds at the new resolution (~300ms)
- **Frame rate capping** — `fpscap.so` LD_PRELOAD hooks `glXSwapBuffers` with `clock_nanosleep` to prevent apps from spinning at 100% CPU in the vblank-less headless display
- **Remote input** — Keyboard and mouse events from the browser are injected into the headless display via XTEST. Platform-independent `KeyboardEvent.code` mapped to Linux keycodes
- **Input isolation** — `AutoAddDevices "false"` prevents physical keyboard/mouse from leaking into the headless display

### Terminal Sharing (`zerocast share terminal [command]`)

Spawns a PTY, streams terminal output over a WebRTC data channel to an xterm.js viewer in the browser.

- **Replay buffer** — 256KB ring buffer replays recent output to late-joining viewers
- **Resize** — Viewer resize propagates back via `TIOCSWINSZ`
- **Asciinema recording** — Optional recording in asciinema v2 format for playback later
- **Bidirectional** — Viewer keystrokes sent back over the data channel

### Multi-Cursor Collaboration

Every viewer gets an assigned color. Cursor positions and draw paths relay through the server to all other viewers in real-time.

- **SVG overlay** — Rendered browser-side with `viewBox` set to native video resolution. Bibata cursor shapes, per-viewer colored paths
- **Drawing mode** — Toggle with Tab. Left-drag to draw, right-click to undo, long-press right-click to clear
- **Binary wire protocol** — Compact little-endian messages over unreliable/unordered WebRTC data channel (UDP semantics). Mouse, keyboard, draw, resize, relay, and color assignment message types
- **Local-first rendering** — Own draw paths render instantly (no round-trip). Remote paths relay via `[0xFE][color_index][msg]` prefix

### Hub Page

Each room gets a landing page showing all active shares as live stats cards (resolution, FPS, bitrate, share type). Click a card to open the viewer in a pop-out window.

## Architecture

```
zerocast daemon
├── share app glxgears     → Headless Xorg :10 → NvFBC → CUDA → NVENC AV1 → WebRTC
├── share app firefox      → Headless Xorg :11 → NvFBC → CUDA → NVENC AV1 → WebRTC
├── share terminal         → PTY → data channel → xterm.js
└── Unix socket ← CLI commands (share, unshare, join, status)

Cloudflare Worker + Durable Object
├── WebSocket signaling (SDP/ICE exchange, hibernates when idle)
├── TURN credential provisioning (Cloudflare TURN API)
├── Hub page, viewer app, terminal viewer (served as static HTML/JS)
└── Room auto-creation on first connection (client-generated IDs)
```

### Capture Pipeline (Linux — NVIDIA + X11)

```
NvFBC (GPU texture, BGRA)
  → CUDA resource (cuGraphicsGLRegisterImage, zero-copy)
    → NVENC AV1 hardware encode (ARGB input, internal CSC to NV12)
      → libdatachannel (AV1 RTP packetization, SRTP, abs-capture-time)
        → WebRTC P2P to browser
```

Everything stays GPU-resident. CPU usage near 0%.

### Transport: WebRTC via libdatachannel

[libdatachannel](https://github.com/paullouisageneau/libdatachannel) — lightweight C/C++ WebRTC library (~20MB statically linked, vs Google's libwebrtc at 600MB). We maintain a [fork](https://github.com/danielbodart/libdatachannel) with two additions:

| Extension | What it does |
|---|---|
| **abs-capture-time** (extmap 3) | Embeds an NTP timestamp from the moment of GPU capture into each RTP packet. The browser reads this via `getSynchronizationSources().captureTimestamp` to compute true end-to-end latency. |
| **playout-delay** (extmap 4, min=max=0) | Instructs Chrome to render frames immediately with zero jitter buffer. Trades smoothness for latency — the right trade-off for interactive application sharing. |

**RTCP chain per peer:**
- Sender Reports for synchronization
- NACK responder with 512-packet retransmission history
- PLI handler — triggers instant keyframe on viewer join or packet loss recovery

**Why not Cloudflare Calls?** Their SFU relays all media through Cloudflare's edge (adds latency for same-network peers), has unidirectional data channels (breaks remote input), no C API, and is overkill for 1:1 or 1:few pair programming. We use Cloudflare for TURN relay and signaling only.

### Signaling: Cloudflare Workers

One Durable Object per room. WebSocket Hibernation API — the DO sleeps between messages, costing nothing during the actual sharing session. Signaling is ~20 messages at setup then silence.

```
Sharer (Zig)              Worker DO              Viewer (Browser)
  ├── WS connect ────────►│◄── WS connect ────────┤
  ├── SDP offer ──────────►│──► SDP offer ─────────►│
  │◄── SDP answer ─────────│◄── SDP answer ─────────┤
  ├── ICE candidates ─────►│──► ICE candidates ────►│
  │                        │   (DO hibernates)      │
  │◄────── direct P2P media + data channel ────────►│
```

NAT traversal: STUN (`stun.cloudflare.com`) for ~85% of connections, Cloudflare TURN relay as fallback.

## AV1: Why, and What We Use

No codec fallback. AV1 only. One path = simpler pipeline.

### Hardware-Accelerated AV1 Features (active in our pipeline)

These are AV1 capabilities that NVENC implements in hardware and that we benefit from:

- **Screen Content Coding** — Intra Block Copy (IBC), palette mode, and transform skip are part of the AV1 base spec (not a bolted-on extension like HEVC SCC). These tools are designed for sharp edges, flat colors, and repeated patterns — exactly what application UIs look like.
- **128x128 superblocks** — Large static regions (IDE backgrounds, terminal backgrounds) encode as single blocks with near-zero bits. Eliminates the need for dirty rect tracking — the encoder handles unchanged regions implicitly.
- **Up to 7 reference frames** — Unchanged regions can reference further back in the stream, spending essentially zero bits. Combined with infinite GOP (keyframes only on PLI), this means static content is almost free.
- **P-only GOP** — `frameIntervalP=1`, no B-frames. Minimum encode latency. Keyframes only when a viewer joins or requests one via PLI.
- **Repeat sequence headers** — Every keyframe includes the sequence header, allowing late-joining viewers to start decoding immediately without waiting for a periodic IDR.
- **Adaptive VBR** — Linear bitrate scaling: `90kbps + (pixels × fps × 0.012)`, capped at 10Mbps. Max bitrate = 2× average. VBV buffer = 1 second. Calibrated for screen content: 150×150→98kbps, 1080p→~1.5Mbps, 4K→~3Mbps.
- **HQ tuning preset** — Counterintuitively, NVENC's high-quality preset (P4 + HQ tuning) produces better results for screen content than the low-latency preset.
- **BT.709 color metadata** — Explicit `colorPrimaries=1, transferCharacteristics=1, matrixCoefficients=1, colorRange=limited` so browsers decode consistently instead of guessing "unspecified."

### AV1 Features We Can't Use Yet

These are in the AV1 spec but not available in current hardware encoders:

| Feature | Why we want it | Why we can't have it |
|---|---|---|
| **4:4:4 chroma** (High Profile) | Screen content has subpixel antialiasing with distinct R/G/B values — 4:2:0 averages them out, causing colour fringing on text edges | NVENC AV1 rejects `chromaFormatIDC != 1`. Browsers don't negotiate AV1 High Profile in WebRTC. Blocked at two independent layers. NVIDIA may add it (they did for H.264/HEVC). |
| **Film grain synthesis** | Strip noise at encode, resynthesize at decode — saves bits on dithered/antialiased content | Not implemented in any hardware encoder. |
| **Super-resolution** | Encode at lower resolution, upsample at decode — useful when bandwidth is tight | Not in hardware encoders. |
| **Temporal AQ** | Adaptive quantization across frames — spend bits where temporal complexity is high | NVENC supports this for H.264/HEVC but not AV1. |
| **Emphasis level map** | Per-block quality control (foveated encoding) — sharpen text, soften backgrounds | NVENC SDK: H.264-only. Returns `err_invalid_param` for AV1. |

**What we do instead:** NVENC takes ARGB input directly (matching NvFBC's BGRA byte order on little-endian) and performs internal CSC to NV12 before encoding. AV1's screen content coding tools compensate well — text remains readable and colour fringing is minimal at typical bitrates.

## Latency Telemetry

The stats panel in the viewer breaks down latency into components:

| Metric | How it's measured |
|---|---|
| **End-to-end** | abs-capture-time NTP timestamp vs `Date.now()` at render |
| **Server** | e2e − browser delay |
| **Decode** | `totalDecodeTime` from WebRTC stats (per-frame average) |
| **Jitter buffer** | `jitterBufferDelay / jitterBufferEmittedCount` (should be ~0 with playout-delay=0) |
| **Render** | Browser delay − processing delay (compositor + vsync wait) |
| **Network** | RTT/2 from ICE candidate pair stats |

Plus: resolution, FPS, bitrate, packets lost, decoder implementation (hardware/software), candidate type (host/srflx/relay).

## Project Structure

| File | What it does |
|---|---|
| `src/app_share.zig` | App sharing session — headless Xorg, NvFBC capture loop, resize, input |
| `src/terminal_share.zig` | Terminal sharing — PTY, replay buffer, asciinema recording |
| `src/session.zig` | WebRTC broadcast — peer lifecycle, signaling, data channels, relay |
| `src/encoder.zig` | Encode pipeline — CUDA copy, NVENC encode, idle detection, timing telemetry |
| `src/nvenc.zig` | NVENC SDK 12.0 bindings — AV1 config, VBR rate control, capability query |
| `src/cuda.zig` | CUDA Driver API — GL texture interop, pitched device memory |
| `src/nvfbc.zig` | NvFBC bindings — GPU texture capture, polling mode |
| `src/daemon.zig` | Daemon — Unix socket listener, session slots (up to 8), thread lifecycle |
| `src/cli.zig` | CLI — subcommand parser (`share`, `unshare`, `join`, `status`) |
| `src/control.zig` | Wire protocol — JSON over Unix socket between CLI and daemon |
| `src/headless_display.zig` | Headless Xorg — config generation, display discovery, xrandr resize |
| `src/xorg.zig` | Setuid helper — Xorg process lifecycle (minimal, root-only) |
| `src/xtest_input.zig` | Input injection — XTEST extension, keycode mapping |
| `src/input_protocol.zig` | Binary protocol — mouse, keyboard, draw, resize, relay messages |
| `src/viewer_state.zig` | Multi-viewer state — color assignment, cursor/path tracking |
| `src/fpscap.zig` | Frame rate cap — LD_PRELOAD `glXSwapBuffers` hook |
| `src/kms.zig` | KMS helper — DRM plane capture, DMA-BUF export (retained for Wayland) |
| `worker/src/room.ts` | Durable Object — signaling, TURN credentials, shares-list broadcast |
| `worker/src/hub.ts` | Hub page — live session cards, pop-out viewer windows |
| `worker/src/viewer.ts` | App viewer — WebRTC client, stats panel, abs-capture-time e2e latency |
| `worker/src/terminal-viewer.ts` | Terminal viewer — xterm.js + WebRTC data channel |
| `worker/src/overlay.ts` | SVG overlay — multi-cursor rendering, draw paths, Bibata cursors |
| `worker/src/input.ts` | Input controller — binary encoding, coordinate mapping, draw/input modes |
| `build.zig` | Build system — executables, modules, static libdatachannel, tests |
| `run.ts` | Task runner — build, test, lint, setup, worker-dev, worker-deploy |

## Hardware Requirements

**Sharer (native Zig binary):**
- NVIDIA RTX 40-series+ (NVENC AV1 encode) — currently the only supported backend
- AMD/Intel VAAPI AV1 — future Linux backend
- Apple M3+ (VideoToolbox AV1) — future macOS backend

**Viewer (browser only):**
- Any browser with AV1 WebRTC decode (Chrome 70+, Firefox 67+, Safari 17+)
- Hardware AV1 decode recommended (M1+, most GPUs from 2020+)

## Current Status

**Working end-to-end on Linux + NVIDIA + X11:**
- Application sharing with headless Xorg, NvFBC capture, AV1 encode, WebRTC streaming
- Terminal sharing with PTY, data channel transport, xterm.js viewer
- Multi-cursor collaboration with drawing/annotation
- Remote keyboard/mouse input
- Viewer-initiated resize
- Hub page with live session stats
- Cloudflare Worker signaling with TURN fallback

**Next:**
- macOS backend (ScreenCaptureKit + VideoToolbox + Metal)
- Linux Wayland support (KMS/DRM capture path is implemented, needs EGL→CUDA wiring)
- AMD/Intel GPU support via VAAPI

## Build & Run

Requires Linux with an NVIDIA GPU. Zig and Bun are installed automatically via `bootstrap.sh` + mise.

```bash
git clone <repo> && cd zerocast
./run.ts              # bootstrap, build, lint, test — one command
./run.ts setup        # install binaries + setcap on helpers

# Run locally
./run.ts worker-dev                                              # signaling server on :8787
ZEROCAST_URL=http://localhost:8787 dist/bin/zerocast daemon      # start daemon
dist/bin/zerocast join myroom                                    # join a room
dist/bin/zerocast share app glxgears                             # share an app
dist/bin/zerocast share terminal                                 # share a terminal
```

```
./run.ts              # build + lint + test (default)
./run.ts build        # zig build ReleaseSafe
./run.ts test         # unit + property tests
./run.ts lint         # zwanzig static analysis + shellcheck
./run.ts integration  # GPU integration test (captures 3s IVF, validates with ffprobe)
./run.ts worker-dev   # local Cloudflare Worker on :8787
./run.ts worker-deploy # deploy Worker to production
./run.ts rebuild-libs # rebuild libdatachannel static libs
./run.ts setup        # build + install + setcap
./run.ts clean        # rm -rf dist/bin .zig-cache
```

## Acknowledgements

- [libdatachannel](https://github.com/paullouisageneau/libdatachannel) by Paul-Louis Ageneau — lightweight WebRTC in C/C++
- [gpu-screen-recorder](https://git.dec05eba.com/gpu-screen-recorder/about/) by dec05eba — reference for NvFBC capture and NVENC encoding patterns
