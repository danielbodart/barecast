# Screen Sharing Tool — Research & Design Notes

## Vision

An opinionated, low-level screen sharing / pair programming tool built in Zig. Extremely fast, GPU-resident, minimal CPU usage. Linux-first, macOS later. Browser-based viewer — no install on the receiving end.

Think Tuple/Pop but leaner, faster, and elitist about hardware requirements.

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

### Capture Pipeline (Linux)

```
KMS/DRM framebuffer (GPU VRAM)
  → DMA-BUF file descriptor (via barecast-kms helper, CAP_SYS_ADMIN)
    → EGL image (eglCreateImage with EGL_LINUX_DMA_BUF_EXT)
      → GL texture (glEGLImageTargetTexture2DOES)
        → CUDA resource (cuGraphicsGLRegisterImage — zero-copy, pointer swap)
          → NVENC AV1 hardware encode (dedicated ASIC, not GPU compute)
            → encoded bitstream
              → libdatachannel (AV1 → RTP packetization, SRTP encryption)
                → WebRTC to browser
```

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

### Signaling & Infrastructure: Cloudflare Workers

All server-side infrastructure runs on Cloudflare Workers. Single deployment, no servers to manage.

#### Architecture

```
barecast.dev (Cloudflare Worker)
│
├── GET /                        → static viewer app (bundled in Worker)
├── GET /room/:id/ws             → WebSocket upgrade → Durable Object
└── POST /room/new               → (optional, rooms auto-create on first connect)
```

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

### Viewer: Browser Only

No native app install on the viewer side. Open a URL, browser hardware-decodes AV1 via WebRTC, renders it. Keyboard/mouse events sent back over WebRTC data channel.

Massive UX advantage over Tuple/Pop which require native installs on both sides.

### Remote Input (Sharer Receives Viewer's Input)

- Viewer captures keyboard/mouse in browser
- Sent over WebRTC data channel (low latency, encrypted)
- Sharer's Zig binary injects via **uinput** (same pattern as capsper)
- Works on both X11 and Wayland

### Privilege Separation

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

#### Architecture: `barecast-kms` helper

The helper is ~200-300 lines of Zig. It does exactly one thing: export DMA-BUF fds from the compositor's framebuffers.

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

## Build Tooling & Developer Experience

Same pattern as capsper: Bun TypeScript task runner + bootstrap script + mise for tool versioning.

### Bootstrap (`bootstrap.sh`)

Self-contained setup script. Installs mise (tool version manager), which installs pinned versions of Zig and Bun. Pulls git submodules. Makes `run.ts` self-executing via the shebang chain `#!/usr/bin/env ./bootstrap.sh` → `exec bun "$@"`.

Worktree-aware — resolves `TOOLS_ROOT` to the primary worktree so git worktrees share tool installations.

### Task Runner (`run.ts`)

Bun TypeScript script. All build commands live here — CI only calls `run.ts` targets, no build logic in workflow YAML.

```
./run.ts              # default: build + test
./run.ts build        # zig build (both barecast + barecast-kms)
./run.ts clean        # rm -rf dist/bin .zig-cache
./run.ts test         # zig build test (unit + property tests)
./run.ts lint         # static analysis + shellcheck
./run.ts setup        # build + install + setcap
./run.ts dist         # validate + package tarball
./run.ts ci           # full pipeline (test + build + dist + release)
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

### Tier 1: Zig Unit Tests

Inline `test` blocks in source files. Pure functions, no hardware dependencies. Fast, runs everywhere.

Target modules:
- **IPC wire protocol** — serialization/deserialization of KMS request/response structs
- **Signaling message parsing** — WebSocket JSON message handling
- **Bitrate adaptation logic** — packet loss / RTT → target bitrate calculations
- **Input event encoding/decoding** — keyboard/mouse events over the data channel
- **ULID/room ID generation** — correctness, uniqueness

```bash
./run.ts test         # or: zig build test
```

### Tier 2: Property-Based Tests

Using [minish](https://github.com/CogitatorTech/minish) (same as capsper). Tests invariants that must hold for all inputs.

Candidates:
- **IPC roundtrip** — serialize then deserialize any valid KMS response → identical output
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

| Technology | Role |
|---|---|
| **KMS/DRM** | Kernel Mode Setting — access GPU framebuffer directly |
| **DMA-BUF** | Kernel mechanism for sharing GPU buffer handles between processes without copying |
| **EGL + EGL_LINUX_DMA_BUF_EXT** | Import DMA-BUF fds as GPU textures |
| **CUDA** | Register GL textures as CUDA resources for NVENC |
| **NVENC** | NVIDIA's dedicated hardware video encoder ASIC |
| **VAAPI** | Video Acceleration API — AMD/Intel hardware encode (future) |
| **evdev / uinput** | Kernel input subsystem — capture and inject keyboard/mouse events |
| **libdatachannel** | WebRTC transport (ICE, DTLS, SRTP, data channels) |

## Reference: gpu-screen-recorder

[gpu-screen-recorder](https://git.dec05eba.com/gpu-screen-recorder/about/) by dec05eba is the closest existing project to study. Key source files:

| File | What it does |
|---|---|
| `src/capture/kms.c` (~1200 lines) | KMS/DRM capture, DMA-BUF → EGL image → GL texture |
| `src/capture/nvfbc.c` | NVIDIA Frame Buffer Capture (X11 only, not useful for us) |
| `src/capture/portal.c` (~900 lines) | xdg-desktop-portal + PipeWire capture |
| `src/encoder/video/nvenc.c` | CUDA interop + NVENC encode |
| `src/encoder/video/vaapi.c` | VAAPI encode via DMA-BUF export |
| `src/color_conversion.c` | GL shaders for RGB → NV12/P010 (BT.709/BT.2020) |
| `src/egl.c` | EGL context + DMA-BUF image creation |
| `src/pipewire_video.c` | PipeWire stream for portal-based DMA-BUF reception |
| `kms/server/kms_server.c` | Privileged setuid helper for DRM ioctls |

Architecture: plugin-based via C function pointers. Capture and encoder backends implement a common interface. Detect GPU at startup, pick best backend.

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
