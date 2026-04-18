---
created: "2026-04-18"
last_edited: "2026-04-18"
---
# Implementation Tracking: testing

Build site: context/plans/build-site.md

| Task | Status | Notes |
|------|--------|-------|
| T-002 | DONE | encoder_contract_test.zig skeleton + FakeBackend validation + registered in build.zig (commit adad2ed) |
| T-003 | DONE | FrameBuffer struct + FrameSink.buffer variant + unit tests (commit adad2ed) |
| T-004 | DONE | Encoder clock injection — start_ns + self.clock.nowNs() for PTS. 4 Encoder.init call sites updated. See commit message for boundary reads left in place. (commit adad2ed) |
| T-007 | PENDING | Contract suite expansion (blocked T-002 ✓, T-003 ✓ — unblocked) |
| T-008 | PENDING | Property tests (blocked T-002 ✓, T-003 ✓ — unblocked) |
| T-020 | PENDING | GPU-free integration lane (blocked T-018) |
