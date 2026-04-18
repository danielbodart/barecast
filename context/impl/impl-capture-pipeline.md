---
created: "2026-04-18"
last_edited: "2026-04-18"
---
# Implementation Tracking: capture-pipeline

Build site: context/plans/build-site.md

| Task | Status | Notes |
|------|--------|-------|
| T-001 | DONE | SVT-AV1 v3.1.2 submodule + rebuild-libs wiring (commit adad2ed). COMPILE_C_ONLY=ON (no NASM). Lib at SVT-AV1/Bin/Release/libSvtAv1Enc.a |
| T-005 | DONE | Inventory worklist at context/impl/svt-av1-non-av1-inventory.md (commit 91ad99b) |
| T-006 | PENDING | SW backend adapter (blocked T-001 ✓ — unblocked) |
| T-009 | PENDING | Delete non-AV1/VBR symbols (blocked T-005 ✓ — unblocked) |
| T-010 | PENDING | Frame ingestion (blocked T-006) |
| T-011 | PENDING | CQP config (blocked T-006) |
| T-012 | PENDING | P-only GOP (blocked T-006) |
| T-013 | PENDING | BT.709 (blocked T-006) |
| T-014 | PENDING | Force keyframe (blocked T-006) |
| T-015 | PENDING | IVF wiring (blocked T-011/12/13) |
| T-016 | PENDING | HW+SW pass contract (blocked T-007/11/12/13/14) |
| T-017 | PENDING | External inspection check (blocked T-015) |
| T-018 | PENDING | Selector wiring (blocked T-016) |
| T-019 | PENDING | Negotiation regression (blocked T-018) |
| T-021 | PENDING | macOS SVT-AV1 migration (blocked T-018) |
