---
created: "2026-04-18"
last_edited: "2026-04-18"
complexity: medium
---

# Cavekit: WebRTC Transport

## Scope
Real-time media and control transport between one host (sharer) and many browser viewers. Covers per-peer lifecycle, the binary input protocol carried over a data channel, multi-viewer state, and the latency-oriented RTP conventions the pipeline relies on. Does not cover signalling message routing (see signaling kit) nor frame production (see capture-pipeline kit).

## Requirements

### R1: One broadcast session per share, bounded fan-out
**Description:** Each active share runs a single broadcast session that accepts multiple viewer peers. The maximum number of concurrent viewers per share is bounded. This bound is distinct from the daemon's bound on concurrent shares; a host can run multiple shares, each with its own viewer pool.
**Acceptance Criteria:**
- [ ] A share accepts up to eight concurrent viewers.
- [ ] An attempt to join beyond the limit is rejected with a structured error and does not disturb existing viewers.
- [ ] When a viewer disconnects, its slot is reclaimed and a subsequent join can take it.

### R2: Per-peer lifecycle
**Description:** Each viewer has an independent peer session with its own negotiation, connectivity establishment, keyframe delivery, and loss-recovery state.
**Acceptance Criteria:**
- [ ] A new viewer completes offer/answer negotiation and connectivity establishment without disturbing other viewers.
- [ ] On attach, the new viewer receives a keyframe as its first decodable frame.
- [ ] Negative acknowledgements for lost packets are honored per peer.
- [ ] Picture-loss indications from a viewer cause the encoder to emit a keyframe on the next frame.
- [ ] A viewer teardown completes without leaking native transport handles.
**Dependencies:** cavekit-capture-pipeline.md (keyframe-on-demand, R9)

### R3: Two-phase peer initialization
**Description:** Peer construction creates native handles first and registers event callbacks in a second phase, so callbacks cannot fire against a half-initialized object. Handle destruction follows explicit rules to avoid deadlocks with the transport library.
**Acceptance Criteria:**
- [ ] Construction returns a peer whose handles are created but whose callbacks have not yet been registered.
- [ ] A separate start step registers callbacks; callbacks never fire before this step returns.
- [ ] Handles are destroyed outside any lock that is also acquired by a callback.
- [ ] A peer teardown under concurrent callback activity does not deadlock.

### R4: Absolute capture-time RTP extension
**Description:** Each emitted video frame carries an absolute capture-time extension in its RTP header that allows the viewer to compute true end-to-end latency against a trusted clock reference.
**Acceptance Criteria:**
- [ ] Every video RTP packet contains a populated absolute capture-time extension.
- [ ] The extension value is set once per frame at capture completion and propagates unchanged to the viewer.
- [ ] A viewer reading the extension can compute the difference between capture-time and its own decode-time clock.

### R5: Zero-jitter playout
**Description:** The transport signals to viewers that no jitter buffering delay is desired. Viewers that honor this signal play out frames as soon as they are decodable.
**Acceptance Criteria:**
- [ ] The transport's playout-delay hint requests a minimum and maximum delay of zero.
- [ ] The hint is present in the negotiated media description.

### R6: Binary input protocol
**Description:** A compact, little-endian, message-framed protocol carries control events over the control data channel. Messages fall into two directions: viewer-to-host and host-to-viewer.
**Acceptance Criteria:**
- [ ] Viewer-to-host messages exist for at minimum: mouse input, keyboard input, draw path updates, viewer-initiated resize, and relay-forward payloads.
- [ ] Host-to-viewer messages exist for at minimum: viewer color assignment, relayed viewer events, host resize notifications, and viewer-left notifications.
- [ ] Encoding and decoding of each message are implemented symmetrically, and a roundtrip over any valid payload yields the original payload.
- [ ] Malformed or truncated messages are rejected without crashing the receiver.

### R7: Control data channel — unreliable, ordered
**Description:** The control data channel carries the binary input protocol. It uses transport semantics suitable for real-time input: ordered delivery of what arrives, no retransmission of stale events. Use of this channel is scoped to low-latency small messages; bulk payloads use a separate channel (R11).
**Acceptance Criteria:**
- [ ] The control data channel is negotiated with unreliable delivery and ordered reception.
- [ ] Loss of a mouse movement event does not block delivery of later events.
- [ ] Terminal byte streams and any other bulk payloads do not flow over the control channel.

### R8: Viewer registry
**Description:** The host maintains a registry of attached viewers. Each viewer has an assigned color drawn from a bounded palette and tracks its cursor position and a bounded set of active draw paths.
**Acceptance Criteria:**
- [ ] On attach, each viewer is assigned a color from a palette and no two attached viewers share a color while the palette has free entries.
- [ ] Each viewer's last known cursor position is retrievable from the registry.
- [ ] The number of draw paths retained per viewer is bounded; when the bound is exceeded, the oldest path is dropped.
- [ ] On detach, the viewer's entry and its associated draw state are released.

### R9: TURN credentials from signaling
**Description:** Ephemeral TURN credentials are delivered through the signaling channel and applied to the peer before connectivity gathering begins.
**Acceptance Criteria:**
- [ ] A peer does not begin connectivity gathering before TURN credentials, if any, have been applied.
- [ ] Credentials that expire mid-session do not invalidate an already-established peer connection.
**Dependencies:** cavekit-signaling.md (credential delivery)

### R10: Host relay of selected viewer messages
**Description:** The host rebroadcasts a configured subset of viewer messages (cursor position, draw path updates) to every other attached viewer so that multi-viewer presence is observable to all.
**Acceptance Criteria:**
- [ ] A cursor-position message from one viewer is delivered to all other attached viewers within one relay step, tagged with the originating viewer's identity.
- [ ] A draw path update from one viewer is delivered to all other attached viewers, tagged with the originating viewer's identity.
- [ ] Messages not in the relay set are not forwarded.

### R11: Bulk data channel — reliable, ordered
**Description:** A separate data channel carries bulk byte streams where message loss is unacceptable — primarily terminal output. It uses transport semantics that guarantee in-order, lossless delivery, accepting higher latency in exchange for reliability.
**Acceptance Criteria:**
- [ ] A bulk data channel exists distinct from the control channel (R7) and is negotiated with reliable, ordered delivery.
- [ ] A byte sequence written to the bulk channel at the host appears at every attached viewer in the same order with no loss, assuming the peer connection is alive.
- [ ] Backpressure on the bulk channel does not block the control channel, and vice versa.
- [ ] A share kind that does not use bulk delivery (e.g. video-only shares) is not required to open the bulk channel.
**Dependencies:** cavekit-terminal-share.md (consumer)

## Out of Scope
- Signalling message exchange and room membership.
- Frame production, encoding, and codec selection.
- Browser-side rendering of cursors and draw paths.
- Audio tracks.
- Viewer-to-viewer direct connections.

## Cross-References
- See also: cavekit-capture-pipeline.md (keyframe on demand, encoded frame producer)
- See also: cavekit-signaling.md (SDP, ICE, TURN delivery)
- See also: cavekit-viewer-ui.md (browser peer, input encoder, overlay renderer)
- See also: cavekit-terminal-share.md (shares the data channel transport)
- See also: cavekit-testing.md (peer lifecycle contract tests, input protocol roundtrips)

## Source Traceability
- `src/shared/session.zig` — R1, R2, R3, R7, R8, R10, R11
- `src/shared/input_protocol.zig` — R6, R7
- `src/shared/viewer_state.zig` — R8
- `src/shared/encoder.zig` — R4, R5 (abs-capture-time, playout-delay)
- libdatachannel fork (danielbodart/libdatachannel) — R4

## Changelog
- 2026-04-18: initial draft (brownfield --from-code)
- 2026-04-18: reviewer pass — split R7 into control (unreliable) vs bulk (reliable, new R11); clarified R1 dimensional scope
