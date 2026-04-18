---
created: "2026-04-18"
last_edited: "2026-04-18"
complexity: medium
---

# Cavekit: Capture Pipeline

## Scope
Everything from capturing an application's rendered surface through GPU-side hand-off to the encoder, the encoder itself, and the emission of an encoded AV1 bitstream. Also covers optional session recording of the encoded bitstream to disk. Does not cover transport of the encoded bitstream over the network; that is the transport domain.

## Requirements

### R1: Embedded compositor runs apps headlessly
**Description:** The system hosts each shared application inside an embedded compositor that requires no physical display, no display server login session, and no DRM master. The compositor presents a rendered surface to the capture stage.
**Acceptance Criteria:**
- [ ] Starting a share succeeds on a Linux host without a running desktop session attached to the invoking user.
- [ ] A shared application receives a valid surface on which to render and reports a live connection to its host display.
- [ ] The compositor tears down cleanly when the share ends, leaving no orphan child processes.
- [ ] [GAP] On macOS the same guarantees hold via the platform's virtual-display and screen-capture facilities.

### R2: GPU-resident frame source
**Description:** The capture stage produces frames that live in GPU memory and hands them to the encoder without a CPU-side color-space conversion pass.
**Acceptance Criteria:**
- [ ] Captured frames are referenced through a GPU-shareable handle appropriate to the host platform.
- [ ] No frame data is copied through the CPU during the capture-to-encode hand-off.
- [ ] A frame handle is owned by exactly one stage at a time; ownership transfer is explicit.

### R3: Swappable encoder backend interface
**Description:** The encoder is an interface with multiple implementations selected at runtime. Logic that submits frames does not depend on which backend is active.
**Acceptance Criteria:**
- [ ] The encoder interface exposes at minimum: configure with dimensions and codec parameters, submit a GPU frame, request a forced keyframe, and tear down.
- [ ] [GAP] At least one hardware backend and one software backend implement the interface and pass the same contract tests. (A software AV1 backend is not yet implemented.)
- [ ] Submitting a frame does not require the caller to know which backend is active.

### R4: Encoder backend selection
**Description:** At startup the system probes GPU capabilities and selects an encoder backend. Hardware AV1 is preferred when available; otherwise software AV1 is used.
**Acceptance Criteria:**
- [ ] On hosts whose GPU advertises AV1 encode, a hardware AV1 backend is selected.
- [ ] [GAP] On hosts without hardware AV1 encode, a software AV1 backend is selected. (No software AV1 backend exists today; this criterion cannot pass until R3's software backend lands.)
- [ ] The selection decision, including the probe outcomes that drove it, is logged at startup.
- [ ] Selection does not depend on user configuration; it is driven only by probe results.

### R5: AV1 is the only codec
**Description:** The pipeline emits AV1 bitstreams. No other codec is produced under any configuration.
**Acceptance Criteria:**
- [ ] Every encoder backend emits AV1.
- [ ] Removing all non-AV1 codec constants from the codebase does not reduce functionality.
- [ ] Viewer negotiation advertises AV1 as the sole video codec.

### R6: Explicit color metadata
**Description:** The emitted bitstream carries explicit signalling of color primaries, transfer characteristics, and matrix coefficients, with a defined range. Viewers interpret frames consistently without guesswork.
**Acceptance Criteria:**
- [ ] Each emitted bitstream declares BT.709 primaries, BT.709 transfer, BT.709 matrix, and limited range.
- [ ] An external inspection tool run over a recorded bitstream reports the same values the pipeline declared.

### R7: Constant-quality rate control
**Description:** Rate control operates on a constant quantization parameter. The user may configure the target quantizer; there is no variable-bitrate mode.
**Acceptance Criteria:**
- [ ] The encoder accepts a single quantizer value at configuration time.
- [ ] A documented flag sets the quantizer; unspecified falls back to a documented default.
- [ ] Searching the code for VBR rate-control constants yields no references on any logic path.

### R8: P-only GOP with keyframe headers
**Description:** The bitstream uses keyframes and forward-predicted frames only; no bidirectional frames. Every keyframe carries the sequence headers needed by a late-joining decoder.
**Acceptance Criteria:**
- [ ] No B-frames appear in any emitted bitstream.
- [ ] Every keyframe in the emitted bitstream is self-contained enough that a decoder joining at that keyframe produces correct output without earlier data.

### R9: Keyframe on demand
**Description:** The pipeline issues a keyframe when a downstream consumer requests one or when the pipeline itself reconfigures.
**Acceptance Criteria:**
- [ ] A transport-level picture-loss indication causes the next emitted frame to be a keyframe.
- [ ] A pipeline reconfigure (resize, backend restart) causes the next emitted frame to be a keyframe.
- [ ] A keyframe request received while a frame is in flight takes effect on the following frame.

### R10: Viewer-initiated resize
**Description:** A viewer request to resize the shared surface reconfigures the pipeline to the new dimensions and emits a keyframe on the next frame. Rapid resize bursts are coalesced.
**Acceptance Criteria:**
- [ ] A single resize request results in exactly one reconfiguration with the requested dimensions.
- [ ] A burst of resize requests inside the coalescing window produces exactly one reconfiguration using the last requested dimensions.
- [ ] The first frame after reconfiguration is a keyframe.
- [ ] Coalescing is driven by the injected clock primitive and is deterministic under test.
**Dependencies:** cavekit-cli-daemon.md (Clock, Debounce)

### R11: XDG constraints applied to surface sizing
**Description:** When the shared application imposes minimum, maximum, or aspect-ratio constraints on its surface, the pipeline honors those constraints when reconfiguring.
**Acceptance Criteria:**
- [ ] A surface with declared minimum dimensions is never reconfigured smaller than those dimensions.
- [ ] A surface with declared maximum dimensions is never reconfigured larger than those dimensions.
- [ ] A surface with a fixed aspect ratio is reconfigured only to dimensions that respect that ratio.

### R12: Optional session recording
**Description:** When a recording output directory is configured, the pipeline writes the encoded bitstream to disk in a container appropriate for AV1 alongside streaming. Recording is per-share and does not block encoding.
**Acceptance Criteria:**
- [ ] With no recording directory configured, no files are written and no extra work is done.
- [ ] With a recording directory configured, each share writes a distinct file whose name includes the share identifier.
- [ ] The recorded file is playable by a standard media inspector without further processing.
- [ ] Recording I/O failure does not crash the share; it logs and continues without recording.

### R13: Round-robin disk management
**Description:** Recorded files are managed so that disk usage does not grow unbounded. Old recordings are reclaimed.
**Acceptance Criteria:**
- [ ] When the recording directory exceeds its configured capacity, the oldest recorded file is deleted before a new recording begins.
- [ ] [GAP] A documented mechanism exposes the current retention policy.

### R14: Frame throttling without viewers
**Description:** The encoder does not produce frames when no viewer is attached. On the first viewer attach, a keyframe is produced immediately.
**Acceptance Criteria:**
- [ ] With no viewers attached, the encoder's per-frame work is not performed.
- [ ] On first viewer attach, the encoder produces a keyframe without waiting for the next scheduled frame.
- [ ] When the last viewer detaches, frame production stops within one frame interval.

### R15: Pipeline-timings telemetry
**Description:** The pipeline measures capture, encode, and send stages per frame and emits periodic aggregate summaries for latency analysis.
**Acceptance Criteria:**
- [ ] Each emitted frame carries timestamps for capture completion and encode completion.
- [ ] The pipeline emits an aggregate summary of the last interval's stage latencies at least every five seconds while producing frames.
- [ ] Summaries include at minimum: count, mean, and maximum for each of capture, encode, and transport submit.

## Out of Scope
- Transport of encoded bitstreams across the network.
- Audio capture and encoding.
- Browser-side decoding.
- HEVC, H.264, VP9, and any non-AV1 codecs.
- VBR rate control.
- The removed privileged KMS capture helper.

## Cross-References
- See also: cavekit-cli-daemon.md (Clock, Debounce, environment configuration)
- See also: cavekit-webrtc-transport.md (consumer of encoded frames; source of keyframe and resize requests)
- See also: cavekit-testing.md (encoder backend contract tests, frame sink doubles)

## Source Traceability
- `src/linux/wayland/compositor.zig` — R1
- `src/linux/wayland/app_share.zig` — R1, R10, R11
- `src/linux/wayland/nvenc_backend.zig`, `src/linux/wayland/nvenc.zig` — R3, R4, R5, R6, R7, R8, R9
- `src/linux/wayland/cuda.zig` — R2
- `src/linux/vaapi/vaapi.zig`, `src/linux/vaapi/encoder_backend.zig` — R3, R4
- `src/shared/encoder.zig` — R3, R9, R14, R15
- `src/shared/codec.zig`, `src/shared/ivf.zig` — R5, R12
- `src/shared/session_recorder.zig` — R12, R13
- `src/macos/app_share.zig`, `src/macos/encoder_backend.zig`, `src/macos/screen_capture.m`, `src/macos/videotoolbox.m` — R1, R3, R4, R5 (GAP: macOS backend currently emits HEVC, needs AV1 migration via SVT-AV1 software path)
- `src/linux/gpu_detect.zig` — R4

## Changelog
- 2026-04-18: initial draft (brownfield --from-code). AV1-only, HEVC references removed per direction of travel.
- 2026-04-18: reviewer pass — added [GAP] markers on R3 and R4 for SVT-AV1 software backend (not yet built); macOS R5 added to Source Traceability GAP list.
