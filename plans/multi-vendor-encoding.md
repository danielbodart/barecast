# Multi-Vendor Hardware Encoding

Expand hardware support beyond NVENC AV1-only. Always prefer AV1, fall back to HEVC when AV1 hardware isn't available. macOS/Apple Silicon is handled separately via native AVFoundation — out of scope here.

## Background

Current state: NVENC AV1 only (RTX 40/50 series). This excludes the vast majority of Linux machines.

### Codec reach by vendor

| Vendor | HEVC encode since | AV1 encode since |
|--------|------------------|-----------------|
| NVIDIA | GTX 950 / Maxwell Gen 2 (2014) | RTX 4060 / Ada (2022) |
| Intel iGPU | Skylake / 6th gen (2015) | Meteor Lake / 14th gen (2023) |
| Intel Arc | All (A310+) | All (A310+) |
| AMD | RX 400 / Polaris (2016) | RX 7000 / RDNA3 (2022) |

### Codec selection logic

Detect available hardware at startup. Prefer AV1, fall back to HEVC:

1. If AV1 encode is available → use AV1
2. Else if HEVC encode is available → use HEVC
3. Else → error: no supported encoder

This applies per-vendor — an RTX 3080 gets HEVC via NVENC, an RTX 4060 gets AV1 via NVENC, an Intel Skylake laptop gets HEVC via VA-API, etc.

### Browser decode support

Both AV1 and HEVC decode in all modern browsers:
- AV1: Chrome 70+, Firefox 67+, Safari 17+
- HEVC: Chrome 107+ (hardware only), Safari 11+, Firefox 120+ (behind flag, hardware)

The viewer needs to know which codec the stream uses so it can configure the correct WebRTC decoder. Signal codec choice during SDP exchange.

---

## Stage 1: NVENC HEVC fallback

**Goal**: Support every NVENC GPU from GTX 950 onward (Maxwell Gen 2+).

Same NVENC API, same capture pipeline. The only changes are encoder configuration and signaling.

### What changes

- **Encoder init**: Query NVENC for AV1 support. If unavailable, configure HEVC instead. Different codec GUID, profile, level, and rate control params.
- **Packetizer**: AV1 uses OBU framing; HEVC uses NAL units with Annex B start codes. libdatachannel has separate packetizers for each — use `rtcSetH265Packetizer` for HEVC vs `rtcSetAV1Packetizer` for AV1.
- **Signaling**: Include codec in the SDP offer so the viewer knows what to expect. The worker room needs to relay this.
- **Viewer**: Conditionally set `codec: "av01..."` or `codec: "hev1..."` in the RTCRtpTransceiver codec preferences.
- **IVF container** (recording): IVF is AV1/VP8/VP9 only. For HEVC recordings, either use raw Annex B `.265` files or switch to a different container. Low priority — recording is optional.

### What doesn't change

- Capture pipeline (KMS/DMA-BUF/EGL/CUDA) — identical
- WebRTC transport (libdatachannel) — same API, different packetizer call
- Rate control strategy — same adaptive VBR formula

### Key files

- `src/encoder.zig` — codec selection, NVENC config branching
- `src/session.zig` — packetizer setup, SDP codec signaling
- `worker/src/room.ts` — relay codec info
- `worker/src/viewer.ts` — codec preference in transceiver

---

## Stage 2: Intel VA-API (HEVC + AV1)

**Goal**: Support Intel iGPUs (Skylake+ for HEVC, Meteor Lake+ for AV1) and Intel Arc discrete GPUs.

This is the big architectural change — a second encode backend alongside NVENC.

### What changes

- **New encode backend**: VA-API encoder using `libva`. Implements the same encode interface as the NVENC path but talks to VA-API instead.
- **Capture pipeline**: Can't use NvFBC on Intel. Need an alternative screen capture:
  - KMS/DRM DMA-BUF export works on Intel (same kernel API, different driver: `i915` or `xe`)
  - No CUDA — use EGL/DMA-BUF directly into VA-API surfaces, or map to system memory
  - This is the hardest part of Stage 2
- **Backend selection**: Detect GPU vendor at startup. NVIDIA → NVENC path. Intel → VA-API path.
- **VA-API codec selection**: Same AV1-preferred-HEVC-fallback logic, but querying VA-API profiles instead of NVENC GUIDs.

### Key considerations

- `libva` is the C API; link dynamically (it's a system library, not something we'd vendor)
- Intel iGPU + discrete NVIDIA is a common laptop config — need to pick the right device. User might want to encode on the dGPU but the iGPU is the only option if it's an Intel-only machine.
- VA-API rate control: CQP and VBR are widely supported. CBR support varies. Stick with VBR.
- Intel's VA-API HEVC encoder quality is decent but not NVENC-tier. AV1 on Arc is competitive.

### Key new files

- `src/vaapi_encoder.zig` — VA-API encode backend
- `src/gpu_detect.zig` — enumerate GPUs, pick backend
- Modifications to capture pipeline for non-NVIDIA GPU capture

---

## Stage 3: AMD VA-API (HEVC + AV1)

**Goal**: Support AMD GPUs (RX 400+ for HEVC, RX 7000+ for AV1).

### What changes

Mostly free if Stage 2 is done well — AMD uses the same VA-API interface via Mesa's `radeonsi` driver.

- **Capture pipeline**: Same DRM/KMS DMA-BUF approach as Intel. AMD's `amdgpu` kernel driver supports DMA-BUF export.
- **VA-API encode**: Same `libva` API. AMD-specific quirks:
  - Historical Mesa alignment bug (1920x1080 → 1088 lines) — fixed in Mesa 23+ / libva 1.21+. May need minimum version check.
  - Some RDNA3 hybrid graphics configs don't expose encoders — GPU selection logic needs to be robust.
- **Backend selection**: Extend `gpu_detect.zig` to handle AMD. Intel and AMD both route through the VA-API backend; only the underlying driver differs.

### What doesn't change from Stage 2

- VA-API encoder code — same API, same code path
- Codec selection logic — same AV1/HEVC fallback
- Signaling and viewer — already codec-agnostic from Stage 1

### AMD-specific testing

- Test on Polaris (RX 580) for oldest HEVC support
- Test on RDNA3 (RX 7600/7800 XT) for AV1
- Verify Mesa version requirements
