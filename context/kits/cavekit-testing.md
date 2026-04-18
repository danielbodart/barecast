---
created: "2026-04-18"
last_edited: "2026-04-18"
complexity: medium
---

# Cavekit: Testing

## Scope
Cross-cutting testing strategy, dependency-injection patterns, and specification philosophy that every other domain in zerocast must follow. Defines what kinds of tests exist, how collaborators are injected for testability, and the bar that must be met before code merges.

## Requirements

### R1: Specification-first
**Description:** Every non-trivial change starts with testable acceptance criteria. New production code must exist to satisfy a named criterion in a cavekit, and new criteria must be accompanied by at least one test that would fail without the corresponding code.
**Acceptance Criteria:**
- [ ] Every acceptance criterion in a cavekit can be mapped to at least one automated test case.
- [ ] Pull requests introducing behavior add or update a test case in the same change.
- [ ] Criteria that cannot be automatically validated are marked `[needs human review]` or converted to an observable form.
**Dependencies:** none

### R2: Three test tiers
**Description:** Tests are partitioned into three distinct tiers with different cost and fidelity profiles. Fast tiers run on every change; slower tiers run only where dedicated hardware exists.
**Acceptance Criteria:**
- [ ] Unit tier runs to completion without a GPU, without network access, and without mutating the user's persistent filesystem outside of a temporary directory.
- [ ] Property tier exercises decoders, state invariants, and roundtrips using generated inputs and records counterexamples on failure.
- [ ] Integration tier exercises capture, encode, and transport end to end on real hardware and is runnable via a single project command.
- [ ] Each tier has a single documented entry point command; the unit + property tiers share one command, the integration tiers each have their own.
**Dependencies:** cavekit-cli-daemon.md (test entry points surfaced via run.ts)

### R3: Dependency injection via fat-pointer interfaces
**Description:** Collaborators whose behavior depends on ambient state (time, GPU, filesystem, network) are accepted as interfaces so tests can substitute deterministic implementations. Logic paths never read ambient state through global singletons.
**Acceptance Criteria:**
- [ ] Time reads on any logic path go through an injected clock interface rather than a direct call to the OS monotonic clock.
- [ ] Encoder backend, frame sink, and viewer transport are accepted as interface types at their public construction points.
- [ ] A grep for direct OS-clock calls inside logic modules returns no results outside of the production clock implementation and test doubles.

### R4: Production-shaped doubles, not mocks
**Description:** Test doubles implement the same interfaces as their production counterparts and behave as real objects. Tests do not use per-method expectation DSLs; they observe real state transitions on the double.
**Acceptance Criteria:**
- [ ] Every interface used in tests has a production implementation and at least one double implementation; both pass the same interface contract tests where one exists.
- [ ] Time-controlling doubles advance only when the test explicitly advances them.
- [ ] In-memory frame sinks store produced bytes so tests can assert over real output.
- [ ] No test uses a method-call expectation framework to stub return values.

### R5: Determinism
**Description:** Tests that depend on elapsed time advance simulated time through the injected clock rather than sleeping. Tests that depend on real hardware timing have tolerance bands rather than exact comparisons.
**Acceptance Criteria:**
- [ ] Non-integration tests do not call a sleep primitive on the current thread.
- [ ] Integration tests that measure throughput or latency assert against a range, not an equality.
- [ ] A test that fails once in a local run is treated as failing; retry-on-failure is not used to mask flakes.

### R6: Boundary fidelity
**Description:** At kernel, socket, and peer-to-peer transport boundaries, tests use real kernel primitives and real peer sessions rather than fakes that bypass the system under test.
**Acceptance Criteria:**
- [ ] PTY-related tests spawn a real pseudo-terminal pair.
- [ ] Daemon control-socket tests bind a real Unix socket inside a temporary directory.
- [ ] WebRTC transport tests establish a real peer-to-peer session between two in-process peers.
- [ ] No test substitutes a hand-rolled fake for the kernel socket, file, or process APIs.

### R7: Static analysis gate
**Description:** A single lint command runs all configured static-analysis checks across Zig and shell sources, and this command must pass before code can merge.
**Acceptance Criteria:**
- [ ] The lint entry point exits non-zero if any checked rule is violated.
- [ ] Continuous integration runs the lint entry point and blocks merge on failure.
- [ ] The lint entry point covers at least: dead-code detection, illegal-store detection in Zig, and shell-script linting.
**Dependencies:** cavekit-cli-daemon.md (lint entry point surfaced via run.ts)

### R8: Coverage expectations per domain
**Description:** Each functional cavekit enumerates specific test cases it must satisfy. This cavekit defines the tiers and patterns; each domain owns the test cases that prove its requirements.
**Acceptance Criteria:**
- [ ] Every functional cavekit cross-references this cavekit.
- [ ] Every functional cavekit contains at least one acceptance criterion that is unit-testable and at least one that is integration-testable where hardware is involved.

### R9: No flaky tests
**Description:** Flaky tests are either fixed at the source of non-determinism or removed. Retry loops are not used to hide flakiness.
**Acceptance Criteria:**
- [ ] Any test observed to fail intermittently is either deleted or accompanied by a change that removes the non-determinism in the same pull request.
- [ ] No test harness configuration enables automatic retry-on-failure.

## Out of Scope
- Code coverage percentage targets. Specific criteria in domain kits define coverage, not line percentages.
- Mutation testing.
- Load, stress, and soak testing frameworks.
- Human-in-the-loop exploratory testing procedures.
- Benchmarking methodology (distinct concern from correctness testing).

## Cross-References
- See also: cavekit-cli-daemon.md (Clock and Debounce primitives exposed for injection)
- See also: cavekit-capture-pipeline.md (encoder backend and frame sink interfaces)
- See also: cavekit-webrtc-transport.md (peer lifecycle two-phase init covered by interface tests)
- See also: cavekit-terminal-share.md (PTY boundary fidelity)
- See also: cavekit-signaling.md (worker-level tests)
- See also: cavekit-viewer-ui.md (browser-side protocol encoder/decoder property tests)

## Source Traceability
- `packages/zerocast/src/shared/prop_tests.zig` — R2, R4 (property-based test harness)
- `packages/zerocast/src/shared/daemon.zig` — R3, R6 (Clock injection at daemon boundary)
- `packages/zerocast/src/shared/encoder.zig` — R3 (FrameSink dispatch)
- `run.ts` — R2, R7 (test and lint entry points)

## Changelog
- 2026-04-18: initial draft (brownfield --from-code)
