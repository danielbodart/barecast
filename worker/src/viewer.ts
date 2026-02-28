const video = document.getElementById("video") as HTMLVideoElement;
const status = document.getElementById("status")!;
const toggle = document.getElementById("toggle")!;
const info = document.getElementById("info")!;
const statsPanel = document.getElementById("stats-panel")!;

// Extract room ID from pathname: /room/:id
const pattern = new URLPattern({ pathname: "/room/:id" });
const pathMatch = pattern.exec(window.location.href);
const roomId = pathMatch?.pathname.groups.id ?? null;

if (!roomId) {
    window.location.href = "/";
} else {
    const peerId = Array.from(crypto.getRandomValues(new Uint8Array(8)))
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");

    const wsProto = location.protocol === "https:" ? "wss:" : "ws:";
    const wsBase = `${wsProto}//${location.host}/room/${roomId}/ws?role=viewer&peer_id=${peerId}`;

    let pc: RTCPeerConnection | null = null;
    let ws: WebSocket | null = null;
    let reconnectDelay = 1000;
    let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
    let streamSized = false;
    let isZoom = false;
    let iceServers: RTCIceServer[] = [
        { urls: "stun:stun.cloudflare.com:3478" },
    ];

    // ── Stats overlay state ─────────────────────────────────────────

    interface StatsSample {
        ts: number;
        framesDecoded: number;
        bytesReceived: number;
    }

    let statsInterval: ReturnType<typeof setInterval> | null = null;
    let statsPanelVisible = false;
    let lastSample: StatsSample | null = null;

    const sRes = document.getElementById("s-res")!;
    const sFps = document.getElementById("s-fps")!;
    const sBitrate = document.getElementById("s-bitrate")!;
    const sRtt = document.getElementById("s-rtt")!;
    const sCodec = document.getElementById("s-codec")!;
    const sLost = document.getElementById("s-lost")!;
    const sJitter = document.getElementById("s-jitter")!;
    const sVia = document.getElementById("s-via")!;

    function startStatsPolling() {
        stopStatsPolling();
        if (statsPanelVisible) {
            statsPanel.classList.add("visible");
        }
        statsInterval = setInterval(async () => {
            if (!pc) return;
            let report: RTCStatsReport;
            try {
                report = await pc.getStats();
            } catch {
                return;
            }
            if (!pc) return;

            let frameWidth = 0;
            let frameHeight = 0;
            let framesDecoded = 0;
            let bytesReceived = 0;
            let packetsLost = 0;
            let jitter = 0;
            let codecId = "";
            let codecName = "\u2014";
            let rtt = -1;
            let localCandidateId = "";
            let candidateType = "\u2014";

            for (const stat of report.values()) {
                if (stat.type === "inbound-rtp" && (stat as any).kind === "video") {
                    const s = stat as any;
                    frameWidth = s.frameWidth || 0;
                    frameHeight = s.frameHeight || 0;
                    framesDecoded = s.framesDecoded || 0;
                    bytesReceived = s.bytesReceived || 0;
                    packetsLost = s.packetsLost || 0;
                    jitter = s.jitter || 0;
                    codecId = s.codecId || "";
                } else if (stat.type === "codec" && stat.id === codecId) {
                    codecName = ((stat as any).mimeType || "").replace("video/", "");
                } else if (stat.type === "candidate-pair" && (stat as any).state === "succeeded") {
                    const s = stat as any;
                    if (s.currentRoundTripTime !== undefined) {
                        rtt = s.currentRoundTripTime;
                    }
                    localCandidateId = s.localCandidateId || "";
                } else if (stat.type === "local-candidate" && stat.id === localCandidateId) {
                    candidateType = (stat as any).candidateType || "\u2014";
                }
            }

            // Second pass for codec and candidate (may appear before their reference)
            if (codecName === "\u2014" && codecId) {
                for (const stat of report.values()) {
                    if (stat.type === "codec" && stat.id === codecId) {
                        codecName = ((stat as any).mimeType || "").replace("video/", "");
                        break;
                    }
                }
            }
            if (candidateType === "\u2014" && localCandidateId) {
                for (const stat of report.values()) {
                    if (stat.type === "local-candidate" && stat.id === localCandidateId) {
                        candidateType = (stat as any).candidateType || "\u2014";
                        break;
                    }
                }
            }

            // Resolution
            sRes.textContent = frameWidth > 0 ? `${frameWidth}\u00d7${frameHeight}` : "\u2014";

            // FPS and bitrate from deltas
            const now = Date.now();
            if (lastSample) {
                const dtSec = (now - lastSample.ts) / 1000;
                if (dtSec > 0) {
                    const fps = (framesDecoded - lastSample.framesDecoded) / dtSec;
                    sFps.textContent = fps.toFixed(1);
                    const bitrateKbps = ((bytesReceived - lastSample.bytesReceived) * 8) / dtSec / 1000;
                    sBitrate.textContent = bitrateKbps >= 1000
                        ? `${(bitrateKbps / 1000).toFixed(1)} Mbps`
                        : `${Math.round(bitrateKbps)} kbps`;
                }
            }
            lastSample = { ts: now, framesDecoded, bytesReceived };

            // RTT
            sRtt.textContent = rtt >= 0 ? `${Math.round(rtt * 1000)} ms` : "\u2014";

            // Codec
            sCodec.textContent = codecName;

            // Packets lost
            sLost.textContent = String(packetsLost);

            // Jitter
            sJitter.textContent = jitter > 0 ? `${(jitter * 1000).toFixed(1)} ms` : "\u2014";

            // Connection type
            sVia.textContent = candidateType;
        }, 1000);
    }

    function stopStatsPolling() {
        if (statsInterval) {
            clearInterval(statsInterval);
            statsInterval = null;
        }
        lastSample = null;
    }

    function hideStatsPanel() {
        statsPanel.classList.remove("visible");
        statsPanelVisible = false;
    }

    function setStatus(msg: string) {
        status.textContent = msg;
        status.classList.remove("hidden");
    }

    // ── Zoom toggle ───────────────────────────────────────────────────

    toggle.addEventListener("click", () => {
        isZoom = !isZoom;
        if (isZoom) {
            document.body.classList.add("zoom");
            toggle.textContent = "fit";
        } else {
            document.body.classList.remove("zoom");
            toggle.textContent = "1:1";
        }
    });

    // ── Stats toggle ────────────────────────────────────────────────

    info.addEventListener("click", () => {
        statsPanelVisible = !statsPanelVisible;
        if (statsPanelVisible) {
            statsPanel.classList.add("visible");
        } else {
            statsPanel.classList.remove("visible");
        }
    });

    // ── Auto-resize on first frame ────────────────────────────────────

    video.addEventListener("playing", () => {
        status.classList.add("hidden");
        toggle.classList.add("visible");
        info.classList.add("visible");
        startStatsPolling();

        if (!streamSized && video.videoWidth > 0) {
            streamSized = true;
            const vw = video.videoWidth;
            const vh = video.videoHeight;

            // Set CSS custom properties for zoom mode (1:1 native pixels)
            document.documentElement.style.setProperty("--video-w", vw + "px");
            document.documentElement.style.setProperty("--video-h", vh + "px");

            // Resize window to stream dimensions, clamped to screen
            const ratio = vw / vh;
            const maxW = screen.availWidth;
            const maxH = screen.availHeight;
            let fitW = vw;
            let fitH = vh;
            if (fitW > maxW) {
                fitW = maxW;
                fitH = Math.round(maxW / ratio);
            }
            if (fitH > maxH) {
                fitH = maxH;
                fitW = Math.round(maxH * ratio);
            }
            window.resizeTo(fitW, fitH);
        }
    });

    // ── WebSocket signaling ───────────────────────────────────────────

    function connect() {
        if (reconnectTimer) {
            clearTimeout(reconnectTimer);
            reconnectTimer = null;
        }

        ws = new WebSocket(wsBase);

        ws.onopen = () => {
            reconnectDelay = 1000;
            setStatus("Waiting for sharer...");
        };

        ws.onclose = () => {
            scheduleReconnect();
        };

        ws.onerror = () => {
            /* onclose fires after */
        };

        ws.onmessage = (event) => {
            const msg = JSON.parse(event.data);

            if (msg.type === "turn-credentials") {
                iceServers = [
                    { urls: "stun:stun.cloudflare.com:3478" },
                    {
                        urls: [
                            "turn:turn.cloudflare.com:3478?transport=udp",
                            "turn:turn.cloudflare.com:3478?transport=tcp",
                            "turns:turn.cloudflare.com:5349?transport=tcp",
                            "turns:turn.cloudflare.com:443?transport=tcp",
                        ],
                        username: msg.username,
                        credential: msg.credential,
                    },
                ];
            } else if (msg.type === "offer") {
                handleOffer(msg.sdp);
            } else if (msg.type === "ice" && pc) {
                pc.addIceCandidate({
                    candidate: msg.candidate,
                    sdpMid: msg.mid || "0",
                }).catch(() => {});
            } else if (msg.type === "sharer-left") {
                stopStatsPolling();
                hideStatsPanel();
                setStatus("Waiting for sharer...");
                if (pc) {
                    pc.close();
                    pc = null;
                }
            }
        };
    }

    function scheduleReconnect() {
        stopStatsPolling();
        hideStatsPanel();
        if (pc) {
            pc.close();
            pc = null;
        }
        const delaySec = Math.round(reconnectDelay / 1000);
        setStatus(`Reconnecting in ${delaySec}s...`);
        reconnectTimer = setTimeout(() => {
            reconnectTimer = null;
            connect();
        }, reconnectDelay);
        reconnectDelay = Math.min(reconnectDelay * 2, 30000);
    }

    function handleOffer(sdp: string) {
        stopStatsPolling();
        if (pc) {
            pc.close();
            pc = null;
        }
        setStatus("Negotiating...");

        pc = new RTCPeerConnection({ iceServers });

        pc.ontrack = (event) => {
            video.srcObject =
                event.streams[0] || new MediaStream([event.track]);
            video.play().catch(() => {});
        };

        pc.onicecandidate = (event) => {
            if (
                event.candidate &&
                ws &&
                ws.readyState === WebSocket.OPEN
            ) {
                ws.send(
                    JSON.stringify({
                        type: "ice",
                        candidate: event.candidate.candidate,
                        mid: event.candidate.sdpMid || "0",
                    })
                );
            }
        };

        pc.oniceconnectionstatechange = () => {
            if (
                pc &&
                (pc.iceConnectionState === "disconnected" ||
                    pc.iceConnectionState === "failed")
            ) {
                setStatus("Connection lost");
            }
        };

        pc.setRemoteDescription(
            new RTCSessionDescription({ type: "offer", sdp })
        )
            .then(() => pc!.createAnswer())
            .then((answer) => pc!.setLocalDescription(answer))
            .then(() => {
                if (
                    ws &&
                    ws.readyState === WebSocket.OPEN &&
                    pc &&
                    pc.localDescription
                ) {
                    ws.send(
                        JSON.stringify({
                            type: "answer",
                            sdp: pc.localDescription.sdp,
                        })
                    );
                }
            })
            .catch(() => {
                setStatus("Negotiation failed");
            });
    }

    connect();
}

// ── Service worker registration ───────────────────────────────────────

if ("serviceWorker" in navigator) {
    navigator.serviceWorker.register("/sw.js").catch(() => {});
}
