---
created: "2026-04-18"
last_edited: "2026-04-18"
complexity: medium
---

# Cavekit: Signaling

## Scope
The signalling server: a durable-object-backed worker that brokers control messages between sharers and viewers so they can establish peer-to-peer media sessions. Also serves the static assets (viewer, terminal-viewer, hub) referenced by clients. The signalling tier never handles media.

## Requirements

### R1: Room is a single-instance message broker
**Description:** A room is a single instance identified by a client-generated room identifier. All participants connected to the same identifier share one broker instance. Connecting to a room identifier creates the instance on demand.
**Acceptance Criteria:**
- [ ] Two clients connecting with the same room identifier are routed to the same broker instance.
- [ ] A client connecting with a new identifier causes that instance to be created without an explicit room-creation step.
- [ ] Room instances are strongly isolated: a message sent in one room is never delivered to another.

### R2: Participant tagging
**Description:** Each participant in a room is tagged by role. Sharers are distinguished from viewers, and each participant within a role is addressable by a stable identifier for the duration of its connection.
**Acceptance Criteria:**
- [ ] A sharer is identified within its room by a share identifier.
- [ ] A viewer is identified within its room by a peer identifier.
- [ ] A single room may contain multiple sharers and multiple viewers simultaneously.

### R3: Hibernation-friendly connections
**Description:** Long-lived client connections use a hibernation-aware mechanism so that idle rooms consume no compute resources. Hibernated rooms wake transparently when a message arrives.
**Acceptance Criteria:**
- [ ] A room with no in-flight messages and all connections idle does not hold a running compute instance.
- [ ] A message arriving for a hibernated room results in delivery without the sender observing a reconnect.

### R4: Targeted SDP and ICE forwarding
**Description:** SDP offers, SDP answers, and ICE candidates are delivered only to the specific counterpart they target. Signalling messages are not broadcast to unrelated participants.
**Acceptance Criteria:**
- [ ] A viewer-originated offer targeted at a specific share identifier is delivered only to that sharer.
- [ ] A sharer-originated answer targeted at a specific peer identifier is delivered only to that viewer.
- [ ] ICE candidates are delivered only along the specific sharer-viewer pair they belong to.
- [ ] Malformed or untargeted signalling messages are rejected with a structured error.

### R5: TURN credential delivery
**Description:** Each peer receives ephemeral TURN credentials before it needs them for connectivity establishment. Credentials are scoped to the session and carry an expiry.
**Acceptance Criteria:**
- [ ] A newly connected peer receives TURN credentials before being asked to produce ICE candidates.
- [ ] Credentials include an explicit expiry time.
- [ ] Credentials are not reused across different peers.

### R6: Shares-list broadcast
**Description:** The signalling tier maintains a live list of active shares per room and pushes updates to hub subscribers. Subscribers see sharers appear and disappear as they join and leave.
**Acceptance Criteria:**
- [ ] A hub subscriber connected to a room receives the current set of active shares on connection.
- [ ] When a sharer joins the room, subscribers receive an add notification within one message round trip.
- [ ] When a sharer leaves the room, subscribers receive a remove notification within one message round trip.
- [ ] Notifications include at minimum: share identifier and share kind.

### R7: Static asset delivery
**Description:** The worker serves the viewer, terminal-viewer, and hub browser applications as static assets from the same origin that hosts signalling.
**Acceptance Criteria:**
- [ ] A request for the hub asset returns a valid HTML response.
- [ ] A request for the screen-viewer asset returns a valid HTML response.
- [ ] A request for the terminal-viewer asset returns a valid HTML response.
- [ ] Unknown paths return a structured 404 response.

### R8: Deploys via continuous integration only
**Description:** The signalling worker is deployed only by the continuous-integration system on pushes to the canonical branch. No developer machine is authorized to deploy.
**Acceptance Criteria:**
- [ ] Repository documentation states that deploys go through CI only.
- [ ] The CI workflow is the only recorded source of production deploys in the project's deployment history.

### R9: Media-free broker
**Description:** The signalling tier never handles media frames. It exchanges only control messages and serves assets.
**Acceptance Criteria:**
- [ ] No code path in the signalling tier consumes or forwards RTP payloads.
- [ ] A review of signalling-tier dependencies reveals no media-codec libraries.

## Out of Scope
- Media relay and SFU behavior.
- Authentication and access control beyond what TURN credentials imply.
- Persistent storage of messages or rooms beyond the lifetime of the broker instance.
- User accounts, billing, and quotas.
- Recording on the signalling side.

## Cross-References
- See also: cavekit-webrtc-transport.md (consumer of SDP/ICE/TURN)
- See also: cavekit-viewer-ui.md (consumer of shares-list and static assets)
- See also: cavekit-cli-daemon.md (daemon connects to signaling base URL on join)
- See also: cavekit-testing.md (worker-level contract tests)

## Source Traceability
- `worker/src/index.ts` — R1, R7
- `worker/src/room.ts` — R1, R2, R3, R4, R5, R6, R9
- `worker/src/viewer.ts` — R7
- `worker/src/terminal-viewer.ts` — R7
- CI workflow under `.github/workflows/` — R8

## Changelog
- 2026-04-18: initial draft (brownfield --from-code)
