---
created: "2026-04-18"
last_edited: "2026-04-18"
---
# Loop Log

Build site: context/plans/build-site.md
TIER_START_REF (tier 0): ee10c8db0f70feaa1f4620e8aefd808ea42331f4

## Pre-flight
- Coverage matrix: 33/33 COVERED, no GAPs
- Execution model: opus
- Caveman active (build): true

## Wave 1 — Tier 0 (2026-04-18)

Planned packets:
- A (T-001, worktree, bg): SVT-AV1 lib integration
- B (T-002 + T-003 + T-004, worktree, bg): test infra + clock audit
- C (T-005, worktree, bg): non-AV1 inventory

**Harness failure:** all 3 worktree agents' commits were garbage-collected
when their worktrees auto-cleaned. Zero agent commits persisted in the
object database. Work recovered inline on trunk.

Commits:
- 91ad99b — cavekit + build-site + inventory (T-005)
- adad2ed — SVT-AV1 submodule + FrameSink.buffer + contract skeleton +
  clock injection (T-001, T-002, T-003, T-004)

Status: T-001..T-005 all DONE. Build/test/lint green.

**Process fix going forward:** dispatch subagents without
`isolation: worktree` or run inline. The worktree + background
combination is incompatible with this harness's auto-clean.

## Interstitial — packages/ restructure (2026-04-18)

User requested restructure before continuing Tier 1 work. All submodules
and our-code moved under packages/ (matches wasiglk precedent). Commit
29d6e7a. Tests/build/lint green post-restructure.

## Wave 2 — Tier 1 (2026-04-18)

Executed inline on trunk.

Commits:
- 5011be4 — T-006 SvtBackend adapter + SVT-AV1 v3.x init_handle 2-arg fix
- 7ff7d01 — T-009 HEVC + VA-API purge (+57 / -1664, 35 Zig files left)
- 6399803 — T-007 contract suite expansion + T-008 property tests

Status: T-006, T-007, T-008, T-009 DONE. Build/test/lint green.

**T-009 scope note:** Original inventory underestimated HEVC surface.
Real delete touched codec.zig, session.zig, session_recorder.zig,
nvenc.zig, gpu_detect.zig, app_share.zig, build_linux.zig + whole
vaapi/ tree. `--gpu intel` and `--gpu auto` currently return
EncoderInitFailed pending T-018 wiring.

## Wave 3 — Tier 2 partial (2026-04-18)

Commit df9bedf — T-011/T-012/T-013/T-014 SvtBackend config refinement.
All small tweaks to svt_backend.zig init(): CQP, LOW_DELAY_B with
hierarchical=2, BT.709 color, force-keyframe (already satisfied).

SVT config log confirms: `pred struct: low delay / mini-gop size: 4 /
CQP 32`.

## Summary at checkpoint

13 / 21 build-site tasks DONE.

Remaining (blocked chain):
- T-010 (M) — Compositor YUV download → SvtBackend.setPendingYuv
- T-015 (S) — SW backend → IVF wiring  [blocked T-011/12/13 ✓]
- T-016 (M) — Run contract vs HW + SW  [blocked T-007/11/12/13/14 ✓]
- T-017 (S) — ffprobe external inspection  [blocked T-015]
- T-018 (M) — Backend selector wiring  [blocked T-016]
- T-019 (S) — Viewer negotiation regression  [blocked T-018]
- T-020 (M) — GPU-free integration lane  [blocked T-018]
- T-021 (L) — macOS SVT-AV1 migration  [blocked T-018]

**Next task:** T-010 or T-016 — both unblocked. T-016 is the payoff
moment for the entire SVT-AV1 push ("bunch of testing" the user
originally asked for — runContract against the real SW backend, not
the FakeBackend). T-010 is prerequisite for T-020 integration lane.

Tier 2 Codex review skipped — no codex wired, no tier_gate_mode set.

## Resume instructions

After /clear in a new session:

    resume /ck:make — Tier 2 continue, next task is T-016 (or T-010)

Read the files below before picking work:
- context/plans/build-site.md — task graph
- context/impl/impl-*.md — per-domain status tables
- context/impl/loop-log.md — this file (history + context)

## Wave 4 — Tier 2 close + Tier 3+4+5 (2026-04-23)

Continued from 13/21 checkpoint. Caveman build mode active.

Commits (in order):
- dab26... feat: T-016 + T-015 — SvtBackend contract tests + IVF recording path
- 9de61... feat: T-010 — CPU-side frame ingestion for SVT-AV1 software backend
- 0cbc1... feat: T-018 — probe-driven encoder backend selection
- 5c05c... feat: T-019 — regression guard: AV1 is the sole negotiated video codec
- 13ba4... feat: T-017 — ffprobe external-inspection verification of SW AV1 output
- aac68... feat: T-020 — GPU-free SVT-AV1 integration lane
- 8f5b7... feat: T-021 — macOS app-share migrated to SVT-AV1 (HEVC path retired)

(Commit SHAs approximate — see `git log` for truth.)

Summary of the wave:
- **T-016** — real SvtBackend passes runContract. encodeUntilOutput
  drain helper resolves the divergence between synchronous FakeBackend
  and SW encoders that buffer internally. SvtBackend.deinit now sends
  EOS + drains, cleaning up stderr noise.
- **T-015** — SvtBackend → IVF end-to-end test asserts DKIF magic,
  AV01 FourCC, dimensions, frame count. Uses the shared IvfWriter.
- **T-010** — shared yuv (BT.709 limited-range RGBA→I420) + linux
  frame_download (GL FBO readback). Wayland AppShare.BackendState
  gains .svt variant so intel/AMD hosts can actually produce AV1.
- **T-018** — selectBackend + selectRenderDevice in gpu_detect.
  Probe-driven selection; no user override. Daemon logs a deprecation
  warning if the legacy `gpu` field is sent.
- **T-019** — two regression tests on Codec + RTC_CODEC mapping lock
  viewer negotiation to AV1-only at the construction site.
- **T-017** — ffprobe JSON checks for BT.709 metadata + absence of
  B-frames, driven from the contract harness. Skips when ffprobe
  not on PATH.
- **T-020** — `./run.ts sw-integration` runs a synthetic capture
  through SVT-AV1 into FrameBuffer. CI-safe, no GPU.
- **T-021** — macOS migration. VideoToolbox HEVC backend deleted;
  new macos/frame_download.zig (CVPixelBuffer BGRA → I420) wires
  into SvtBackend. Linux build + tests still green; macOS runtime
  verification pending native hardware.

All 21 tasks DONE. Build green, tests green (6×200 + property +
contract + T-015/T-017 + sw-integration), lint clean.

Tier gates (Codex) skipped — `tier_gate_mode` off.
