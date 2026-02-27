# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## What is this?

Barecast is a low-level screen sharing / pair programming tool. Native Zig binary captures the screen via KMS/DRM, hardware-encodes AV1 via NVENC, and streams to a browser viewer over WebRTC. See `screen-share-research.md` for the full design.

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

# First-time setup (builds, installs binaries, sets CAP_SYS_ADMIN on barecast-kms)
./run.ts setup
```

### Cloudflare Worker (signaling server)

```bash
./run.ts worker-dev      # local dev server on :8787
./run.ts worker-deploy   # deploy to Cloudflare
```

## Architecture

Two Zig binaries + one Cloudflare Worker:

- **`barecast`** — Main binary (unprivileged). Screen capture pipeline: DMA-BUF → EGL → CUDA → NVENC AV1 → libdatachannel WebRTC → browser.
- **`barecast-kms`** — Privileged KMS helper (CAP_SYS_ADMIN). Opens `/dev/dri/card0`, exports DMA-BUF fds over Unix socketpair via SCM_RIGHTS. Intentionally minimal — no networking, no encoding.
- **`worker/`** — Cloudflare Worker + Durable Object. WebSocket signaling for SDP/ICE exchange. Rooms auto-create on first connection with client-generated IDs.

### Key source files

- **`src/main.zig`** — Entry point for the main binary.
- **`src/kms.zig`** — Entry point for the privileged KMS helper.
- **`src/protocol.zig`** — Wire protocol structs for IPC between barecast and barecast-kms.
- **`src/prop_tests.zig`** — Property-based tests (minish).
- **`worker/src/index.ts`** — Cloudflare Worker entry point.
- **`worker/src/room.ts`** — Durable Object for signaling rooms.

## Testing

```bash
./run.ts test    # unit + property tests (fast, no GPU)
./run.ts lint    # static analysis (zwanzig) + shellcheck
```

Three test tiers: unit tests (inline `test` blocks), property tests (minish), integration tests (Bun, requires GPU — not yet implemented).

## Conventions

- Zig 0.15 API: `b.createModule(...)` for executables
- CI only calls `run.ts` targets — no build logic in workflow YAML
- All server-side infrastructure is Cloudflare Workers (signaling, TURN config)
- libdatachannel for WebRTC transport (C API, callable from Zig)
- AV1 only, no codec fallback
