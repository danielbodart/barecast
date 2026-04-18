---
created: "2026-04-18"
last_edited: "2026-04-18"
---
# Loop Log

Build site: context/plans/build-site.md
TIER_START_REF (tier 0): ee10c8db0f70feaa1f4620e8aefd808ea42331f4
TIER_0_END_REF: adad2edTBD

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
object database. Work recovered inline on trunk:
- Packet A: submodule + build_linux.zig edits redone manually. NASM
  missing → switched to COMPILE_C_ONLY=ON. Also had to add
  `-Wno-date-time` then simplify to just `-DCOMPILE_C_ONLY=ON`.
- Packet B: redone inline with correct encoder.zig shape (agent
  transcript was hallucinated on file structure). Real EncodeBackend
  vtable has 4 fn pointers (prepareFn/encodeFn/unlockFn/deinitFn).
  Clock injection done on Encoder struct directly.
- Packet C: inventory doc recreated from agent's output verbatim.

Commits:
- 91ad99b — cavekit + build-site + inventory (T-005)
- adad2ed — SVT-AV1 submodule + FrameSink.buffer + contract skeleton +
  clock injection (T-001, T-002, T-003, T-004)

Status: T-001..T-005 all DONE. Build/test/lint green.
Tier 0 complete — proceeding to Wave 2 (Tier 1).

**Process fix going forward:** Dispatch subagents without
`isolation: worktree` or with foreground execution so their commits
land on trunk directly. The worktree + background combination is
incompatible with this harness's auto-clean behaviour.
