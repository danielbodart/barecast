# zerocast

Highly opinionated application sharing for developers.

- **Zero latency\*** — GPU-direct capture, hardware encode, P2P WebRTC with zero jitter buffer. End-to-end latency measured as low as 1ms on a local network. (\*We use the [abs-capture-time](https://webrtc.googlesource.com/src/+/refs/heads/main/docs/native-code/rtp-hdrext/abs-capture-time/) RTP extension to measure true capture-to-render latency, and [playout-delay](https://webrtc.googlesource.com/src/+/refs/heads/main/docs/native-code/rtp-hdrext/playout-delay/) set to zero to eliminate the browser's jitter buffer entirely.)
- **Zero CPU copy on the GPU path** — The wlroots compositor renders client surfaces into a GL renderbuffer that CUDA imports directly. NVENC reads ARGB and produces AV1; the CPU only sees the encoded bitstream.
- **Zero audio, zero webcam** — Screen only. This is a collaboration tool, not a video call. Use your existing voice chat.
- **Zero install for viewers** — Open a URL, see the application. No native app, no extension, no plugin.
- **Zero codec negotiation** — AV1, period. NVENC for NVIDIA, VA-API for Intel/AMD, SVT-AV1 in software when neither is available. The encoder is auto-detected at startup.
- **Zero infrastructure** — Signaling runs on Cloudflare Workers (serverless, hibernating Durable Objects). Media flows P2P via STUN. Cloudflare TURN as a last resort.
- **Zero config** — Run the binary, share the URL. That's it.
- **Zero privileged helpers** — One unprivileged binary. No setuid, no setcap, no daemons running as root.

Built in Zig. Linux today, macOS in progress.

> This project is a work in progress. The core capture and streaming pipeline is working end-to-end. See [Current Status](#current-status) for details.

## What It Does

Two sharing modes, both streaming over WebRTC to a browser viewer:

### Application Sharing (`zerocast share app <command>`)

Launches your application against a private wlroots compositor running headless inside the daemon, captures every committed frame, encodes it as AV1, and streams over WebRTC. Each app gets its own embedded compositor — no host display interaction, no DBus integration, no portal dialogs.

- **Embedded Wayland compositor** — wlroots in headless mode, one per share. The client app talks Wayland to a `WAYLAND_DISPLAY` socket the daemon owns; nothing leaks to your real desktop.
- **Damage-driven event loop** — The compositor's headless output drives the encode loop. `wl_event_loop_dispatch` blocks until the next frame, and surface commit serials act as damage tracking — idle apps produce no encoded frames.
- **Remote input** — Keyboard and mouse events from the browser are injected via virtual `wlr_keyboard` and `wlr_pointer` devices on the embedded `wlr_seat`. Platform-independent `KeyboardEvent.code` mapped to evdev keycodes.
- **App-driven sizing** — The app's native size is authoritative. If the app resizes its toplevel, the encoder rebuilds at the new resolution.

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
├── share app glxgears     → wlroots compositor → GL FBO → CUDA / VA-API / readback → AV1 encode → WebRTC
├── share app firefox      → wlroots compositor → GL FBO → CUDA / VA-API / readback → AV1 encode → WebRTC
├── share terminal         → PTY → data channel → xterm.js
└── Unix socket ← CLI commands (share, unshare, join, status)

Cloudflare Worker + Durable Object
├── WebSocket signaling (SDP/ICE exchange, hibernates when idle)
├── TURN credential provisioning (Cloudflare TURN API)
├── Hub page, viewer app, terminal viewer (served as static HTML/JS)
└── Room auto-creation on first connection (client-generated IDs)
```

### Capture Pipeline

The daemon picks an `EncodeBackend` at startup based on what the host can do (`linux/gpu_detect.zig`). All three produce AV1 over the same `Encoder` orchestrator and `FrameSink` distributor.

**NVIDIA — NVENC (preferred when available):**
```
wlroots compositor (GLES2)
  → GL renderbuffer (ARGB)
    → cuGraphicsGLRegisterImage (zero-copy GPU import)
      → NVENC AV1 (internal CSC to NV12)
        → libdatachannel (RTP packetization, SRTP, abs-capture-time)
          → WebRTC P2P to browser
```

**Intel / AMD — VA-API:**
```
wlroots compositor → DMA-BUF export → VA-API AV1 → libdatachannel → browser
```

**Software fallback — SVT-AV1:**
```
wlroots compositor → glReadPixels → RGBA→I420 → SVT-AV1 (preset 12) → libdatachannel → browser
```

The SVT-AV1 path is the GPU-free safety net. It's also the test encoder — every layer of the pyramid above the browser can run on a CI runner without a GPU because SVT-AV1 produces real, valid AV1 bitstream in software.

### Transport: WebRTC via libdatachannel

[libdatachannel](https://github.com/paullouisageneau/libdatachannel) — lightweight C/C++ WebRTC library (~20MB statically linked, vs Google's libwebrtc at 600MB). We maintain a [fork](https://github.com/danielbodart/libdatachannel) with two additions:

| Extension | What it does |
|---|---|
| **abs-capture-time** (extmap 3) | Embeds an NTP timestamp from the moment of capture into each RTP packet. The browser reads this via `getSynchronizationSources().captureTimestamp` to compute true end-to-end latency. |
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

## Codec: AV1 only

AV1 is the only codec. There is no fallback to HEVC, no negotiation, no per-session selection.

- **30–50% better compression** than HEVC at same quality — lower bandwidth for remote sessions
- **Universal browser decode** — Chrome 70+, Firefox 67+, Safari 17+ all support AV1 in WebRTC without flags
- **Three encoder paths** — NVENC (NVIDIA, RTX 40-series+), VA-API (Intel ≥Tiger Lake, AMD RDNA 2+), SVT-AV1 (anywhere). The daemon probes the GPU at startup and picks the best one available; SVT-AV1 always works.

### Encode configuration

All three backends share the same orchestration in `shared/encoder.zig`:

- **Infinite GOP, P-only** — `gopLength = 0xFFFFFFFF`, `frameIntervalP = 1`. No B-frames, no scheduled keyframes. Keyframes are sent only when a viewer joins or requests one via PLI.
- **Idle keyframe suppression** — Once a keyframe has been delivered while content is static, further PLIs during idle are dropped. Browsers stop sending PLIs once they decode a frame, so the burst is self-limiting.
- **CQP by default** — Constant QP (default `--qp 20`) gives consistent quality regardless of content complexity. Crucial for text-heavy screen sharing where VBR would aggressively quantize static P-frames into a blurry mess. VBR is available via `--rc vbr` for bandwidth-constrained scenarios.
- **BT.709 with limited range** — Explicit primaries/transfer/matrix so browsers decode consistently across wide-gamut and SDR displays.
- **Repeat headers** — Every keyframe carries sequence/parameter headers so late-joining viewers can start decoding immediately.

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

| Path | What it does |
|---|---|
| `packages/zerocast/src/main.zig` | Entry point — dispatches to daemon or CLI |
| `packages/zerocast/src/shared/daemon.zig` | Daemon — Unix socket listener, session slots, thread lifecycle |
| `packages/zerocast/src/shared/cli.zig` | CLI — subcommand parser (`share`, `unshare`, `join`, `status`) |
| `packages/zerocast/src/shared/control.zig` | Wire protocol — JSON over Unix socket between CLI and daemon |
| `packages/zerocast/src/shared/session.zig` | WebRTC broadcast — peer lifecycle, signaling, data channels, relay |
| `packages/zerocast/src/shared/encoder.zig` | Encode pipeline — backend dispatch, idle detection, timing, FrameSink distribution |
| `packages/zerocast/src/shared/svt_backend.zig` | SVT-AV1 software EncodeBackend (CPU fallback, also the test encoder) |
| `packages/zerocast/src/shared/codec.zig` | Codec identity (AV1 only) |
| `packages/zerocast/src/shared/terminal_share.zig` | Terminal sharing — PTY, replay buffer, asciinema recording |
| `packages/zerocast/src/shared/input_protocol.zig` | Binary protocol — mouse, keyboard, draw, resize, relay messages |
| `packages/zerocast/src/shared/viewer_state.zig` | Multi-viewer state — color assignment, cursor/path tracking |
| `packages/zerocast/src/linux/gpu_detect.zig` | Backend selection — sysfs vendor probe + NVENC/VA-API capability check |
| `packages/zerocast/src/linux/wayland/app_share.zig` | App share session — embedded compositor + encoder pipeline |
| `packages/zerocast/src/linux/wayland/compositor.zig` | wlroots headless compositor — output, surface tracking, dispatch |
| `packages/zerocast/src/linux/wayland/nvenc.zig` | NVENC SDK 12.0 bindings — AV1 config, capability detection |
| `packages/zerocast/src/linux/wayland/nvenc_backend.zig` | EncodeBackend impl — CUDA GL interop + NVENC |
| `packages/zerocast/src/linux/wayland/cuda.zig` | CUDA Driver API — GL renderbuffer interop, pitched device memory |
| `packages/zerocast/src/linux/wayland/frame_download.zig` | GL FBO readback for the SVT-AV1 software path |
| `packages/zerocast/src/linux/wayland/input.zig` | Input injection — virtual `wlr_keyboard` + `wlr_pointer` |
| `packages/zerocast/src/linux/vaapi/vaapi.zig` | VA-API encoder (Intel QSV / AMD VCN) |
| `packages/zerocast/src/linux/vaapi/encoder_backend.zig` | EncodeBackend impl (VA-API + DMA-BUF) |
| `packages/worker/src/room.ts` | Durable Object — signaling, TURN credentials, shares-list broadcast |
| `packages/worker/src/hub.ts` | Hub page — live session cards, pop-out viewer windows |
| `packages/worker/src/viewer.ts` | App viewer — WebRTC client, stats panel, abs-capture-time e2e latency |
| `packages/worker/src/terminal-viewer.ts` | Terminal viewer — xterm.js + WebRTC data channel |
| `packages/worker/src/overlay.ts` | SVG overlay — multi-cursor rendering, draw paths, Bibata cursors |
| `packages/worker/src/input.ts` | Input controller — binary encoding, coordinate mapping, draw/input modes |
| `build.zig` | Build system — executable, modules, static libdatachannel + SVT-AV1, tests |
| `.mise.toml` | Task graph — build, test, lint, libs, worker, ci. The single source of truth for orchestration. |
| `run.ts` | Thin wrapper around `mise run` |

## Hardware Requirements

**Sharer:**
- NVIDIA GPU with AV1 encode (RTX 40-series, Ada/Blackwell), **or**
- Intel iGPU with AV1 encode (Tiger Lake / Arc / Meteor Lake+), **or**
- AMD GPU with AV1 encode (RDNA 2+ / RDNA 3), **or**
- **Any x86_64 CPU** — SVT-AV1 software fallback always works (preset 12, real-time at modest resolutions).

The daemon probes available encoders at startup and picks the fastest one; you don't choose. macOS support (Apple Silicon via SVT-AV1) is in progress.

**Viewer (browser only):**
- Any modern browser — AV1 in WebRTC is broadly supported.

## Current Status

**Working end-to-end on Linux:**
- Application sharing through the embedded wlroots compositor with AV1 hardware encode (NVENC) or software encode (SVT-AV1)
- Terminal sharing with PTY, data channel transport, xterm.js viewer
- Multi-cursor collaboration with drawing/annotation
- Remote keyboard/mouse input via virtual wlroots seat devices
- Hub page with live session stats
- Cloudflare Worker signaling with TURN fallback

**In progress:**
- VA-API (Intel/AMD) end-to-end validation
- macOS backend (ScreenCaptureKit + SVT-AV1)
- Viewer-initiated resize (currently the app's native size is authoritative)

## Build & Run

Requires Linux. Zig and Bun are installed automatically via `bootstrap.sh` + mise.

```bash
git clone <repo> && cd zerocast
./run.ts              # bootstrap, build, lint, test — one command
./run.ts setup        # symlink the binary into ~/.local/bin, ensure group membership

# Run locally
./run.ts worker-dev                                              # signaling server on :8787
ZEROCAST_URL=http://localhost:8787 dist/bin/zerocast daemon      # start daemon
dist/bin/zerocast join myroom                                    # join a room
dist/bin/zerocast share app glxgears                             # share an app
dist/bin/zerocast share terminal                                 # share a terminal
```

Common tasks (all dispatch through `./run.ts <task>`, which is `mise run <task>`):

```
./run.ts              # build + lint + test (default)
./run.ts build        # ReleaseSafe build into dist/bin/zerocast
./run.ts test         # unit + property tests
./run.ts lint         # zwanzig static analysis + shellcheck
./run.ts integration  # GPU integration test (captures 3s video, validates with ffprobe)
./run.ts sw-integration # GPU-free SVT-AV1 lane (CI-safe)
./run.ts compositor-test # wlroots compositor integration test (requires GPU)
./run.ts worker-dev   # local Cloudflare Worker on :8787
./run.ts libs         # rebuild libdatachannel + SVT-AV1 static libs
./run.ts clean        # rm -rf dist/bin .zig-cache
```

## Acknowledgements

- [libdatachannel](https://github.com/paullouisageneau/libdatachannel) by Paul-Louis Ageneau — lightweight WebRTC in C/C++
- [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) — modular Wayland compositor library
- [SVT-AV1](https://gitlab.com/AOMediaCodec/SVT-AV1) — open-source AV1 software encoder
- [gpu-screen-recorder](https://git.dec05eba.com/gpu-screen-recorder/about/) by dec05eba — reference for NVENC encoding patterns
