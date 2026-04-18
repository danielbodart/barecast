---
created: "2026-04-18"
last_edited: "2026-04-18"
---

# Cavekit Overview: Zerocast

Zerocast is an opinionated screen and terminal sharing tool for developers. A native binary hosts shared applications inside an embedded compositor, hardware-encodes the output to AV1, and streams it over WebRTC to zero-install browser viewers. A minimal Cloudflare-hosted worker brokers signalling and serves the viewer applications.

This overview indexes the seven domain cavekits and a cross-cutting testing cavekit. Each kit is the single source of truth for its domain. Downstream plans and implementations trace back to numbered requirements here.

## Domain Index

| Domain | File | Requirements | Status | Description |
|---|---|---|---|---|
| Capture Pipeline | [cavekit-capture-pipeline.md](cavekit-capture-pipeline.md) | 15 | DRAFT | Embedded compositor, frame capture, AV1 encode, session recording. |
| WebRTC Transport | [cavekit-webrtc-transport.md](cavekit-webrtc-transport.md) | 11 | DRAFT | Per-viewer peer lifecycle, control + bulk data channels, binary input protocol, relay, TURN. |
| Signaling | [cavekit-signaling.md](cavekit-signaling.md) | 9 | DRAFT | Worker-hosted broker, rooms, asset delivery, CI-only deploys. |
| CLI and Daemon | [cavekit-cli-daemon.md](cavekit-cli-daemon.md) | 10 | DRAFT | Single-binary mode split, control socket, Clock, Debounce. |
| Terminal Share | [cavekit-terminal-share.md](cavekit-terminal-share.md) | 8 | DRAFT | PTY-backed terminal streaming, replay, OSC title, asciinema. |
| Viewer UI | [cavekit-viewer-ui.md](cavekit-viewer-ui.md) | 9 | DRAFT | Browser screen viewer, terminal viewer, hub, overlay, stats. |
| Testing | [cavekit-testing.md](cavekit-testing.md) | 9 | DRAFT | Test tiers, DI patterns, determinism, lint gate (cross-cutting). |

Totals: 7 domain kits + 1 cross-cutting testing kit; 71 requirements.

## Cross-Reference Matrix

Rows reference columns. A mark means the row kit has an explicit dependency on or collaboration point with the column kit.

|                      | capture | transport | signaling | cli-daemon | terminal | viewer-ui | testing |
|----------------------|---------|-----------|-----------|------------|----------|-----------|---------|
| capture-pipeline     |         |     x     |           |     x      |          |           |    x    |
| webrtc-transport     |    x    |           |     x     |            |    x     |     x     |    x    |
| signaling            |         |     x     |           |            |          |     x     |    x    |
| cli-daemon           |    x    |     x     |     x     |            |    x     |           |    x    |
| terminal-share       |         |     x     |           |     x      |          |     x     |    x    |
| viewer-ui            |    x    |     x     |     x     |            |    x     |           |    x    |
| testing              |    x    |     x     |     x     |     x      |    x     |     x     |         |

## Dependency Graph (Build / Design Order)

```
        testing  (cross-cutting, no prereqs)
           |
           v
     cli-daemon              signaling
     (Clock,                (room broker,
      Debounce,              TURN creds,
      control plane)         shares-list)
       |    \                   |
       |     \                  |
       v      v                 v
   capture  webrtc-transport <--+
   pipeline   (consumes           (consumes shares-list,
    (consumes  signaling,          static assets)
     Clock/    emits input
     Debounce, protocol)
     emits                            ^
     frames)                          |
       |         |                    |
       v         v                    |
     (frames)  terminal-share ---> viewer-ui
               (PTY + data            (screen + terminal
                channel)               + hub + overlay
                                       + stats)
```

Build order summary:
1. testing (patterns are applied everywhere).
2. cli-daemon and signaling in parallel (no mutual dependency).
3. capture-pipeline depends on cli-daemon (Clock, Debounce) and testing.
4. webrtc-transport depends on signaling, capture-pipeline (keyframe-on-demand contract), and testing.
5. terminal-share depends on webrtc-transport (data channel), cli-daemon (subcommand, recording env), and testing.
6. viewer-ui depends on signaling, webrtc-transport, capture-pipeline (timings), terminal-share (data channel contract), and testing.

## Direction of Travel Captured in This Draft

- AV1 is the only codec; HEVC has been removed from all requirements.
- SVT-AV1 is the software fallback for hosts without hardware AV1 encode and is the primary macOS encode path today.
- The privileged KMS helper is not included; its removal is assumed.
- No attach CLI subcommand is included.
- macOS support is in scope but current gaps are marked `[GAP]` in the relevant kits.

## Changelog
- 2026-04-18: initial draft (brownfield --from-code) of the full kit set.
- 2026-04-18: reviewer pass — transport kit grew R11 (bulk channel); totals + description updated; transport↔terminal cross-reference marked in matrix.
