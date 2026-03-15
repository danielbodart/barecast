# zerocast

Highly opinionated application sharing for developers.

- **Zero latency\*** — GPU-direct capture, hardware encode, P2P WebRTC with zero jitter buffer. End-to-end latency measured as low as 1ms on a local network. (\*We use the [abs-capture-time](https://webrtc.googlesource.com/src/+/refs/heads/main/docs/native-code/rtp-hdrext/abs-capture-time/) RTP extension to measure true capture-to-render latency, and [playout-delay](https://webrtc.googlesource.com/src/+/refs/heads/main/docs/native-code/rtp-hdrext/playout-delay/) set to zero to eliminate the browser's jitter buffer entirely.)
- **Zero CPU copy** — Pixels never leave the GPU. NvFBC capture, CUDA interop, NVENC encode — all on GPU hardware. The CPU only sees the encoded bitstream.
- **Zero audio, zero webcam** — Screen only. This is a collaboration tool, not a video call. Use your existing voice chat.
- **Zero install for viewers** — Open a URL, see the application. No native app, no extension, no plugin.
- **Zero shaders** — NvFBC gives a GPU texture. CUDA copies it to linear device memory. NVENC encodes with internal ARGB→NV12 color space conversion. No GL shaders, no compute passes.
- **Zero codec negotiation** — AV1 preferred, HEVC fallback. Auto-detected at startup. One codec per session, no mid-stream switching.
- **Zero infrastructure** — Signaling runs on Cloudflare Workers (serverless, hibernating Durable Objects). Media flows P2P via STUN. Cloudflare TURN as a last resort.
- **Zero config** — Run the binary, share the URL. That's it.

Built in Zig. Linux + NVIDIA today, macOS + Apple Silicon next.

> This project is a work in progress. The core capture and streaming pipeline is working end-to-end. See [Current Status](#current-status) for details.

## What It Does

Two sharing modes, both streaming over WebRTC to a browser viewer:

### Application Sharing (`zerocast share app <command>`)

Launches your application in an isolated headless Xorg display, captures it via NvFBC, and streams over WebRTC. Each app gets its own X server — no compositor needed, no interference with your host desktop.

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
├── share app glxgears     → Headless Xorg :10 → NvFBC → CUDA → NVENC (AV1/HEVC) → WebRTC
├── share app firefox      → Headless Xorg :11 → NvFBC → CUDA → NVENC (AV1/HEVC) → WebRTC
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
    → NVENC hardware encode (AV1 or HEVC, ARGB input, internal CSC to NV12)
      → libdatachannel (RTP packetization, SRTP, abs-capture-time)
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

## Codec Support

AV1 preferred, HEVC fallback. The codec is auto-detected at startup by querying the GPU's supported encode GUIDs. One codec per session — no mid-stream negotiation.

| Codec | GPU requirement | Browser decode |
|-------|----------------|---------------|
| **AV1** (preferred) | NVIDIA RTX 40-series+ (Ada/Blackwell) | Chrome 70+, Firefox 67+, Safari 17+ |
| **HEVC** (fallback) | NVIDIA GTX 950+ (Maxwell Gen 2+) | Chrome 107+, Safari 11+, Firefox 120+ |

### Why AV1 is Preferred

- **30–50% better compression** than HEVC at same quality — lower bandwidth for remote sessions
- **Universal browser decode** — all major browsers support AV1 WebRTC without flags
- **Future-proof** — when hardware encoders add screen content coding tools (IBC, palette mode), AV1 benefits most

### Why HEVC Fallback Matters

AV1 hardware encode requires RTX 40-series or newer. HEVC goes back to 2014 (GTX 950), covering the entire GTX 10-series, RTX 20-series, and RTX 30-series — a vastly larger installed base.

### NVENC Encoding Configuration

Both codecs share the same pipeline configuration:

- **P-only GOP** — `frameIntervalP=1`, no B-frames. Minimum encode latency. Keyframes only when a viewer joins or requests one via PLI.
- **Repeat headers** — Every keyframe includes sequence/parameter headers (AV1: `repeatSeqHdr`, HEVC: `repeatSPSPPS`), allowing late-joining viewers to start decoding immediately.
- **Adaptive VBR** — Linear bitrate scaling: `90kbps + (pixels × fps × 0.012)`, capped at 10Mbps. Max bitrate = 2× average. VBV buffer = 1 second. Calibrated for screen content: 150×150 at 98kbps, 1080p at approx 1.5Mbps, 4K at approx 3Mbps.
- **HQ tuning preset** — Counterintuitively, NVENC's high-quality preset (P4 + HQ tuning) produces better results for screen content than the low-latency preset.
- **BT.709 color metadata** — Explicit BT.709 primaries/transfer/matrix with limited range so browsers decode consistently. AV1 uses top-level config fields; HEVC uses VUI parameters.
- **Direct ARGB input** — NVENC takes ARGB directly (matching NvFBC's BGRA byte order on little-endian) and performs internal CSC to NV12. No CPU color conversion needed.

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
| `src/codec.zig` | Codec enum (AV1/HEVC) — shared across encoder, session, recorder |
| `src/encoder.zig` | Encode pipeline — CUDA copy, NVENC encode, idle detection, timing telemetry |
| `src/nvenc.zig` | NVENC SDK 12.0 bindings — AV1/HEVC config, codec detection, VBR rate control |
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
- NVIDIA GTX 950+ (HEVC) or RTX 40-series+ (AV1) — auto-detected at startup
- Intel/AMD VA-API — future Linux backend
- Apple Silicon (VideoToolbox) — future macOS backend

**Viewer (browser only):**
- Any modern browser — AV1 and HEVC are both widely supported in WebRTC

## Current Status

**Working end-to-end on Linux + NVIDIA + X11:**
- Application sharing with headless Xorg, NvFBC capture, hardware encode (AV1/HEVC), WebRTC streaming
- Terminal sharing with PTY, data channel transport, xterm.js viewer
- Multi-cursor collaboration with drawing/annotation
- Remote keyboard/mouse input
- Viewer-initiated resize
- Hub page with live session stats
- Cloudflare Worker signaling with TURN fallback

**Next:**
- macOS backend (ScreenCaptureKit + VideoToolbox + Metal)
- Linux Wayland support (KMS/DRM capture path is implemented, needs EGL→CUDA wiring)
- Intel/AMD GPU support via VA-API (HEVC + AV1)

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
./run.ts integration  # GPU integration test (captures 3s video, validates with ffprobe)
./run.ts worker-dev   # local Cloudflare Worker on :8787
./run.ts worker-deploy # deploy Worker to production
./run.ts rebuild-libs # rebuild libdatachannel static libs
./run.ts setup        # build + install + setcap
./run.ts clean        # rm -rf dist/bin .zig-cache
```

## Acknowledgements

- [libdatachannel](https://github.com/paullouisageneau/libdatachannel) by Paul-Louis Ageneau — lightweight WebRTC in C/C++
- [gpu-screen-recorder](https://git.dec05eba.com/gpu-screen-recorder/about/) by dec05eba — reference for NvFBC capture and NVENC encoding patterns
