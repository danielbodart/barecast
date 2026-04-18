---
created: "2026-04-18"
last_edited: "2026-04-18"
complexity: complex
---

# Cavekit: Viewer UI

## Scope
The browser-side applications served by the signalling worker: screen viewer, terminal viewer, room hub, the input-event encoder that translates browser events into the binary control protocol, and the overlay renderer that draws remote cursors and draw paths over the video surface. Includes the installability and offline shell behavior.

## Requirements

### R1: Zero-install browser viewer
**Description:** A viewer runs in any modern browser without installing a native application, browser extension, or plugin.
**Acceptance Criteria:**
- [ ] Opening the viewer URL in a supported browser produces a functional session without prompting for installation.
- [ ] The viewer does not require any browser permission beyond those implied by WebRTC and microphone-free media.
- [ ] Documentation lists the set of supported browsers and versions.

### R2: Screen viewer session
**Description:** The screen viewer negotiates a WebRTC session with the host and presents the incoming video track in a full-viewport element that auto-scales as the window changes size. It recovers from transient transport loss by reconnecting.
**Acceptance Criteria:**
- [ ] The video element scales to fit the available viewport while preserving aspect ratio.
- [ ] A transport loss that closes the peer triggers a reconnect attempt without requiring a page reload.
- [ ] A successful reconnect delivers a keyframe as its first decoded frame.

### R3: Terminal viewer session
**Description:** The terminal viewer presents a terminal emulator backed by a WebRTC data channel. Resizing the viewer's terminal pane propagates to the host.
**Acceptance Criteria:**
- [ ] Bytes received over the data channel are rendered to the terminal in order.
- [ ] Changing the terminal pane's rows or columns results in a resize event sent to the host.
- [ ] User keystrokes are sent to the host as input events.

### R4: Room hub
**Description:** The hub presents a live grid of active shares in a room. Each card shows per-share statistics and links to the appropriate viewer.
**Acceptance Criteria:**
- [ ] The hub updates its grid when a share is added or removed without a page reload.
- [ ] Each card displays the share's kind, current resolution, current frames-per-second, and current bitrate.
- [ ] Clicking a card opens the associated viewer in a new browser context.
**Dependencies:** cavekit-signaling.md (shares-list broadcast)

### R5: SVG overlay for cursors and draws
**Description:** Remote viewer cursors and draw paths are rendered as a scalable-vector overlay on top of the video element. Each remote participant's overlay uses a color drawn from the palette assigned by the host.
**Acceptance Criteria:**
- [ ] A remote viewer's cursor position renders as a cursor glyph in that viewer's assigned color.
- [ ] A remote viewer's draw path renders in that viewer's assigned color.
- [ ] The local participant's draw strokes render immediately on input without awaiting a relay round trip.
- [ ] Overlay elements scale and position correctly as the underlying video element resizes.

### R6: Drawing interaction model
**Description:** The viewer supports an opt-in drawing mode with explicit gestures for toggle, draw, undo, and clear.
**Acceptance Criteria:**
- [ ] Pressing Tab toggles drawing mode on and off.
- [ ] In drawing mode, a left-button drag creates a draw path that is sent to the host.
- [ ] A right-click removes the most recent draw path authored by the local participant.
- [ ] Holding the right button for a long press removes all draw paths authored by the local participant.

### R7: Input encoder conforms to binary protocol
**Description:** The browser translates DOM input events into binary messages that match the host's expected protocol byte layout exactly. Coordinate values reported to the host are in native video-resolution space, not CSS-pixel space.
**Acceptance Criteria:**
- [ ] An encoded mouse event round-trips through the host decoder yielding the same field values.
- [ ] An encoded keyboard event round-trips through the host decoder yielding the same field values.
- [ ] Mouse coordinates sent to the host are expressed in the remote video's native pixel dimensions regardless of how the video element is scaled locally.
**Dependencies:** cavekit-webrtc-transport.md (binary input protocol)

### R8: Installable progressive web application
**Description:** The viewer is installable as a progressive web application with a service worker that enables an update shell. Network fetches are passed through the service worker without altering semantics.
**Acceptance Criteria:**
- [ ] A supported browser presents an install prompt on the viewer origin.
- [ ] A registered service worker handles fetch events and forwards them to the network without altering request or response semantics.
- [ ] Installing the viewer does not change the behavior of an already-open session.

### R9: Latency and transport stats panel
**Description:** The viewer exposes a stats panel that shows the latency breakdown and network quality indicators for the current session.
**Acceptance Criteria:**
- [ ] The panel displays end-to-end latency derived from the capture-time extension.
- [ ] The panel displays server-side pipeline latency summary derived from host telemetry.
- [ ] The panel displays decode latency, jitter-buffer delay, render delay, and network round-trip time.
- [ ] Values update at least once per second while a session is active.
**Dependencies:** cavekit-webrtc-transport.md (abs-capture-time), cavekit-capture-pipeline.md (pipeline timings)

## Out of Scope
- Native desktop or mobile applications.
- Authentication UI, accounts, and access control.
- Audio rendering.
- Recording or download of viewer-side media.
- Administrative dashboards.

## Cross-References
- See also: cavekit-signaling.md (asset origin, shares-list)
- See also: cavekit-webrtc-transport.md (binary protocol, abs-capture-time, peer lifecycle)
- See also: cavekit-capture-pipeline.md (pipeline timings surfaced in stats)
- See also: cavekit-terminal-share.md (data channel contract)
- See also: cavekit-testing.md (protocol roundtrip property tests)

## Source Traceability
- `packages/worker/src/viewer.ts` — R1, R2, R5, R6, R7, R8, R9
- `packages/worker/src/terminal-viewer.ts` — R1, R3, R7
- `packages/worker/src/index.ts` — R4 (hub page served by worker)
- `packages/worker/src/overlay.ts` — R5, R6

## Changelog
- 2026-04-18: initial draft (brownfield --from-code)
