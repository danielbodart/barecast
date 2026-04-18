---
created: "2026-04-18"
last_edited: "2026-04-18"
---
# Implementation Tracking: testing

Build site: context/plans/build-site.md

| Task | Status | Notes |
|------|--------|-------|
| T-002 | DONE | encoder_contract_test.zig skeleton + FakeBackend validation. Registered in build.zig test_step. Commit adad2ed |
| T-003 | DONE | FrameBuffer + FrameSink.buffer variant in encoder.zig. Ring buffer, bounded alloc, oldest-first iteration. Inline unit tests. Commit adad2ed |
| T-004 | DONE | Encoder clock injection — clock: Clock + start_ns: u64 fields, PTS via (clock.nowNs - start_ns). 4 Encoder.init call sites updated. Legacy timer field kept for session_recorder compat (refactor later). Commit adad2ed |
| T-007 | DONE | Contract suite expansion — caseReconfigureEmitsKeyframe + caseMalformedInputRejected added. runContract now 5 cases. Commit 6399803 |
| T-008 | DONE | Property tests — sweeps 7 resolutions × fps/qp combinations through runContract; separate idempotent-reconfigure loop. Commit 6399803 |
| T-020 | PENDING | GPU-free integration lane — capture → SvtBackend → IVF through FrameSink.buffer, exposed via run.ts entry point. Blocked on T-018. |
