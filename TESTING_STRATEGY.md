# Testing Strategy

## Context

The app share pipeline (compositor → encode → WebRTC → browser) has minimal test coverage today. The existing compositor-test validates resize events but not frame content. The integration test checks frame count but not quality. Encoder orchestration logic (damage tracking, PLI, keyframe forcing) has no tests at all.

Planned encoder changes unlock a much better testing story:
- Drop HEVC, go AV1-only
- Add SVT-AV1 as a software encoder fallback (always available, no GPU required)
- NVENC remains the primary encoder when an NVIDIA GPU is present

SVT-AV1 means every test layer can run without a GPU, including CI.

## Test Pyramid

| Layer | What | Runs on | Speed |
|-------|------|---------|-------|
| Unit | Encoder orchestration + SVT-AV1 | Anywhere | ~1s |
| Component | Compositor + synthetic client + SVT-AV1 + buffer sink | Any Linux (software GL) | ~5s |
| Quality | Decode + PSNR/SSIM comparison | Any Linux + ffmpeg | ~5s |
| Integration | Full pipeline minus browser | Any Linux | ~10s |
| E2E | Playwright + real browser | Any Linux + Playwright | ~30s |

Every layer runs without a GPU. GPU-specific tests supplement the pyramid by validating NVENC parity with SVT-AV1.

## 1. SVT-AV1 as the Test Encoder

Instead of a mock EncodeBackend that returns canned bytes, use SVT-AV1 — a real encoder producing real AV1 bitstream, just in software. The `EncodeBackend` vtable already exists, so SVT-AV1 slots in as a third implementation alongside NVENC and VA-API.

### What it tests

- Encoder orchestration: frame skipping (damage tracking), PLI aggregation, keyframe forcing, PTS/NTP calculation, stats accumulation, idle frame suppression
- Real encoding contract: bitstream validity, keyframe generation, resize re-init, drain-on-reconfigure
- Everything a mock would test, plus real codec behavior

### Why real beats mock

A mock EncodeBackend can't catch bugs in how the Encoder orchestrator interacts with a real encoder. For example: does it handle "encoder needs to be drained and re-initialized on resize" correctly? SVT-AV1 exercises the real contract.

### Implementation

- Static library, built with zig cc (same approach as libdatachannel)
- New `SvtBackend` struct implementing `EncodeBackend` vtable
- Preset 12 (fastest) for tests — single 1080p frame ~10ms
- Becomes the default backend for all non-GPU tests

## 2. Synthetic Wayland Client

Instead of launching gnome-calculator (which renders whatever GTK decides), write a minimal Wayland client in Zig that connects to the embedded compositor and renders known test patterns: solid red, solid green, checkerboard, gradient ramp.

### What it tests

- Compositor frame capture and DMA-BUF extraction
- GL RBO readback correctness
- Surface sequence tracking (damage detection)
- Resize handling (client commits new buffer at different size)
- Pixel-level correctness of the capture path

### Implementation

- ~100-line Zig program using `wl_shm` to submit known pixel buffers
- Connects to `WAYLAND_DISPLAY` set by AppShare, creates `xdg_toplevel`
- Launched by AppShare like any other app
- Test reads back CapturedFrame data and compares against known pattern

### Software rendering

The compositor needs a render node, but Mesa's software renderers work with wlroots headless (`WLR_RENDERER=pixman` or software GL via llvmpipe). This means the synthetic client tests run without a GPU.

## 3. Decode-and-Compare Quality Gate

Encode real frames (via SVT-AV1 or NVENC), decode the bitstream, and measure quality against the source. The "did encoding actually work correctly" test.

### What it tests

- Bitstream validity and codec compliance
- Color space correctness (BT.709 primaries, transfer, matrix)
- Resolution correctness after resize
- Visual quality floor (PSNR > threshold for given QP)
- Encoder parameter regressions

### Implementation

- Synthetic client renders known test card → compositor captures → encode → IVF file
- Decode: `ffmpeg -i output.ivf -f rawvideo -pix_fmt rgb24 pipe:1`
- Quality: compute PSNR against source (should be >35dB at QP=20)
- Metadata: `ffprobe -show_streams` → assert `color_primaries=bt709`, `color_transfer=bt709`, `color_space=bt709`

### Cross-encoder comparison

When both SVT-AV1 and NVENC are available, compare their output quality. Significant divergence means one encoder's configuration is wrong.

### Historical bugs this catches

The March 2026 AV1 color metadata issue (washed-out colors on wide-gamut displays) would have been caught by checking `color_primaries=1` in ffprobe output.

## 4. In-Memory Frame Buffer Sink

Add a `FrameSink.buffer` variant that captures encoded frames in memory instead of sending them over WebRTC or writing to disk. Tests the full capture → encode → sink path without network, browser, or GPU.

### What it tests

- Full pipeline integration: compositor → encoder → frame distribution
- Frame count, keyframe presence, PTS monotonicity
- Bitstream parseability
- Resize pipeline rebuild (drain old encoder, init new, first frame is keyframe)

### Implementation

Low-cost change — add a union variant to the existing `FrameSink`:

```zig
pub const FrameSink = union(enum) {
    ivf: IvfWriter,
    session: *BroadcastSession,
    buffer: *FrameBuffer,    // in-memory capture for tests
    none,
};

pub const FrameBuffer = struct {
    frames: [64]StoredFrame = undefined,
    count: u32 = 0,
};
```

A test would:
1. Init compositor + synthetic client + SVT-AV1 backend + `FrameSink.buffer`
2. Run main loop for N iterations
3. Read frames from buffer
4. Validate: count, keyframes present, PTS monotonic, bitstream parseable
5. Optionally decode and pixel-compare (combines with quality gate)

No new abstraction layer needed. No refactoring of session.zig.

## 5. Playwright Visual Regression

Real compositor + real encoder + real WebRTC + real browser. The only test that validates what the user actually sees.

### What it tests

- Browser can decode the AV1 stream
- WebRTC negotiation and RTP packetization
- Video display and stats reporting
- Input injection round-trip (optional)

### Implementation

- Launch daemon + worker dev server
- Share synthetic client app
- Open viewer in Playwright headless browser
- Wait for video to stabilize (stats: FPS > 0, bitrate > 0)
- Screenshot → compare against golden image (perceptual diff via pixelmatch)
- Validate stats panel: codec name, resolution, FPS within expected range
- Optional: send mouse click via Playwright → verify input arrives at Wayland client

### Two modes

- **Software mode (CI):** SVT-AV1 encoding, software GL. Slower but runs on any Linux runner.
- **GPU mode (dev):** NVENC encoding, hardware GL. Fast, validates GPU-specific paths.

## Execution Plan

### Phase 1: Foundation

1. Implement SVT-AV1 `EncodeBackend` (needed for the encoder restructuring anyway)
2. Add `FrameSink.buffer` variant (trivial, enables in-memory testing)
3. Write encoder orchestration tests using SVT-AV1 + buffer sink

### Phase 2: Deterministic Input

4. Write the synthetic Wayland client (test pattern renderer)
5. Component tests: compositor + synthetic client + SVT-AV1 + buffer sink
6. Quality gate: decode IVF output, check PSNR and ffprobe metadata

### Phase 3: End-to-End

7. Playwright E2E test with SVT-AV1 software path
8. Golden image comparison for visual regression
9. GPU-specific test variant for NVENC parity checking
