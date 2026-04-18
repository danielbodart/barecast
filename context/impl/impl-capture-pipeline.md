---
created: "2026-04-18"
last_edited: "2026-04-18"
---
# Implementation Tracking: capture-pipeline

Build site: context/plans/build-site.md

| Task | Status | Notes |
|------|--------|-------|
| T-001 | DONE | SVT-AV1 v3.1.2 submodule at packages/svt-av1, rebuild-libs wiring, COMPILE_C_ONLY (no NASM). Lib at packages/svt-av1/Bin/Release/libSvtAv1Enc.a (~21 MB). Commit adad2ed |
| T-005 | DONE | Inventory worklist at context/impl/svt-av1-non-av1-inventory.md. Commit 91ad99b |
| T-006 | DONE | SvtBackend adapter at packages/zerocast/src/shared/svt_backend.zig — wraps SVT-AV1 C API as EncodeBackend vtable. Smoke test in-file. Commit 5011be4 |
| T-009 | DONE | HEVC + VA-API purged. Deleted packages/zerocast/src/linux/vaapi/ tree (4 files, ~1600 lines). Codec enum AV1-only. NVENC detectCodec fails if AV1 unavailable. Commit 7ff7d01 |
| T-011 | DONE | CQP rate control — rate_control_mode=CQP_OR_CRF, enable_adaptive_quantization=0, qp passthrough with range warn. Commit df9bedf |
| T-012 | DONE | P-only GOP — intra_period_length=-1 (no auto intra), intra_refresh_type=KF_REFRESH, hierarchical_levels=2 (SVT v3.x minimum), pred_structure=LOW_DELAY_B. External inspection verification belongs to T-017. Commit df9bedf |
| T-013 | DONE | BT.709 signalling — color_primaries=BT_709, transfer_characteristics=BT_709, matrix_coefficients=BT_709, color_range=STUDIO_RANGE. Commit df9bedf |
| T-014 | DONE | Force-keyframe semantics already honored by T-006's encodeFn (pic_type=EB_AV1_KEY_PICTURE when force_key true). R9 cases (PLI, reconfigure, in-flight) all satisfied. Commit df9bedf |
| T-010 | PENDING | Compositor YUV download — GL FBO → RGB → I420 → svt_backend.setPendingYuv. Not yet wired into AppShare. |
| T-015 | PENDING | Connect SvtBackend output to session recorder IVF path. Blocked on T-011/12/13 (DONE). |
| T-016 | PENDING | Run contract suite against BOTH NVENC and SvtBackend. Needs synthetic YUV test inputs; FakeBackend currently stands in. Blocked on T-007/11/12/13/14 (DONE). |
| T-017 | PENDING | ffprobe verification of BT.709 + no-B-frames. Blocked on T-015. |
| T-018 | PENDING | Backend selector wiring — gpu_detect → NVENC vs SvtBackend. AppShare's `.intel`/`.auto` currently errors; this task routes those to SvtBackend. Blocked on T-016. |
| T-019 | PENDING | Viewer negotiation advertises AV1 only — regression assert. Blocked on T-018. |
| T-021 | PENDING | macOS VideoToolbox → SVT-AV1 migration. Big — first-class port not path substitution. Blocked on T-018. |
