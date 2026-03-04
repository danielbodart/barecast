# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## What is this?

Zerocast is a highly opinionated screen sharing tool for developers. Native Zig binary captures the screen via KMS/DRM, hardware-encodes AV1 via NVENC, and streams to a browser viewer over WebRTC. See `README.md` for the full design.

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

- **`zerocast`** — Main binary (unprivileged). Screen capture pipeline: DMA-BUF → EGL → CUDA → NVENC AV1 → libdatachannel WebRTC → browser.
- **`zerocast-kms`** — Privileged KMS helper (CAP_SYS_ADMIN). Opens `/dev/dri/card0`, exports DMA-BUF fds over Unix socketpair via SCM_RIGHTS. Intentionally minimal — no networking, no encoding.
- **`worker/`** — Cloudflare Worker + Durable Object. WebSocket signaling for SDP/ICE exchange. Rooms auto-create on first connection with client-generated IDs.

### Key source files

- **`src/main.zig`** — Entry point. Dispatches to daemon or CLI.
- **`src/daemon.zig`** — Daemon mode. Unix socket listener, session slot management, thread lifecycle.
- **`src/cli.zig`** — CLI client. Subcommand parser, socket client, help text.
- **`src/control.zig`** — Wire protocol for daemon ↔ CLI (JSON over Unix socket).
- **`src/screen_share.zig`** — Self-contained screen share session (NvFbc → Encoder → BroadcastSession).
- **`src/terminal_share.zig`** — Terminal share session (PTY + asciinema v2 recording).
- **`src/session.zig`** — Multi-viewer WebRTC broadcast (libdatachannel peer management, signaling).
- **`src/encoder.zig`** — Encode pipeline with FrameSink dispatch (IVF or WebRTC).
- **`src/kms.zig`** — Entry point for the privileged KMS helper.
- **`src/protocol.zig`** — Wire protocol structs for IPC between zerocast and zerocast-kms.
- **`src/prop_tests.zig`** — Property-based tests (minish).
- **`worker/src/index.ts`** — Cloudflare Worker + routing.
- **`worker/src/viewer.ts`** — WebRTC browser viewer (screen share).
- **`worker/src/terminal-viewer.ts`** — xterm.js browser viewer (terminal share).
- **`worker/src/room.ts`** — Durable Object for signaling rooms with role tagging.

## Testing

```bash
./run.ts test    # unit + property tests (fast, no GPU)
./run.ts lint    # static analysis (zwanzig) + shellcheck
```

Three test tiers: unit tests (inline `test` blocks), property tests (minish), integration tests (`./run.ts integration`, requires GPU — captures 3s IVF, validates with ffprobe).

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
- AV1 only, no codec fallback
