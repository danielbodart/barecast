---
created: "2026-04-18"
last_edited: "2026-04-18"
complexity: quick
---

# Cavekit: CLI and Daemon

## Scope
Single-binary process lifecycle for zerocast as an unprivileged user process. Covers daemon mode (long-lived server holding active shares), CLI mode (short-lived client dispatching commands to the daemon), the control protocol between them, and shared infrastructure (clock, debounce) that the rest of the system injects for testability.

## Requirements

### R1: Single binary, two modes
**Description:** One executable serves both as the daemon host process and as the short-lived command-line client. Which mode runs is determined by the invoked subcommand, not by a separate binary.
**Acceptance Criteria:**
- [ ] Invoking the binary with the daemon subcommand starts a long-lived process that does not return until stopped.
- [ ] Invoking any non-daemon subcommand executes a single operation against a running daemon and exits.
- [ ] Invoking the binary with no arguments prints usage and exits non-zero.

### R2: Supported subcommands
**Description:** The CLI exposes a closed, documented set of subcommands. Each maps to a single intent.
**Acceptance Criteria:**
- [ ] The CLI accepts: daemon, join, leave, share app, share terminal, unshare, status, start, stop, version.
- [ ] Any other first-argument token prints usage and exits non-zero.
- [ ] A dedicated attach subcommand is not accepted.
- [ ] The version subcommand prints a semantic version string and exits zero without contacting the daemon.

### R3: Control transport
**Description:** CLI and daemon communicate over a local, unauthenticated, per-user transport using a request/response protocol with structured messages.
**Acceptance Criteria:**
- [ ] The transport is not reachable from other users on the same host under default permissions.
- [ ] Requests and responses are discrete, framed messages; a malformed request does not crash the daemon.
- [ ] A CLI invocation fails fast with a clear message if no daemon is running.

### R4: Session slot table
**Description:** The daemon maintains a bounded table of concurrent share sessions. Each slot tracks identity, share kind, and lifecycle state. The slot-table capacity bounds how many shares one daemon can run; it is distinct from the per-share viewer fan-out bound owned by the transport kit.
**Acceptance Criteria:**
- [ ] The daemon rejects new shares once the slot table is full and returns a structured error the CLI surfaces.
- [ ] Each active share has a stable identifier that remains valid for the lifetime of the daemon process.
- [ ] The status subcommand lists every active share with its identifier, kind, and summary state.
- [ ] The slot table capacity is at least eight.

### R5: Per-share thread lifecycle
**Description:** Each share runs on its own thread. The daemon owns thread creation, handoff of lifecycle signals, and joining on shutdown.
**Acceptance Criteria:**
- [ ] Starting a share does not block the daemon's control loop from accepting other commands.
- [ ] Stopping a share signals its thread to exit and waits for thread exit before marking the slot free.
- [ ] A thread that exits unexpectedly frees its slot and logs a structured error entry.

### R6: Graceful shutdown
**Description:** The daemon drains active shares, closes its control transport, and exits on request. Shutdown is idempotent.
**Acceptance Criteria:**
- [ ] Issuing stop while shares are active causes each share to receive a teardown signal before the daemon exits.
- [ ] After stop returns, no subsequent CLI command reaches the daemon.
- [ ] A second stop issued concurrently succeeds without error.

### R7: Clock abstraction
**Description:** A clock interface provides the monotonic time reference used by any logic that depends on elapsed time. Tests supply a manually advanced clock; production supplies the OS monotonic clock.
**Acceptance Criteria:**
- [ ] The clock interface is a fat-pointer value that can be passed by reference into other components.
- [ ] A production clock implementation returns monotonic time from the operating system.
- [ ] A test clock implementation exposes a method to advance simulated time and does not advance on its own.
- [ ] Logic code reads elapsed time only through a clock value passed in by its owner.

### R8: Debounce primitive
**Description:** A reusable debounce construct coalesces rapid bursts of events into a single trailing-edge callback. It is generic over the event payload type and is driven by an injected clock rather than timer threads.
**Acceptance Criteria:**
- [ ] The debounce primitive accepts an event payload and a delay; events arriving within the delay window replace the pending payload.
- [ ] The primitive fires exactly once per quiet window, carrying the most recently observed payload.
- [ ] The primitive uses the injected clock for all time reads; tests advance time without sleeping.
- [ ] The primitive is usable from multiple domains without modification (e.g. capture resize coalescing).

### R9: Environment configuration only
**Description:** Runtime configuration is read from environment variables. No configuration file is read or written.
**Acceptance Criteria:**
- [ ] The signaling base URL is read from an environment variable and has a documented name.
- [ ] An optional recording output directory is read from an environment variable; when unset, recording is disabled.
- [ ] Starting the daemon without the signaling base URL fails with a clear diagnostic and does not create partial state.
- [ ] No command reads or writes a configuration file under the user's home directory.

### R10: Join, leave, share, unshare semantics
**Description:** A daemon belongs to at most one signaling room at a time. Share and unshare operate within that room.
**Acceptance Criteria:**
- [ ] Join attaches the daemon to a named room; if already joined, it rejects with a structured error.
- [ ] Leave detaches from the current room and stops all shares attached to it.
- [ ] Share app and share terminal require an active room; when none is joined, they reject with a structured error.
- [ ] Unshare targets a specific share identifier and does not affect other active shares.
- [ ] Start and stop map to daemon lifecycle (spawn/terminate), not to share lifecycle.

## Out of Scope
- Multi-user daemon: the daemon is strictly per-user and unprivileged.
- Configuration files, dotfiles, or persisted state on disk outside recordings.
- Remote control: the daemon is not reachable from other machines.
- The removed privileged KMS helper and its control protocol.
- An attach subcommand.

## Cross-References
- See also: cavekit-signaling.md (daemon consumes signaling base URL and room semantics)
- See also: cavekit-capture-pipeline.md (consumes Clock and Debounce for resize coalescing)
- See also: cavekit-webrtc-transport.md (daemon threads host per-share peer sessions)
- See also: cavekit-terminal-share.md (share terminal subcommand)
- See also: cavekit-testing.md (DI patterns, determinism, lint gate)

## Source Traceability
- `src/main.zig` — R1, R2 (mode dispatch)
- `src/shared/daemon.zig` — R3, R4, R5, R6, R10 (daemon core)
- `src/shared/cli.zig` — R2, R3, R10 (subcommand parsing and client)
- `src/shared/control.zig` — R3 (wire protocol)
- `src/shared/clock.zig` (or equivalent) — R7 (Clock interface)
- `src/shared/debounce.zig` (or equivalent) — R8 (Debounce primitive)

## Changelog
- 2026-04-18: initial draft (brownfield --from-code)
