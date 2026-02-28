# zerocast

Highly opinionated screen sharing for developers.

- **Zero CPU copy** — Pixels never leave the GPU. Screen capture, layout conversion, color conversion, and AV1 encode all happen on GPU hardware. The CPU only sees the encoded bitstream. CPU usage near 0%.
- **Zero audio, zero webcam** — Screen only. This is a pair programming tool, not a video call. Use your existing voice chat.
- **Zero legacy hardware** — Requires AV1 hardware encode (NVIDIA RTX 40-series+ or Apple M3+) to share. Requires AV1 hardware decode (most GPUs from 2020+, Apple M1+) to view. No software fallback.
- **Zero install for viewers** — Open a URL, see the screen. PWA for a near-borderless window. No native app needed, no extension, no plugin.
- **Zero shaders** — NvFBC gives us a GPU texture. CUDA copies it to linear device memory, then NVENC encodes it with internal ARGB→NV12 color space conversion. No CPU pixel processing, no GL shaders, no compute passes.
- **Zero codec negotiation** — AV1 only. One codec path = simpler pipeline, fewer bugs, less testing.
- **Minimal latency** — GPU-direct capture, hardware encode, P2P WebRTC transport. No compositor round-trip, no CPU encode.
- **Minimal infrastructure** — Signaling runs on Cloudflare Workers (serverless). Media flows P2P via STUN. Cloudflare TURN as a last resort.
- **Minimal dependencies** — staticly link libdatachannel (~20MB) instead of Google's libwebrtc (600MB). Native Zig binary, only real external dependency is OpenSSL
- **Minimal config** — Run the binary, share the URL. That's it.

Built in Zig. Linux-first, macOS next

## Implementation Status

What's built, what's next, what's later.

### Done

- **NvFBC capture** (`src/nvfbc.zig`) — Pure Zig bindings for NVIDIA's proprietary Frame Buffer Capture API. Dynamically loads `libnvidia-fbc.so.1`, creates GLX context, captures full-screen frames as GL textures. Primary capture backend for X11.
- **KMS/DRM capture** (`src/kms.zig`) — Privileged helper binary. Full DRM plane enumeration, GEM handle → DMA-BUF fd export, plane property extraction (type, CRTC position, rotation, source crop). Retained for Wayland (where NvFBC is unavailable).
- **IPC layer** (`src/protocol.zig`, `src/ipc.zig`) — Wire protocol structs (extern C ABI) for request/response between main binary and KMS helper. SCM_RIGHTS fd passing over Unix socketpair. Fully tested.
- **KMS client** (`src/kms_client.zig`) — Launches `zerocast-kms` as subprocess, sends frame requests, receives DMA-BUF fds. Includes NVIDIA GPU card discovery via sysfs vendor ID.
- **Build system** (`build.zig`) — Two executable targets with module dependency graph, system library linking (libdrm, X11, GL), test framework, property tests via minish, static analysis via zwanzig.
- **Task runner** (`run.ts`) — Bun TypeScript. build/test/lint/setup/dist/ci/worker-dev/worker-deploy targets. Version string from git. Dependency checking via pkg-config.
- **Signaling server** (`worker/`) — Cloudflare Worker + Durable Object. WebSocket upgrade routing, message broadcast to room peers, peer disconnection notifications. Uses Hibernation API.
- **Unit + property tests** — Protocol serialization (5 tests), SCM_RIGHTS roundtrip (3 tests), IVF container (3 tests), property-based tests via minish (4 properties × 200 runs each).
- **CUDA interop** (`src/cuda.zig`) — CUDA Driver API bindings via dlopen. Registers NvFBC GL textures as CUDA resources (`cuGraphicsGLRegisterImage`), copies to pitched device memory via `cuMemcpy2D`. Zero-copy GL→CUDA path.
- **NVENC AV1 encode** (`src/nvenc.zig`) — Direct NVENC SDK 12.0 bindings via dlopen. Pure Zig extern structs with comptime size assertions. AV1 encode with P4 preset, low-latency tuning, constQP 28, ARGB input (BGRA from NvFBC). NVENC handles internal CSC to NV12.
- **IVF container writer** (`src/ivf.zig`) — Writes AV1 bitstream to IVF files (DKIF header + per-frame headers). Millisecond timebase with real wall clock PTS.
- **Encode pipeline** (`src/encoder.zig`) — Orchestrates NvFBC → CUDA → NVENC → IVF. Frame skip tracking, keyframe interval, stats.
- **Capture CLI** — `zerocast` streams via WebRTC (default), `zerocast --record output.ivf [seconds]` records to IVF. SIGINT/SIGTERM handling.
- **libdatachannel integration** (`src/webrtc.zig`) — Static link via cmake (built with zig cc for libc++ ABI). Zig bindings wrapping the C API: peer connection, sendonly AV1 track with RTP packetizer (90kHz clock, 1200 byte fragments), signaling WebSocket, PLI-triggered keyframes. Thread-safe: atomics for state/keyframe flags, callbacks fire on libdatachannel threads.
- **FrameSink abstraction** (`src/encoder.zig`) — Tagged union `FrameSink = union(enum) { ivf, webrtc }`. Encoder dispatches encoded data to either IVF writer or WebRTC track. PLI keyframe forcing for WebRTC path.
- **Browser viewer** (`worker/src/index.ts`) — Full WebRTC viewer served on `/` and `?room=` paths. RTCPeerConnection with STUN, `ontrack` → `<video>` binding, SDP answer generation, ICE candidate exchange. Status overlay (Connecting → Waiting → Negotiating → hidden on play → Disconnected).
- **Signaling protocol** (`worker/src/room.ts`) — Role-tagged WebSocket connections (`?role=sharer|viewer`). `peer-joined` notifications on connect, verbatim message relay between peers. JSON messages: offer, answer, ice, peer-joined, peer-disconnected.

### Next

- **Bitrate adaptation** — Monitor packet loss / RTT from libdatachannel stats, adjust NVENC target bitrate dynamically (REMB callback is stubbed).
- **Remote input** — Keyboard/mouse events from browser → data channel → uinput injection on sharer.
- **Region sharing** — Crop to sub-region at GL/CUDA stage. `zerocast share [WxH+X+Y]`.

### Later

- **macOS backend** — ScreenCaptureKit + VideoToolbox + IOSurface.
- **VAAPI backend** — AMD/Intel hardware encode on Linux.

### Source Files

| File | Lines | What it does |
|---|---|---|
| `src/main.zig` | ~240 | Entry point. CLI parsing (stream vs `--record`), WebRTC mode (room ID, signaling, wait for viewer), record mode (IVF), signal handler. |
| `src/webrtc.zig` | ~250 | libdatachannel Zig bindings. Peer connection, AV1 track + packetizer, signaling WebSocket, callbacks, minimal JSON helpers. |
| `src/nvfbc.zig` | ~465 | NvFBC bindings. Dynamic `libnvidia-fbc.so.1` loading, GLX context setup, frame capture → GL texture. 33ms sampling rate for ~30fps pacing. |
| `src/cuda.zig` | ~275 | CUDA Driver API via dlopen. GL texture interop, pitched device memory allocation, CUarray→linear copy. |
| `src/nvenc.zig` | ~790 | Direct NVENC SDK 12.0 via dlopen. AV1 encode (P4/low-latency/constQP 28), ARGB input, comptime struct size assertions. |
| `src/ivf.zig` | ~190 | IVF container writer. 32-byte file header + 12-byte frame headers. Millisecond PTS timebase. 3 unit tests. |
| `src/encoder.zig` | ~105 | Pipeline orchestration. NvFBC → CUDA → NVENC → FrameSink dispatch (IVF or WebRTC). PLI keyframe support. |
| `src/kms.zig` | ~312 | KMS helper binary. DRM plane enumeration, GEM → DMA-BUF export, SCM_RIGHTS IPC. Runs with CAP_SYS_ADMIN. |
| `src/kms_client.zig` | ~188 | Launches `zerocast-kms` subprocess, sends frame requests, receives DMA-BUF fds. NVIDIA GPU discovery via sysfs. |
| `src/protocol.zig` | ~115 | Wire protocol structs (extern C ABI). Request/Response types, Plane metadata, DmaBuf descriptors. |
| `src/ipc.zig` | ~223 | SCM_RIGHTS ancillary data over Unix socketpair. sendmsg/recvmsg with cmsg alignment. |
| `src/drm.zig` | ~90 | libdrm C bindings via `@cImport`. ~15 functions for plane/FB2/property enumeration. |
| `src/prop_tests.zig` | ~70 | Property-based tests (minish). 4 properties × 200 runs. |
| `worker/src/index.ts` | ~130 | Cloudflare Worker. Routes `/room/{id}/ws` → Durable Object, serves full WebRTC viewer HTML/JS. |
| `worker/src/room.ts` | ~60 | SignalingRoom Durable Object. Role-tagged WebSocket connections, peer-joined broadcast, message relay. |
| `build.zig` | ~300 | Build system. Two exe targets, encode + webrtc modules, cmake rebuild-libs step, static link libdatachannel, test framework. |
| `run.ts` | ~210 | Bun task runner. build/test/lint/setup/dist/ci/integration/rebuild-libs/worker targets. |

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
- **4:4:4 chroma in the AV1 spec** — see [4:4:4 chroma section](#444-chroma--why-we-cant-have-it) below.
- **~30-50% better compression than HEVC** at same quality — lower bandwidth for remote sessions over residential internet.
- **Film grain synthesis** — strips noise at encode, resynthesises at decode. Encoder doesn't waste bits on dithering/subpixel rendering noise.
- **Built-in superresolution** — encode at lower res, upsample at decode. Useful when bandwidth is tight on remote connections.

### 4:4:4 Chroma — Why We Can't Have It

Screen sharing is the one use case where 4:4:4 chroma genuinely matters. Text rendering uses subpixel antialiasing with distinct R/G/B values per pixel — 4:2:0 chroma subsampling averages those out, causing colour fringing on sharp text edges. This is why RDP and VNC use lossless RGB, and why every screen sharing tool that uses video codecs gets complaints about blurry text.

AV1 supports 4:4:4 in its High Profile. The spec is fine. The problem is the entire hardware pipeline refuses to cooperate:

| Layer | 4:4:4 support | Notes |
|---|---|---|
| **AV1 spec** | Yes (High Profile) | Fully specified |
| **NVENC AV1** | **No** | `chromaFormatIDC` must be 1 (YUV420). NVENC H.264/HEVC *can* do 4:4:4, but NVENC AV1 cannot. Confirmed by testing — encoder rejects any other chroma format. |
| **Browser AV1 decode** | Unlikely | Chrome/Firefox WebRTC stacks negotiate Main Profile (4:2:0). No browser has shipped High Profile AV1 decode for WebRTC. Even if the decoder silicon supports it, the WebRTC negotiation won't offer it. |
| **libdatachannel** | N/A | Passes through whatever the encoder produces. Not a bottleneck. |
| **Software AV1 encoders** | Yes (libaom, SVT-AV1) | But real-time 4K screen sharing on CPU is not viable. |

So we're blocked at two independent layers: the hardware encoder can't produce it, and the browser can't consume it via WebRTC. Either one alone would kill the path.

**What we do instead:** NvFBC captures BGRA. We pass it to NVENC as `NV_ENC_BUFFER_FORMAT_ARGB` (BGRA on little-endian). NVENC performs internal CSC from ARGB → NV12 (4:2:0) before encoding. The chroma subsampling happens inside the encoder ASIC — no CPU shader pass needed.

**Why it's acceptable:** AV1's screen content coding tools — Intra Block Copy, palette mode, transform skip — compensate surprisingly well. At constQP 28, text remains readable and colour fringing is minimal. The 128×128 superblocks also help: large solid-colour regions (IDE backgrounds, terminal backgrounds) encode as single palette-mode blocks where chroma subsampling is irrelevant.

**Future escape hatches:**
- NVIDIA may add 4:4:4 to NVENC AV1 in a future GPU generation (they did it for H.264/HEVC, so there's precedent)
- Browsers may eventually support AV1 High Profile in WebRTC (Chrome bug tracker has requests)
- If both happen simultaneously, we just flip `chromaFormatIDC` and the SDP profile negotiation — the rest of the pipeline is unchanged

### Dirty rects

macOS ScreenCaptureKit provides dirty rects natively. Linux KMS/DRM does not — you get the full composited framebuffer every time.

This doesn't matter much because AV1's skip-block mechanism handles unchanged regions implicitly. The encoder spends near-zero bits on static areas without explicit dirty rect hints.

If needed later: a GPU compute shader can diff the previous and current frame as textures and output a changed-block bitmask. But the encoder already does this internally.

## Architecture

### Capture Pipeline (Linux — NVIDIA + X11) [IMPLEMENTED — end-to-end WebRTC]

```
NvFBC (NVIDIA Frame Buffer Capture, proprietary driver API)
  → GL texture (BGRA, direct from NvFBC)                        ← DONE
    → CUDA resource (cuGraphicsGLRegisterImage — zero-copy)      ← DONE
      → NVENC AV1 hardware encode (ARGB input, internal CSC)     ← DONE
        → libdatachannel (AV1 → RTP packetization, SRTP)         ← DONE
          → WebRTC to browser                                     ← DONE
        → (optional) IVF file via --record flag                   ← DONE
```

**Tested:** 3840x1600 live WebRTC streaming to browser viewer via Cloudflare Worker signaling. Also: 3840x1600 at ~30fps AV1 constQP 28 IVF recording. CLI: `zerocast` (stream) or `zerocast --record output.ivf [seconds]` (record).

**Key discovery during implementation:** NVENC AV1 does NOT support 4:4:4 chroma (`chromaFormatIDC` must be 1 = YUV420). NvFBC captures BGRA, which maps to `NV_ENC_BUFFER_FORMAT_ARGB` on little-endian. NVENC performs internal CSC from ARGB to NV12 before encoding. Output is YUV420. For screen sharing this is acceptable — AV1's screen content coding tools (IBC, palette mode, transform skip) compensate for the chroma subsampling on text.

NvFBC is the primary capture path. It's NVIDIA's proprietary screen capture API — a single call produces a GL texture of the entire screen. No DRM plane enumeration, no DMA-BUF export, no EGL import chain. Simpler and faster than KMS for X11.

**Why NvFBC over KMS on X11:** NVIDIA's proprietary driver does not populate KMS planes when running under X11. `drmModeGetFB2()` returns valid metadata but the GEM handles point to nothing useful — the X server owns the framebuffer through its own path, not through standard KMS. NvFBC bypasses this entirely by capturing from the GPU's internal display pipeline.

**Trade-off:** NvFBC requires `libnvidia-fbc.so.1` (ships with the NVIDIA driver). It's X11-only — not available under pure Wayland. For Wayland, the KMS path is retained.

### Capture Pipeline (Linux — KMS/DRM, for Wayland) [IMPLEMENTED]

```
KMS/DRM framebuffer (GPU VRAM)
  → DMA-BUF file descriptor (via zerocast-kms helper, CAP_SYS_ADMIN)  ← DONE
    → EGL image (eglCreateImage with EGL_LINUX_DMA_BUF_EXT)
      → GL texture (glEGLImageTargetTexture2DOES)
        → CUDA resource (cuGraphicsGLRegisterImage)
          → NVENC AV1 hardware encode
            → encoded bitstream → libdatachannel → WebRTC
```

The KMS path goes through the `zerocast-kms` privileged helper. Everything from DRM plane enumeration through DMA-BUF fd export is implemented and tested. The EGL import → GL texture → CUDA → NVENC chain is not yet wired up.

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

### Signaling & Infrastructure: Cloudflare Workers [IMPLEMENTED — full signaling + viewer]

All server-side infrastructure runs on Cloudflare Workers. Single deployment, no servers to manage. Deployed at `zerocast.bodar.workers.dev`.

#### Architecture

```
zerocast.bodar.workers.dev (Cloudflare Worker)
│
├── GET /                        → viewer app (full WebRTC JS)              ← DONE
├── GET /?room=<id>              → viewer app with room auto-connect        ← DONE
├── GET /room/:id/ws?role=…      → WebSocket upgrade → Durable Object      ← DONE
└── (rooms auto-create on first WebSocket connection)
```

**Current state:** Worker routes `/room/{roomId}/ws` to a Durable Object. The DO accepts WebSocket upgrades with role tags (`?role=sharer|viewer`), broadcasts `peer-joined` notifications on new connections, relays all signaling messages (SDP offer/answer, ICE candidates) between peers, and notifies peers on disconnect. The viewer at `/` is a complete WebRTC client — creates RTCPeerConnection, handles SDP answer generation, ICE candidate exchange, and displays the remote AV1 stream in a `<video>` element.

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

- **STUN:** `stun.cloudflare.com:3478` (free, unlimited) — discovers public IP/port. Works for ~85% of home NATs. Most remote pairing sessions between devs on residential connections will use this path.
- **TURN:** Cloudflare TURN relay (fallback for symmetric NATs, CGNAT, strict corporate firewalls). $0.05/GB after 1 TB/month free. Standard TURN protocol — works with any WebRTC library including libdatachannel. This is the fallback for devs behind restrictive network setups.

ICE tries paths in priority order: direct P2P → STUN-assisted P2P → TURN relay. Best working path wins. For two devs in different cities on residential internet, STUN-assisted P2P is the typical outcome.

#### Cost

| Component | Cost |
|---|---|
| Worker requests | Free tier: 100K/day. Paid: $0.50/million |
| Durable Objects | Free while hibernated. ~$0.00 for signaling |
| TURN relay | 1 TB/month free, then $0.05/GB |
| STUN | Free, unlimited |

For pair programming usage, this is effectively free.

### Viewer: Browser Only [IMPLEMENTED]

No native app install on the viewer side. Your pair sends you a URL, you open it, their screen appears. Browser hardware-decodes AV1 via WebRTC, renders it. Keyboard/mouse events sent back over WebRTC data channel for remote control (future).

Massive UX advantage over Tuple/Pop which require native installs on both sides. Critical for remote pair programming where you want zero friction for the person joining.

**Current state:** Full WebRTC viewer served from the Worker. RTCPeerConnection with STUN, `ontrack` → `<video>` element binding, SDP answer generation, ICE candidate relay. Status overlay transitions: Connecting → Waiting for sharer → Negotiating → (hidden when video plays) → Disconnected. Tested end-to-end: 3840x1600 AV1 stream from native sharer to Chromium viewer.

#### PWA — Near-Borderless Viewer Window (Future)

The viewer can be made installable as a Progressive Web App, giving viewers a clean, near-borderless window that auto-sizes to the shared screen's aspect ratio. Much closer to a native screen sharing app than a browser tab.

**What PWA standalone mode provides:**
- `manifest.json` with `"display": "standalone"` — own window, no URL bar, no tabs
- `"display_override": ["window-controls-overlay"]` — just the OS close/min/max as a tiny overlay, nearly frameless
- macOS gets a razor-thin title bar, Linux/GNOME similar

**Auto-sizing to stream aspect ratio:**
- Once `ontrack` fires and `videoWidth`/`videoHeight` are known, call `window.resizeTo()` to match the aspect ratio
- `resizeTo()` is blocked in regular browser tabs but allowed in standalone PWA windows
- Flow: video arrives → read dimensions → resize window to match → feels like a native viewer

**What's needed:**
- `manifest.json` served from the Worker with correct MIME type, icon, `start_url: "/?room="`
- Trivial service worker (Chrome requires one for PWA installability — can be a no-op)
- `resizeTo()` call in the viewer JS on first frame

**Limitations:**
- Can't truly remove the OS window frame — that's outside browser control. But standalone + window-controls-overlay gets very close
- `resizeTo()` behaviour varies by OS — works best on macOS/Windows, Linux tiling WMs may override
- Install prompt UX varies by browser (Chrome shows install icon in address bar, Safari has "Add to Dock")

This is a small addition — manifest, a no-op service worker, and a resize call — but meaningfully improves the viewer experience for repeated use.

### Region Sharing (Future)

Support sharing a sub-region of the screen rather than the full display. Useful for ultrawide/multi-monitor setups where you want to keep parts of your workspace private.

**Syntax:** `zerocast share [WxH+X+Y]` — standard X11 geometry format (used by xrandr, ffmpeg, wf-recorder).

**Where it happens in the pipeline:** At the GL/CUDA stage, not in KMS capture. The `zerocast-kms` helper always captures the full framebuffer (DRM only gives you the whole thing). The main process crops to the requested geometry when setting up the NVENC input — just adjusted texture coordinates, essentially free on the GPU.

This means region sharing doesn't affect the KMS helper design at all.

### Remote Input (Sharer Receives Viewer's Input)

- Viewer captures keyboard/mouse in browser
- Sent over WebRTC data channel (low latency, encrypted)
- Sharer's Zig binary injects via **uinput** (same pattern as capsper)
- Works on both X11 and Wayland

### Privilege Separation [IMPLEMENTED]

Two Zig binaries: `zerocast` (unprivileged) and `zerocast-kms` (CAP_SYS_ADMIN file capability).

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

#### Architecture: `zerocast-kms` helper [IMPLEMENTED — 312 lines]

The helper does exactly one thing: export DMA-BUF fds from the compositor's framebuffers.

```
zerocast (unprivileged, video group)
  │
  ├── socketpair(AF_UNIX, SOCK_STREAM)
  ├── fork() + exec("zerocast-kms")
  │
  │   zerocast-kms (CAP_SYS_ADMIN via file capability)
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
sudo install -m 755 zerocast /usr/local/bin/zerocast
sudo install -m 755 zerocast-kms /usr/local/bin/zerocast-kms
sudo setcap cap_sys_admin+ep /usr/local/bin/zerocast-kms
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
./run.ts build        # zig build ReleaseSafe (both zerocast + zerocast-kms)
./run.ts clean        # rm -rf dist/bin .zig-cache
./run.ts test         # zig build test (unit + property tests)
./run.ts lint         # zwanzig static analysis + shellcheck
./run.ts setup        # build + install to /usr/local/bin + setcap CAP_SYS_ADMIN
./run.ts dist         # validate (no AVX-512, no absolute RUNPATH) + package tarball
./run.ts ci           # lint + test + build + dist + gh release create
./run.ts integration  # GPU integration test (captures 3s IVF, validates with ffprobe)
./run.ts rebuild-libs # rebuild libdatachannel static libs via cmake
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
git clone <repo> && cd zerocast
./run.ts              # bootstrap installs tools, builds, tests — one command
./run.ts setup        # install binaries + setcap on zerocast-kms
```

## Testing Strategy

Testing is paramount. Three tiers, each testable without the next tier's dependencies.

### Tier 1: Zig Unit Tests [IMPLEMENTED]

Inline `test` blocks in source files. Pure functions, no hardware dependencies. Fast, runs everywhere.

Implemented:
- **IPC wire protocol** (`protocol.zig`, 5 tests) — struct size stability, error message roundtrip + truncation at 127 bytes, fd collection with deduplication
- **SCM_RIGHTS transport** (`ipc.zig`, 3 tests) — real socketpair + `/dev/null` fd roundtrips, Request serialization, Response with error

Future modules (as they're built):
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
- **Input event roundtrip** — encode then decode any keyboard/mouse event → identical event
- **Bitrate adaptation monotonicity** — higher packet loss → lower or equal target bitrate

```bash
zig build prop-test
```

### Tier 3: Integration Tests [PARTIALLY IMPLEMENTED]

Exercise real hardware and network paths. Require GPU, run in CI with hardware or skipped gracefully.

Implemented:
- **IVF capture test** (`./run.ts integration`) — captures 3 seconds via NvFBC → CUDA → NVENC → IVF, validates with ffprobe (codec=av1, frame count ≥ 10)
- **Dist validation** (`./run.ts dist`) — verifies no AVX-512 instructions (portable to x86_64_v3), no absolute RUNPATH in binary

Future:
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
| **CUDA** | Register GL textures as CUDA resources for NVENC | **In use** |
| **NVENC** | NVIDIA's dedicated hardware video encoder ASIC | **In use** |
| **VAAPI** | Video Acceleration API — AMD/Intel hardware encode (future) | Later |
| **evdev / uinput** | Kernel input subsystem — capture and inject keyboard/mouse events | Later |
| **libdatachannel** | WebRTC transport (ICE, DTLS, SRTP, data channels) | **In use** |

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
| `kms/server/kms_server.c` | Privileged setuid helper for DRM ioctls | Inspired our `zerocast-kms` design |

Architecture: plugin-based via C function pointers. Capture and encoder backends implement a common interface. Detect GPU at startup, pick best backend.

**Lessons learned from gpu-screen-recorder:** Their NvFBC path is the simplest capture backend (~200 lines vs ~1200 for KMS). We adopted the same approach — NvFBC for X11, KMS retained for Wayland. Their NVENC encoder was a useful reference for our implementation.

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
