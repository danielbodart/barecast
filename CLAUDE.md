# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## What is this?

Zerocast is a highly opinionated screen sharing tool for developers. A single native Zig binary runs apps in an embedded Wayland compositor (wlroots), hardware-encodes AV1 via NVENC (NVIDIA) or VA-API (Intel/AMD), with SVT-AV1 as a software fallback, and streams to a browser viewer over WebRTC. See `README.md` for the full design.

## Build & Run

Requires Linux with an NVIDIA GPU. Zig and Bun are installed automatically via `bootstrap.sh` + mise.

The build is orchestrated by **mise** (see `.mise.toml`). mise is the engine —
it handles dependency ordering, parallelism, and skip-if-fresh caching. `run.ts`
is a thin convenience wrapper: `./run.ts <task>` is just `mise run <task>`.
Anything in `.mise.toml` is callable via `./run.ts <task>` or directly
`mise run <task>`.

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

# Rebuild native static libs (libdatachannel + SVT-AV1, in parallel)
./run.ts libs

# Integration test (requires GPU)
./run.ts integration

# First-time setup (builds, symlinks the binary into ~/.local/bin, ensures group membership)
./run.ts setup

# Show full task graph for a target
mise tasks deps build
```

### Cloudflare Worker (signaling server)

```bash
./run.ts worker-dev      # local dev server on :8787
./run.ts worker-deploy   # deploy to Cloudflare
```

## Architecture

One Zig binary + one Cloudflare Worker:

- **`zerocast`** — Single unprivileged binary. App share pipeline: embedded wlroots compositor → GL renderbuffer → CUDA / VA-API / GL readback → NVENC / VA-API / SVT-AV1 → libdatachannel WebRTC → browser. AV1 only.
- **`worker/`** — Cloudflare Worker + Durable Object. WebSocket signaling for SDP/ICE exchange. Rooms auto-create on first connection with client-generated IDs.

### Source layout

All first-party and vendored code lives under `packages/`. Submodules (libdatachannel, wlroots, svt-av1) are peer packages, not privileged dependencies.

```
packages/
├── zerocast/src/                         # Our Zig binary
├── worker/                               # Our Cloudflare Worker + browser viewers
├── libdatachannel/                       # Submodule: WebRTC transport
├── wlroots/                              # Submodule: embedded Wayland compositor
└── svt-av1/                              # Submodule: SVT-AV1 software encoder
```

```
packages/zerocast/src/
├── main.zig                              # Entry point — dispatches to daemon or CLI
├── shared/                               # Platform-agnostic code
│   ├── daemon.zig                        # Daemon mode (Unix socket, session slots, threads)
│   ├── cli.zig                           # CLI client (subcommands, socket client, help)
│   ├── control.zig                       # Wire protocol for daemon ↔ CLI (JSON/Unix socket)
│   ├── session.zig                       # Multi-viewer WebRTC broadcast (libdatachannel)
│   ├── encoder.zig                       # Encode pipeline with FrameSink dispatch
│   ├── svt_backend.zig                   # SVT-AV1 software EncodeBackend (CPU fallback)
│   ├── terminal_share.zig                # Terminal share (PTY + asciinema v2)
│   ├── codec.zig, ivf.zig                # Codec types, IVF container writer
│   ├── session_recorder.zig              # IVF recording to disk
│   ├── input_protocol.zig                # Binary input message protocol
│   ├── viewer_state.zig                  # Viewer color/state tracking
│   ├── osc_parser.zig                    # Terminal OSC sequence parser
│   ├── yuv.zig                           # RGBA → I420 BT.709 conversion
│   └── prop_tests.zig                    # Property-based tests (minish)
├── linux/
│   ├── keymap.zig                        # W3C code → evdev keycodes
│   ├── gpu_detect.zig                    # GPU auto-detection (sysfs + CUDA/VA-API probing)
│   ├── wayland/
│   │   ├── app_share.zig                 # AppShare session (wlroots compositor)
│   │   ├── compositor.zig                # Embedded wlroots headless compositor
│   │   ├── nvenc_backend.zig             # EncodeBackend impl (CUDA + NVENC)
│   │   ├── nvenc.zig                     # NVENC hardware encoder (AV1)
│   │   ├── cuda.zig                      # CUDA GL renderbuffer interop
│   │   ├── frame_download.zig            # GL FBO readback for the SVT-AV1 path
│   │   ├── input.zig                     # Input injection (wlr_seat)
│   │   └── gles2_helper.c                # GL RBO extraction from wlroots
│   └── vaapi/
│       ├── vaapi.zig                     # VA-API encoder (Intel QSV / AMD VCN)
│       └── encoder_backend.zig           # EncodeBackend impl (VA-API)
└── macos/
    ├── app_share.zig                     # AppShare session (ScreenCaptureKit + SVT-AV1)
    ├── frame_download.zig                # IOSurface → I420 readback for SVT-AV1
    ├── input.zig                         # Input injection (CGEvent)
    ├── keymap.zig                        # W3C code → macOS virtual keycodes
    ├── screen_capture.{h,m}              # ScreenCaptureKit ObjC binding
    └── virtual_display.{h,m}             # CGVirtualDisplay ObjC binding
```

### Worker source files

- **`packages/worker/src/index.ts`** — Cloudflare Worker + routing.
- **`packages/worker/src/viewer.ts`** — WebRTC browser viewer (screen share).
- **`packages/worker/src/terminal-viewer.ts`** — xterm.js browser viewer (terminal share).
- **`packages/worker/src/room.ts`** — Durable Object for signaling rooms with role tagging.

## Testing

```bash
./run.ts test    # unit + property tests (fast, no GPU)
./run.ts lint    # static analysis (zwanzig) + shellcheck
```

Three test tiers: unit tests (inline `test` blocks), property tests (minish), integration tests (`./run.ts integration`, requires GPU — captures 3s of video, validates with ffprobe).

## Conventions

- Zig 0.15 API: `b.createModule(...)` for executables
- **Always use `./run.ts <target>` (or `mise run <target>`)** — never run `zig build`, `bun build`, `bun install`, `wrangler deploy`, etc. directly. The mise task graph in `.mise.toml` is the single source of truth for build orchestration. It handles deps, submodules, versioning, and cmake libs automatically. If a task you need isn't there, add it to `.mise.toml`.
- **Binary goes to `dist/bin/`** — `./run.ts build` outputs to `dist/bin/zerocast`. Never look in `zig-out/` or `.zig-cache/` for built binaries. The `--prefix dist` flag in `run.ts build` controls this.
- **To run the daemon locally**: `ZEROCAST_URL=http://localhost:8787 dist/bin/zerocast daemon` (after `./run.ts build`)
- **To share an app**: `ZEROCAST_URL=http://localhost:8787 dist/bin/zerocast share app glxgears`
- **Never deploy from a dev machine** — all deployments (worker, releases) go through CI on push to trunk. Don't run `wrangler deploy` or `gh release create` locally.
- CI only calls `run.ts` targets — no build logic in workflow YAML
- All server-side infrastructure is Cloudflare Workers (signaling, TURN config)
- libdatachannel for WebRTC transport (C API, callable from Zig, statically linked)
- libdatachannel built with zig cc/c++ (libc++ ABI) to match Zig's linker
- AV1 only — HEVC and the X11/NvFBC pipeline were retired. NVENC, VA-API, and SVT-AV1 are the three EncodeBackend implementations.
