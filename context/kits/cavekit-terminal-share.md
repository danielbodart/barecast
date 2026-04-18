---
created: "2026-04-18"
last_edited: "2026-04-18"
complexity: medium
---

# Cavekit: Terminal Share

## Scope
Sharing a terminal session with remote viewers over a reliable data channel. Covers pseudo-terminal spawning, byte streaming to viewers, replay of recent output for late joiners, bidirectional input, terminal resize handling, OSC title extraction, and optional asciinema recording. Does not cover video capture or rendering; terminal output is streamed as raw bytes and rendered browser-side.

## Requirements

### R1: Spawn a pseudo-terminal under the user's shell
**Description:** The terminal share spawns a child process attached to a new pseudo-terminal pair. The child runs the user's shell by default, or a user-supplied command when provided.
**Acceptance Criteria:**
- [ ] A terminal share with no command argument launches the shell indicated by the user's environment.
- [ ] A terminal share with a command argument launches exactly that command with its arguments.
- [ ] Child standard output and standard error are attached to the pseudo-terminal master side.
- [ ] The child inherits a sane controlling-terminal configuration.

### R2: Stream raw bytes to viewers
**Description:** Bytes read from the pseudo-terminal master are forwarded verbatim to every attached viewer. The bytes flow over the reliable, ordered bulk data channel provided by the transport domain; no retransmission logic or reordering is handled here.
**Acceptance Criteria:**
- [ ] A byte sequence written by the child appears at every attached viewer in the same order.
- [ ] No byte is altered, stripped, or re-encoded in transit.
- [ ] A backpressured bulk channel does not cause loss of bytes already produced by the child.
**Dependencies:** cavekit-webrtc-transport.md R11 (reliable bulk data channel)

### R3: Replay ring for late joiners
**Description:** The host retains a bounded amount of recent output. A newly attached viewer receives the retained replay before new output flows to it.
**Acceptance Criteria:**
- [ ] The replay buffer has a documented, bounded size.
- [ ] A viewer attaching after output has been produced receives the retained replay as its first delivered bytes.
- [ ] Retained output does not exceed the buffer's documented size regardless of session length.

### R4: Bidirectional viewer input
**Description:** Keystrokes and other input events originating from a viewer are delivered into the pseudo-terminal master so the child observes them on its standard input.
**Acceptance Criteria:**
- [ ] A keystroke event from a viewer results in the corresponding bytes appearing on the child's standard input.
- [ ] Input from multiple viewers is interleaved without loss at the byte level.

### R5: Viewer-initiated terminal resize
**Description:** A viewer resize event retargets the pseudo-terminal's reported window size. The child receives the signal and may reflow.
**Acceptance Criteria:**
- [ ] A resize event with new rows and columns updates the pseudo-terminal's window-size state.
- [ ] The child process observes the resize signal associated with the pseudo-terminal change.

### R6: OSC title extraction across reads
**Description:** The host extracts the window-title reported by the shell via OSC sequences. Extraction handles sequences that span multiple read chunks.
**Acceptance Criteria:**
- [ ] An OSC 0 sequence emitted in a single read produces a title update.
- [ ] An OSC 2 sequence emitted in a single read produces a title update.
- [ ] An OSC sequence split across two or more reads produces a single title update when the sequence terminates.
- [ ] Malformed or unterminated sequences are dropped without corrupting subsequent parsing.

### R7: Optional asciinema recording
**Description:** When a recording output path is configured, the terminal share writes an asciinema v2 file describing the session.
**Acceptance Criteria:**
- [ ] With no recording path configured, no file is created.
- [ ] With a recording path configured, the file begins with a single JSON header line that matches the asciinema v2 format.
- [ ] Subsequent lines are arrays of [timestamp, stream, payload] describing output events in order.
- [ ] The written file is readable by a standard asciinema player.

### R8: Graceful teardown
**Description:** The share shuts down cleanly when the child exits or when the operator requests stop. Resources are released deterministically.
**Acceptance Criteria:**
- [ ] When the child exits, the share notifies every attached viewer and releases the pseudo-terminal.
- [ ] An operator-issued stop signals the child, waits for it to exit, and then releases resources.
- [ ] No pseudo-terminal file descriptors leak after teardown.
- [ ] No recording file is left partially written; either it is a valid asciinema v2 file or it is removed.

## Out of Scope
- Video capture, encoding, or streaming.
- GPU pipeline integration.
- Audio streams.
- Multiplexed shells on one pseudo-terminal.
- Shared-edit semantics; viewer input is raw passthrough.

## Cross-References
- See also: cavekit-webrtc-transport.md R11 (reliable bulk data channel), R4–R5 do not apply to terminal flows
- See also: cavekit-cli-daemon.md (share terminal subcommand, recording environment variable)
- See also: cavekit-viewer-ui.md (terminal viewer)
- See also: cavekit-testing.md (PTY boundary fidelity, OSC parser property tests)

## Source Traceability
- `packages/zerocast/src/shared/terminal_share.zig` — R1, R2, R3, R4, R5, R7, R8
- `packages/zerocast/src/shared/osc_parser.zig` — R6
- `packages/worker/src/terminal-viewer.ts` — R2, R4, R5 (viewer counterpart)

## Changelog
- 2026-04-18: initial draft (brownfield --from-code)
- 2026-04-18: reviewer pass — R2 explicitly references transport R11 (reliable bulk channel) to resolve channel-semantics ambiguity
