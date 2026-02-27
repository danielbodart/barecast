# Screen Sharing Tool — Research & Design Notes

## Vision

An opinionated, low-level screen sharing / pair programming tool built in Zig. Extremely fast, GPU-resident, minimal CPU usage. Linux-first, macOS later. Browser-based viewer — no install on the receiving end.

Think Tuple/Pop but leaner, faster, and elitist about hardware requirements.

## Implementation Status

What's built, what's next, what's later.

### Done

- **NvFBC capture** (`src/nvfbc.zig`) — Pure Zig bindings for NVIDIA's proprietary Frame Buffer Capture API. Dynamically loads `libnvidia-fbc.so.1`, creates GLX context, captures full-screen frames as GL textures. Primary capture backend for X11.
- **KMS/DRM capture** (`src/kms.zig`) — Privileged helper binary. Full DRM plane enumeration, GEM handle → DMA-BUF fd export, plane property extraction (type, CRTC position, rotation, source crop). Retained for Wayland (where NvFBC is unavailable).
- **IPC layer** (`src/protocol.zig`, `src/ipc.zig`) — Wire protocol structs (extern C ABI) for request/response between main binary and KMS helper. SCM_RIGHTS fd passing over Unix socketpair. Fully tested.
- **KMS client** (`src/kms_client.zig`) — Launches `barecast-kms` as subprocess, sends frame requests, receives DMA-BUF fds. Includes NVIDIA GPU card discovery via sysfs vendor ID.
- **Build system** (`build.zig`) — Two executable targets with module dependency graph, system library linking (libdrm, X11, GL), test framework, property tests via minish, static analysis via zwanzig.
- **Task runner** (`run.ts`) — Bun TypeScript. build/test/lint/setup/dist/ci/worker-dev/worker-deploy targets. Version string from git. Dependency checking via pkg-config.
- **Signaling server** (`worker/`) — Cloudflare Worker + Durable Object. WebSocket upgrade routing, message broadcast to room peers, peer disconnection notifications. Uses Hibernation API.
- **Unit + property tests** — Protocol serialization (5 tests), SCM_RIGHTS roundtrip (3 tests), property-based tests via minish (4 properties × 200 runs each).

### Next

- **CUDA interop** — Register GL textures (from NvFBC) as CUDA resources via `cuGraphicsGLRegisterImage`. Zero-copy pointer swap.
- **NVENC AV1 encode** — Initialize encoder session, configure for screen content (low-latency preset, 4:4:4 chroma), encode captured frames to AV1 bitstream.
- **libdatachannel integration** — Link the C API, implement signaling state machine (SDP offer/answer, ICE candidate exchange), media track for AV1 RTP.
- **Browser viewer** — WebRTC peer connection setup, AV1 decode via browser, video element binding. Replace placeholder HTML.
- **Signaling protocol** — Define message schema for SDP/ICE routing. Add sharer/viewer role detection in the Durable Object.

### Later

- **Bitrate adaptation** — Monitor packet loss / RTT from libdatachannel stats, adjust NVENC target bitrate dynamically.
- **Remote input** — Keyboard/mouse events from browser → data channel → uinput injection on sharer.
- **Region sharing** — Crop to sub-region at GL/CUDA stage. `barecast share [WxH+X+Y]`.
- **macOS backend** — ScreenCaptureKit + VideoToolbox + IOSurface.
- **VAAPI backend** — AMD/Intel hardware encode on Linux.

### Source Files

| File | Lines | What it does |
|---|---|---|
| `src/main.zig` | ~20 | Entry point. Creates NvFBC instance, grabs one frame, prints debug output. Stub — no encoding or streaming loop yet. |
| `src/nvfbc.zig` | ~465 | NvFBC bindings. Dynamic `libnvidia-fbc.so.1` loading, GLX context setup, frame capture → GL texture. |
| `src/kms.zig` | ~312 | KMS helper binary. DRM plane enumeration, GEM → DMA-BUF export, SCM_RIGHTS IPC. Runs with CAP_SYS_ADMIN. |
| `src/kms_client.zig` | ~188 | Launches `barecast-kms` subprocess, sends frame requests, receives DMA-BUF fds. NVIDIA GPU discovery via sysfs. |
| `src/protocol.zig` | ~115 | Wire protocol structs (extern C ABI). Request/Response types, Plane metadata, DmaBuf descriptors. |
| `src/ipc.zig` | ~223 | SCM_RIGHTS ancillary data over Unix socketpair. sendmsg/recvmsg with cmsg alignment. |
| `src/drm.zig` | ~90 | libdrm C bindings via `@cImport`. ~15 functions for plane/FB2/property enumeration. |
| `src/prop_tests.zig` | ~70 | Property-based tests (minish). 4 properties × 200 runs. |
| `worker/src/index.ts` | ~49 | Cloudflare Worker. Routes `/room/{id}/ws` → Durable Object, serves placeholder viewer HTML. |
| `worker/src/room.ts` | ~51 | SignalingRoom Durable Object. WebSocket broadcast to room peers, disconnect notification. |
| `build.zig` | ~178 | Build system. Two exe targets, module graph, test framework, zwanzig analyzer. |
| `run.ts` | ~160 | Bun task runner. build/test/lint/setup/dist/ci/worker targets. |

## Hardware Requirements (Deliberate)

**Sharer (native Zig binary):**
- NVIDIA RTX 40-series+ (NVENC AV1 encode)
- AMD RX 7000+ (VAAPI AV1 encode) — future backend
- Intel Arc / 12th-gen+ (VAAPI AV1 encode) — future backend
- Apple M3+ (VideoToolbox AV1 encode) — future platform

**Viewer (browser only):**
- Any browser with AV1 WebRTC decode (Chrome 70+, Firefox 67+, Safari 17+)
- Hardware AV1 decode on M1+, most GPUs from 2020+
- M1/M2 Macs can view but not share (no AV1 hardware encode)

## Codec: AV1 Only

No fallback. One codec path = simpler pipeline, fewer bugs, less testing.

### Why AV1 for screen sharing specifically

- **Screen Content Coding built into base spec** — Intra Block Copy (IBC), palette mode, transform skip. Not a bolted-on extension like HEVC SCC.
- **128x128 superblocks** — large static screen regions encode as single blocks with near-zero bits. Static regions cost almost nothing, which eliminates the need for dirty rect tracking.
- **56 directional intra prediction modes** (vs HEVC's 35) — sharp text edges predict cleanly.
- **Up to 7 reference frames** — unchanged regions can reference further back, spending essentially zero bits.
- **4:4:4 chroma in the base profile** — full color resolution, text looks perfect. No profile juggling needed.
- **~30-50% better compression than HEVC** at same quality — lower bandwidth, better on shared wifi.
- **Film grain synthesis** — strips noise at encode, resynthesises at decode. Encoder doesn't waste bits on dithering/subpixel rendering noise.
- **Built-in superresolution** — encode at lower res, upsample at decode. Useful for bandwidth-constrained situations.

### Dirty rects

macOS ScreenCaptureKit provides dirty rects natively. Linux KMS/DRM does not — you get the full composited framebuffer every time.

This doesn't matter much because AV1's skip-block mechanism handles unchanged regions implicitly. The encoder spends near-zero bits on static areas without explicit dirty rect hints.

If needed later: a GPU compute shader can diff the previous and current frame as textures and output a changed-block bitmask. But the encoder already does this internally.

## Architecture

### Capture Pipeline (Linux — NVIDIA + X11) [IMPLEMENTED]

```
NvFBC (NVIDIA Frame Buffer Capture, proprietary driver API)
  → GL texture (direct from NvFBC, no intermediate copies)      ← DONE
    → CUDA resource (cuGraphicsGLRegisterImage — zero-copy)      ← NEXT
      → NVENC AV1 hardware encode (dedicated ASIC)               ← NEXT
        → encoded bitstream
          → libdatachannel (AV1 → RTP packetization, SRTP)       ← NEXT
            → WebRTC to browser
```

NvFBC is the primary capture path. It's NVIDIA's proprietary screen capture API — a single call produces a GL texture of the entire screen. No DRM plane enumeration, no DMA-BUF export, no EGL import chain. Simpler and faster than KMS for X11.

**Why NvFBC over KMS on X11:** NVIDIA's proprietary driver does not populate KMS planes when running under X11. `drmModeGetFB2()` returns valid metadata but the GEM handles point to nothing useful — the X server owns the framebuffer through its own path, not through standard KMS. NvFBC bypasses this entirely by capturing from the GPU's internal display pipeline.

**Trade-off:** NvFBC requires `libnvidia-fbc.so.1` (ships with the NVIDIA driver). It's X11-only — not available under pure Wayland. For Wayland, the KMS path is retained.

### Capture Pipeline (Linux — KMS/DRM, for Wayland) [IMPLEMENTED]

```
KMS/DRM framebuffer (GPU VRAM)
  → DMA-BUF file descriptor (via barecast-kms helper, CAP_SYS_ADMIN)  ← DONE
    → EGL image (eglCreateImage with EGL_LINUX_DMA_BUF_EXT)
      → GL texture (glEGLImageTargetTexture2DOES)
        → CUDA resource (cuGraphicsGLRegisterImage)
          → NVENC AV1 hardware encode
            → encoded bitstream → libdatachannel → WebRTC
```

The KMS path goes through the `barecast-kms` privileged helper. Everything from DRM plane enumeration through DMA-BUF fd export is implemented and tested. The EGL import → GL texture → CUDA → NVENC chain is not yet wired up.

Everything stays GPU-resident. CPU usage near 0%.

### Capture Pipeline (macOS — Future)

```
ScreenCaptureKit
  → IOSurface (Apple's equivalent of DMA-BUF)
    → Metal texture (zero-copy)
      → VideoToolbox AV1 hardware encode (dedicated Media Engine ASIC)
        → encoded bitstream
          → libdatachannel → WebRTC to browser
```

Same zero-copy principle. IOSurface = DMA-BUF. Media Engine = NVENC ASIC. Different APIs, same architecture.

### Transport: WebRTC via libdatachannel

[libdatachannel](https://github.com/paullouisageneau/libdatachannel) — lightweight C/C++ WebRTC library with C API (callable from Zig). ~20MB vs Google's libwebrtc at 600MB.

**libdatachannel provides:**
- ICE + STUN + TURN (NAT traversal)
- DTLS encryption
- SRTP media transport
- AV1 RTP packetization
- Data channels (bidirectional — for input events)
- Browser compatibility (Firefox, Chrome, Safari)

**We provide:**
- Encoding/decoding (driving NVENC/VAAPI directly)
- Signaling server (Cloudflare Worker — see below)
- Bitrate adaptation (monitor packet loss / RTT, adjust encoder bitrate)

#### Why not Cloudflare Calls (Realtime SFU)?

Evaluated and rejected. Cloudflare Calls is an anycast SFU — media always relayed through Cloudflare's edge. Problems for our use case:

- **Data channels are unidirectional** (pub-to-sub only). For KVM input (viewer → sharer) you'd need two separate sessions per viewer — doubles connection management complexity.
- **No C API.** You'd need pion (Go) or webrtc-rs (Rust) to connect a native client. Wrapping those from Zig is worse than libdatachannel's clean C API.
- **AV1 support is undocumented.** Listed in the SFU limits page but never announced. No guarantee it handles AV1 dependency descriptors correctly.
- **Overkill for 1:1.** The SFU's main value is 1-to-many fanout. For pair programming (1:1, maybe 1:3), P2P is simpler and lower latency.
- **Always relayed.** Two devs on the same city network still go through Cloudflare. P2P via libdatachannel goes direct.

We **do** use Cloudflare for TURN relay (fallback when P2P fails) and for the signaling server (Worker + Durable Object). Just not the SFU.

### Signaling & Infrastructure: Cloudflare Workers [IMPLEMENTED — basic routing]

All server-side infrastructure runs on Cloudflare Workers. Single deployment, no servers to manage.

#### Architecture

```
barecast.dev (Cloudflare Worker)
│
├── GET /                        → static viewer app (bundled in Worker)    ← DONE (placeholder HTML)
├── GET /room/:id/ws             → WebSocket upgrade → Durable Object      ← DONE
└── POST /room/new               → (optional, rooms auto-create on first connect)
```

**Current state:** Worker routes `/room/{roomId}/ws` to a Durable Object. The DO accepts WebSocket upgrades, broadcasts messages to all other peers in the room, and notifies peers on disconnect. Messages are currently untyped — no SDP/ICE validation or sharer/viewer role detection yet. The viewer page at `/` is a placeholder with `<video>` element but no WebRTC code.

#### Room Management — Durable Objects

One Durable Object per room. Holds WebSocket connections for sharer + viewer(s). Routes signaling messages (SDP offers/answers, ICE candidates) between peers.

**Why WebSocket over SSE:** Durable Objects have a first-class [WebSocket Hibernation API](https://developers.cloudflare.com/durable-objects/api/websockets/). The DO accepts WebSockets, then hibernates — evicted from memory entirely, billed for nothing. Wakes on message, handles it, sleeps again. With SSE, the long-lived HTTP response keeps the DO active for the entire session duration. Since signaling is ~20 messages during setup then silence for the entire pair programming session, hibernation is perfect.

#### Room IDs — Client-Generated

Room IDs are client-generated (ULID or similar). No server round-trip needed to create a room — the sharer generates an ID locally, connects to `/room/:id/ws`, and the Durable Object auto-creates on first connection. Share the URL, viewer connects to the same room ID, signaling begins.

#### Signaling Flow

```
Sharer (Zig + libdatachannel)        Worker DO          Viewer (Browser)
  │                                      │                    │
  ├─── WebSocket connect ───────────────►│◄─── WebSocket ─────┤
  │                                      │                    │
  ├─── SDP offer ───────────────────────►│─── SDP offer ─────►│
  │                                      │                    │
  │◄── SDP answer ───────────────────────│◄── SDP answer ─────┤
  │                                      │                    │
  ├─── ICE candidates ─────────────────►│──► ICE candidates ─►│
  │◄── ICE candidates ──────────────────│◄── ICE candidates ──┤
  │                                      │                    │
  │   (WebRTC P2P connects)              │  (DO hibernates)   │
  │◄─────── direct P2P media ───────────────────────────────►│
  │◄─────── direct P2P data channel ────────────────────────►│
```

After WebRTC connects, the signaling WebSocket goes idle and the DO hibernates. All media and input flows P2P (or via TURN if P2P fails).

#### NAT Traversal

libdatachannel's ICE implementation handles this. Configured with:

- **STUN:** `stun.cloudflare.com:3478` (free, unlimited) — discovers public IP/port. Works for ~85% of home NATs.
- **TURN:** Cloudflare TURN relay (fallback for symmetric NATs, CGNAT, strict firewalls). $0.05/GB after 1 TB/month free. Standard TURN protocol — works with any WebRTC library including libdatachannel.

ICE tries paths in priority order: direct P2P → STUN-assisted P2P → TURN relay. Best working path wins.

#### Cost

| Component | Cost |
|---|---|
| Worker requests | Free tier: 100K/day. Paid: $0.50/million |
| Durable Objects | Free while hibernated. ~$0.00 for signaling |
| TURN relay | 1 TB/month free, then $0.05/GB |
| STUN | Free, unlimited |

For pair programming usage, this is effectively free.

### Viewer: Browser Only [PLACEHOLDER]

No native app install on the viewer side. Open a URL, browser hardware-decodes AV1 via WebRTC, renders it. Keyboard/mouse events sent back over WebRTC data channel.

Massive UX advantage over Tuple/Pop which require native installs on both sides.

**Current state:** Static HTML served from the Worker with a `<video>` element and status text. No JavaScript WebRTC implementation yet — waiting on signaling protocol definition and libdatachannel integration on the sharer side.

### Region Sharing (Future)

Support sharing a sub-region of the screen rather than the full display. Useful for ultrawide/multi-monitor setups where you want to keep parts of your workspace private.

**Syntax:** `barecast share [WxH+X+Y]` — standard X11 geometry format (used by xrandr, ffmpeg, wf-recorder).

**Where it happens in the pipeline:** At the GL/CUDA stage, not in KMS capture. The `barecast-kms` helper always captures the full framebuffer (DRM only gives you the whole thing). The main process crops to the requested geometry when setting up the NVENC input — just adjusted texture coordinates, essentially free on the GPU.

This means region sharing doesn't affect the KMS helper design at all.

### Remote Input (Sharer Receives Viewer's Input)

- Viewer captures keyboard/mouse in browser
- Sent over WebRTC data channel (low latency, encrypted)
- Sharer's Zig binary injects via **uinput** (same pattern as capsper)
- Works on both X11 and Wayland

### Privilege Separation [IMPLEMENTED]

Two Zig binaries: `barecast` (unprivileged) and `barecast-kms` (CAP_SYS_ADMIN file capability).

#### Why two binaries?

KMS framebuffer capture hits two kernel permission layers:

1. **Opening `/dev/dri/card0`** — requires `video` group membership (file is `0660 root:video`). Most desktop users already have this via logind `uaccess` ACLs.
2. **Getting GEM buffer handles** — `drmModeGetFB2()` succeeds for anyone, but **zeroes out GEM handles** unless the caller is DRM master or has `CAP_SYS_ADMIN`. Without real handles, `drmPrimeHandleToFD()` fails and you can't export DMA-BUFs.

You can't be DRM master because the compositor already is (only one master at a time). So `CAP_SYS_ADMIN` is the only option for a capture tool running alongside a desktop.

There is no finer-grained capability — no `CAP_DRM` exists. `CAP_SYS_ADMIN` is effectively root-equivalent (mount, ptrace, namespace creation, raw I/O ports, etc). This is why it goes on a tiny helper binary, not the main process.

#### Alternatives considered

| Approach | Verdict |
|---|---|
| **`video` group only** (capsper pattern) | Doesn't work. Group gets you through Layer 1 (device open) but not Layer 2 (GEM handles zeroed without CAP_SYS_ADMIN). evdev has no equivalent kernel gate — once you open the device, you can do everything. DRM is deliberately more locked down. |
| **`CAP_SYS_ADMIN` on main binary** | Works but dangerous. The entire application — networking, WebRTC, encoding — runs with root-equivalent power. A vulnerability in libdatachannel or signaling gives an attacker CAP_SYS_ADMIN. Sunshine does this and has been criticized for it. |
| **Reuse gpu-screen-recorder's `gsr-kms-server`** | Works but adds an external dependency. The wire protocol (C structs, version 5) is not a stable API. Not a single codebase. |
| **PipeWire / xdg-desktop-portal** | No privilege escalation needed — compositor mediates access. But adds PipeWire as a runtime dependency, extra latency, and significantly more complex code (~900 lines in gpu-screen-recorder's portal backend vs ~200 for KMS). Not available properly on X11. |
| **logind `TakeDevice`** | Can't work — `TakeControl` is exclusive and the compositor already holds it. Only one session controller at a time. |

#### Architecture: `barecast-kms` helper [IMPLEMENTED — 312 lines]

The helper does exactly one thing: export DMA-BUF fds from the compositor's framebuffers.

```
barecast (unprivileged, video group)
  │
  ├── socketpair(AF_UNIX, SOCK_STREAM)
  ├── fork() + exec("barecast-kms")
  │
  │   barecast-kms (CAP_SYS_ADMIN via file capability)
  │     ├── open("/dev/dri/card0", O_RDONLY)
  │     ├── drmSetClientCap(UNIVERSAL_PLANES)
  │     ├── drmSetClientCap(ATOMIC)
  │     └── loop:
  │           ├── recv request
  │           ├── drmModeGetPlaneResources()
  │           ├── drmModeGetPlane() → fb_id
  │           ├── drmModeGetFB2() → GEM handles (non-zero with CAP_SYS_ADMIN)
  │           ├── drmPrimeHandleToFD() → DMA-BUF fd
  │           └── sendmsg() with SCM_RIGHTS → DMA-BUF fd to parent
  │
  ├── recvmsg() → DMA-BUF fd via SCM_RIGHTS
  ├── eglCreateImage(EGL_LINUX_DMA_BUF_EXT)
  ├── GL texture → CUDA → NVENC → encode
  └── close(dma_buf_fd) → request next frame
```

IPC is a simple request/response over `socketpair()`. No path-based socket, no two-phase handshake (gpu-screen-recorder's complexity exists to support pkexec and Flatpak — we only support the `setcap` path).

#### Installation

```bash
sudo install -m 755 barecast /usr/local/bin/barecast
sudo install -m 755 barecast-kms /usr/local/bin/barecast-kms
sudo setcap cap_sys_admin+ep /usr/local/bin/barecast-kms
sudo usermod -aG video "$USER"  # most desktop users already have this
```

## Build Tooling & Developer Experience [IMPLEMENTED]

Same pattern as capsper: Bun TypeScript task runner + bootstrap script + mise for tool versioning.

### Bootstrap (`bootstrap.sh`)

Self-contained setup script. Installs mise (tool version manager), which installs pinned versions of Zig and Bun. Pulls git submodules. Makes `run.ts` self-executing via the shebang chain `#!/usr/bin/env ./bootstrap.sh` → `exec bun "$@"`.

Worktree-aware — resolves `TOOLS_ROOT` to the primary worktree so git worktrees share tool installations.

### Task Runner (`run.ts`)

Bun TypeScript script. All build commands live here — CI only calls `run.ts` targets, no build logic in workflow YAML.

```
./run.ts              # default: build + analyze + test (dev target)
./run.ts build        # zig build ReleaseSafe (both barecast + barecast-kms)
./run.ts clean        # rm -rf dist/bin .zig-cache
./run.ts test         # zig build test (unit + property tests)
./run.ts lint         # zwanzig static analysis + shellcheck
./run.ts setup        # build + install to /usr/local/bin + setcap CAP_SYS_ADMIN
./run.ts dist         # validate + package tarball with version
./run.ts ci           # lint + test + build + dist + gh release create
./run.ts worker-dev   # wrangler dev --port 8787
./run.ts worker-deploy # wrangler deploy
```

### Tool Versions (`.mise.toml`)

```toml
[tools]
zig = "0.15.2"
bun = "latest"
```

### Developer Workflow

```bash
git clone <repo> && cd barecast
./run.ts              # bootstrap installs tools, builds, tests — one command
./run.ts setup        # install binaries + setcap on barecast-kms
```

## Testing Strategy

Testing is paramount. Three tiers, each testable without the next tier's dependencies.

### Tier 1: Zig Unit Tests [IMPLEMENTED]

Inline `test` blocks in source files. Pure functions, no hardware dependencies. Fast, runs everywhere.

Implemented:
- **IPC wire protocol** (`protocol.zig`, 5 tests) — struct size stability, error message roundtrip + truncation at 127 bytes, fd collection with deduplication
- **SCM_RIGHTS transport** (`ipc.zig`, 3 tests) — real socketpair + `/dev/null` fd roundtrips, Request serialization, Response with error

Future modules (as they're built):
- **Signaling message parsing** — WebSocket JSON message handling
- **Bitrate adaptation logic** — packet loss / RTT → target bitrate calculations
- **Input event encoding/decoding** — keyboard/mouse events over the data channel

```bash
./run.ts test         # or: zig build test
```

### Tier 2: Property-Based Tests [IMPLEMENTED]

Using [minish](https://github.com/CogitatorTech/minish) (same as capsper). Tests invariants that must hold for all inputs. 200 randomized runs per property.

Implemented:
- **`prop_setError_roundtrip`** — arbitrary ASCII strings (0–200 bytes) survive error message truncation
- **`prop_setError_marks_err`** — any setError call marks response result as `.err`
- **`prop_collectFds_count`** — fd collection correctly filters invalid fds
- **`prop_default_response_is_ok`** — default Response always has `.ok` result, 0 planes

Future properties (as modules are built):
- **RTP packetization** — any AV1 bitstream packetized then reassembled → identical bitstream
- **Input event roundtrip** — encode then decode any keyboard/mouse event → identical event
- **Bitrate adaptation monotonicity** — higher packet loss → lower or equal target bitrate

```bash
zig build prop-test
```

### Tier 3: Integration Tests

Bun test scripts that exercise real hardware and network paths. Require GPU, run in CI with hardware or skipped gracefully.

Candidates:
- **KMS capture smoke test** — `barecast-kms` helper launches, returns valid DMA-BUF metadata (width > 0, height > 0, valid pixel format, valid fd)
- **NVENC encode smoke test** — capture one frame, encode to AV1, verify output is a valid AV1 OBU sequence
- **Signaling roundtrip** — two libdatachannel peers exchange SDP via a local WebSocket server, verify ICE connection establishes
- **Loopback end-to-end** — sharer encodes a known test pattern, viewer decodes via WebRTC, compare pixel output (SSIM/PSNR against reference)

```bash
./run.ts integration  # requires GPU
```

### Regression Testing

True visual regression (screenshot comparison) is hard for a screen sharing tool — the captured content is whatever's on screen. Possible approaches for later:

- **Synthetic framebuffer** — render a known test pattern to a virtual display (e.g., `Xvfb` or a headless KMS setup), capture it, encode, decode, compare against reference. Deterministic input = deterministic output.
- **Bitstream comparison** — for the same input frame at the same encoder settings, NVENC should produce identical output. Save reference bitstreams, compare byte-for-byte.
- **Latency regression** — measure encode time per frame over a standardized workload, flag if p99 regresses beyond a threshold.

These require infrastructure (virtual displays, reference data, CI with GPUs) so they come after the core product works.

## Implementation Order

1. **NVIDIA/CUDA/NVENC first** — all current machines have NVIDIA GPUs, fewer moving parts, more capable encoder API
2. **macOS second** — ScreenCaptureKit + VideoToolbox + IOSurface, same zero-copy concept, different APIs
3. **VAAPI backend later** — for AMD/Intel support on Linux

## Key Linux APIs & Technologies

| Technology | Role | Status |
|---|---|---|
| **NvFBC** | NVIDIA Frame Buffer Capture — proprietary API for direct screen capture as GL texture (X11 only) | **In use** |
| **KMS/DRM** | Kernel Mode Setting — access GPU framebuffer directly (Wayland path) | **In use** |
| **DMA-BUF** | Kernel mechanism for sharing GPU buffer handles between processes without copying | **In use** |
| **EGL + EGL_LINUX_DMA_BUF_EXT** | Import DMA-BUF fds as GPU textures | Not yet wired |
| **CUDA** | Register GL textures as CUDA resources for NVENC | Next |
| **NVENC** | NVIDIA's dedicated hardware video encoder ASIC | Next |
| **VAAPI** | Video Acceleration API — AMD/Intel hardware encode (future) | Later |
| **evdev / uinput** | Kernel input subsystem — capture and inject keyboard/mouse events | Later |
| **libdatachannel** | WebRTC transport (ICE, DTLS, SRTP, data channels) | Next |

## Reference: gpu-screen-recorder

[gpu-screen-recorder](https://git.dec05eba.com/gpu-screen-recorder/about/) by dec05eba is the closest existing project to study. Key source files:

| File | What it does | Relevance |
|---|---|---|
| `src/capture/kms.c` (~1200 lines) | KMS/DRM capture, DMA-BUF → EGL image → GL texture | Reference for our KMS path |
| `src/capture/nvfbc.c` | NVIDIA Frame Buffer Capture (X11 only) | **Reference for our primary capture path** — we now use NvFBC too |
| `src/capture/portal.c` (~900 lines) | xdg-desktop-portal + PipeWire capture | Not using (too complex) |
| `src/encoder/video/nvenc.c` | CUDA interop + NVENC encode | **Key reference for next phase** |
| `src/encoder/video/vaapi.c` | VAAPI encode via DMA-BUF export | Future AMD/Intel backend |
| `src/color_conversion.c` | GL shaders for RGB → NV12/P010 (BT.709/BT.2020) | May need for NVENC input format |
| `src/egl.c` | EGL context + DMA-BUF image creation | Reference for KMS → EGL path |
| `src/pipewire_video.c` | PipeWire stream for portal-based DMA-BUF reception | Not using |
| `kms/server/kms_server.c` | Privileged setuid helper for DRM ioctls | Inspired our `barecast-kms` design |

Architecture: plugin-based via C function pointers. Capture and encoder backends implement a common interface. Detect GPU at startup, pick best backend.

**Lessons learned from gpu-screen-recorder:** Their NvFBC path is the simplest capture backend (~200 lines vs ~1200 for KMS). We adopted the same approach — NvFBC for X11, KMS retained for Wayland. Their NVENC encoder (`src/encoder/video/nvenc.c`) is the key reference for our next implementation phase.

## Key macOS APIs (Future)

| Technology | Role | Linux equivalent |
|---|---|---|
| **ScreenCaptureKit** | Screen capture framework (macOS 12.3+) | KMS/DRM |
| **IOSurface** | Cross-process GPU memory handle | DMA-BUF |
| **Metal** | GPU API for texture import | EGL/OpenGL |
| **VideoToolbox** | Hardware encode/decode framework | VAAPI/NVENC |
| **Media Engine** | Dedicated encode/decode ASIC on M-series | NVENC ASIC |
| **CGEvent / IOHIDDevice** | Input injection | evdev/uinput |

Zig can call all of these via the Objective-C runtime C ABI. See [Mitchell Hashimoto's Zig + SwiftUI writeup](https://mitchellh.com/writing/zig-and-swiftui).
