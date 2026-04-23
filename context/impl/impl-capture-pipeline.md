---
created: "2026-04-18"
last_edited: "2026-04-23"
---
# Implementation Tracking: capture-pipeline

Build site: context/plans/build-site.md

| Task | Status | Notes |
|------|--------|-------|
| T-001 | DONE | SVT-AV1 v3.1.2 submodule at packages/svt-av1, rebuild-libs wiring, COMPILE_C_ONLY (no NASM). Lib at packages/svt-av1/Bin/Release/libSvtAv1Enc.a (~21 MB). Commit adad2ed |
| T-005 | DONE | Inventory worklist at context/impl/svt-av1-non-av1-inventory.md. Commit 91ad99b |
| T-006 | DONE | SvtBackend adapter at packages/zerocast/src/shared/svt_backend.zig — wraps SVT-AV1 C API as EncodeBackend vtable. Smoke test in-file. Commit 5011be4 |
| T-009 | DONE | HEVC + VA-API purged. Deleted packages/zerocast/src/linux/vaapi/ tree (4 files, ~1600 lines). Codec enum AV1-only. NVENC detectCodec fails if AV1 unavailable. Commit 7ff7d01 |
| T-010 | DONE | CPU-side frame ingestion wired. New shared/yuv.zig (BT.709 limited-range RGBA/BGRA → I420) and linux/wayland/frame_download.zig (GL FBO → RGBA → I420). AppShare.BackendState gains .svt variant pairing SvtBackend + FrameDownloader. Encoder.processFrame semantics unchanged. Commit c3-era T-010 feat |
| T-011 | DONE | CQP rate control — rate_control_mode=CQP_OR_CRF, enable_adaptive_quantization=0, qp passthrough with range warn. Commit df9bedf |
| T-012 | DONE | P-only GOP — intra_period_length=-1, intra_refresh_type=KF_REFRESH, hierarchical_levels=2, pred_structure=LOW_DELAY_B. External inspection verified in T-017. Commit df9bedf |
| T-013 | DONE | BT.709 signalling — color_primaries=BT_709, transfer_characteristics=BT_709, matrix_coefficients=BT_709, color_range=STUDIO_RANGE. Commit df9bedf |
| T-014 | DONE | Force-keyframe semantics — encodeFn sets pic_type=EB_AV1_KEY_PICTURE when force_key true; contract-test case exercises this in T-016. Commit df9bedf |
| T-015 | DONE | SvtBackend → IvfWriter end-to-end test in encoder_contract_test.zig. Drains adapter into tmpdir IVF, asserts DKIF magic + AV01 FourCC + declared dimensions + frame count. encoder.IvfWriter re-exported for test access. R12 AC1..AC4 covered. |
| T-016 | DONE | Real SvtBackend drives runContract alongside FakeBackend in encoder_contract_test.zig. Divergence resolved by the new encodeUntilOutput drain helper (handles backends that buffer inputs). SvtContractAdapter + mid-grey YUV feeder satisfies every contract case. Also cleaned up SvtBackend.deinit to send EOS + drain before handle teardown (no more "deinit called without sending EOS!" noise). |
| T-017 | DONE | ffprobe-driven verification test in encoder_contract_test.zig: drains ~16 SvtBackend frames into IVF, shells out to ffprobe, asserts JSON carries color_primaries=bt709, color_transfer=bt709, color_space=bt709, color_range=tv, and no pict_type=B. Skips cleanly when ffprobe not on PATH. |
| T-018 | DONE | gpu_detect gains selectBackend + selectRenderDevice. AppShare.initInPlace calls detectGpus once, logs the outcome, picks backend + render node from the probe. No user override — daemon logs a deprecation warning when a non-auto `gpu` field arrives. Unit tests cover every selectBackend branch. |
| T-019 | DONE | Two regression tests in session.zig lock the Codec enum to AV1 and lock the startScreen track-init mapping to RTC_CODEC_AV1. Also wired the shared codec/input_protocol/viewer_state imports into session_tests so `@typeInfo(Codec)` resolves. |
| T-021 | DONE | macOS app_share rewired from VideoToolbox HEVC to SvtBackend + new macos/frame_download.zig (BGRA → I420 via shared yuv helper). sc_pixel_buffer_lock/unlock added to screen_capture.m. Deleted encoder_backend.zig + videotoolbox.{h,m}. Linux build + tests still green; macOS runtime verification pending native hardware. |
