# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## What is this?

Zerocast is a highly opinionated screen sharing tool for developers. Native Zig binary captures the screen via KMS/DRM, hardware-encodes video via NVENC (AV1 preferred, HEVC fallback), and streams to a browser viewer over WebRTC. See `README.md` for the full design.

## Build & Run

Requires Linux with an NVIDIA GPU. Zig and Bun are installed automatically via `bootstrap.sh` + mise.

```bash
# Default: build + lint + unit tests
./run.ts

# Build only
./run.ts build

# Clean
./run.ts clean

# Unit + property tests
./run.ts test

# Static analysis
./run.ts lint

# Rebuild libdatachannel static libs (after submodule update)
./run.ts rebuild-libs

# Integration test (requires GPU)
./run.ts integration

# First-time setup (builds, installs binaries, sets CAP_SYS_ADMIN on zerocast-kms)
./run.ts setup
```

### Cloudflare Worker (signaling server)

```bash
./run.ts worker-dev      # local dev server on :8787
./run.ts worker-deploy   # deploy to Cloudflare
```

## Architecture

Two Zig binaries + one Cloudflare Worker:

- **`zerocast`** — Main binary (unprivileged). Screen capture pipeline: DMA-BUF → EGL → CUDA → NVENC (AV1/HEVC) → libdatachannel WebRTC → browser.
- **`zerocast-kms`** — Privileged KMS helper (CAP_SYS_ADMIN). Opens `/dev/dri/card0`, exports DMA-BUF fds over Unix socketpair via SCM_RIGHTS. Intentionally minimal — no networking, no encoding.
- **`worker/`** — Cloudflare Worker + Durable Object. WebSocket signaling for SDP/ICE exchange. Rooms auto-create on first connection with client-generated IDs.

### Source layout

```
src/
├── main.zig                              # Entry point — dispatches to daemon or CLI
├── shared/                               # Platform-agnostic code
│   ├── daemon.zig                        # Daemon mode (Unix socket, session slots, threads)
│   ├── cli.zig                           # CLI client (subcommands, socket client, help)
│   ├── control.zig                       # Wire protocol for daemon ↔ CLI (JSON/Unix socket)
│   ├── session.zig                       # Multi-viewer WebRTC broadcast (libdatachannel)
│   ├── encoder.zig                       # Encode pipeline with FrameSink dispatch
│   ├── terminal_share.zig                # Terminal share (PTY + asciinema v2)
│   ├── codec.zig, ivf.zig               # Codec types, IVF container writer
│   ├── session_recorder.zig              # IVF recording to disk
│   ├── input_protocol.zig                # Binary input message protocol
│   ├── viewer_state.zig                  # Viewer color/state tracking
│   ├── osc_parser.zig                    # Terminal OSC sequence parser
│   └── prop_tests.zig                    # Property-based tests (minish)
├── linux/
│   ├── x11/
│   │   ├── app_share.zig                # AppShare session (headless Xorg + NvFBC)
│   │   ├── encoder_backend.zig          # EncodeBackend impl (CUDA + NVENC)
│   │   ├── input.zig                    # Input injection (XTEST)
│   │   ├── keymap.zig                   # W3C code → evdev keycodes
│   │   ├── nvfbc.zig, cuda.zig          # NvFBC capture, CUDA texture copy
│   │   ├── nvenc.zig                    # NVENC hardware encoder
│   │   ├── headless_display.zig         # Headless Xorg lifecycle
│   │   ├── window_manager.zig           # Minimal X11 WM
│   │   └── xorg.zig                     # Setuid Xorg launcher helper
│   ├── kms/
│   │   ├── main.zig                     # zerocast-kms privileged helper entry
│   │   ├── drm.zig                      # KMS/DRM framebuffer capture
│   │   ├── ipc.zig                      # SCM_RIGHTS fd passing
│   │   └── protocol.zig                 # Wire protocol (zerocast ↔ zerocast-kms)
│   └── fpscap.zig                       # LD_PRELOAD FPS cap for GL apps
└── macos/
    ├── app_share.zig                    # AppShare session (ScreenCaptureKit)
    ├── encoder_backend.zig              # EncodeBackend impl (VideoToolbox HEVC)
    ├── input.zig                        # Input injection (CGEvent)
    ├── keymap.zig                       # W3C code → macOS virtual keycodes
    ├── screen_capture.{h,m}             # ScreenCaptureKit ObjC binding
    ├── videotoolbox.{h,m}               # VTCompressionSession ObjC wrapper
    ├── virtual_display.{h,m}            # CGVirtualDisplay ObjC binding
    └── vd_helper.m                      # CGVirtualDisplay helper process
```

### Worker source files

- **`worker/src/index.ts`** — Cloudflare Worker + routing.
- **`worker/src/viewer.ts`** — WebRTC browser viewer (screen share).
- **`worker/src/terminal-viewer.ts`** — xterm.js browser viewer (terminal share).
- **`worker/src/room.ts`** — Durable Object for signaling rooms with role tagging.

## Testing

```bash
./run.ts test    # unit + property tests (fast, no GPU)
./run.ts lint    # static analysis (zwanzig) + shellcheck
```

Three test tiers: unit tests (inline `test` blocks), property tests (minish), integration tests (`./run.ts integration`, requires GPU — captures 3s of video, validates with ffprobe).

## Conventions

- Zig 0.15 API: `b.createModule(...)` for executables
- **Always use `./run.ts <target>`** — never run `zig build`, `bun build`, `bun install`, `wrangler deploy`, etc. directly. `run.ts` is the single entry point for all build, test, lint, and deploy operations. It handles deps, submodules, versioning, and cmake libs automatically. If a command you need isn't there, add it to `run.ts`.
- **Binaries go to `dist/bin/`** — `./run.ts build` outputs to `dist/bin/zerocast` and `dist/bin/zerocast-kms`. Never look in `zig-out/` or `.zig-cache/` for built binaries. The `--prefix dist` flag in `run.ts build` controls this.
- **To run the daemon locally**: `ZEROCAST_URL=http://localhost:8787 dist/bin/zerocast daemon` (after `./run.ts build`)
- **To share screen**: `ZEROCAST_URL=http://localhost:8787 dist/bin/zerocast share screen [WxH+X+Y] --room <id>`
- **Never deploy from a dev machine** — all deployments (worker, releases) go through CI on push to trunk. Don't run `wrangler deploy` or `gh release create` locally.
- CI only calls `run.ts` targets — no build logic in workflow YAML
- All server-side infrastructure is Cloudflare Workers (signaling, TURN config)
- libdatachannel for WebRTC transport (C API, callable from Zig, statically linked)
- libdatachannel built with zig cc/c++ (libc++ ABI) to match Zig's linker
- AV1 preferred, HEVC fallback (auto-detected via NVENC GUID enumeration)
