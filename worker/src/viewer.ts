import { InputController, VIEWER_COLORS, type ViewerMode } from "./input";
import { OverlayRenderer } from "./overlay";

const video = document.getElementById("video") as HTMLVideoElement;
const statusEl = document.getElementById("status")!;
const toggle = document.getElementById("toggle")!;
const info = document.getElementById("info")!;
const statsPanel = document.getElementById("stats-panel")!;
const modeBtn = document.getElementById("mode-btn") as HTMLButtonElement | null;
const colorDot = document.getElementById("color-dot") as HTMLElement | null;

// Extract room ID from pathname: /room/:id or /room/:id/view
const viewPattern = new URLPattern({ pathname: "/room/:id/view" });
const roomPattern = new URLPattern({ pathname: "/room/:id" });
const viewMatch = viewPattern.exec(window.location.href);
const roomMatch = roomPattern.exec(window.location.href);
const roomId = viewMatch?.pathname.groups.id ?? roomMatch?.pathname.groups.id ?? null;

// Extract share_id from query param
const shareId = new URLSearchParams(window.location.search).get("share") || undefined;

if (!roomId) {
    window.location.href = "/";
} else {
    const peerId = Array.from(crypto.getRandomValues(new Uint8Array(8)))
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");

    const wsProto = location.protocol === "https:" ? "wss:" : "ws:";
    const shareParam = shareId ? `&share_id=${shareId}` : "";
    const wsBase = `${wsProto}//${location.host}/room/${roomId}/ws?role=viewer&peer_id=${peerId}${shareParam}`;

    // BroadcastChannel for hub page sync
    const bc = new BroadcastChannel(`zerocast-room-${roomId}`);
    if (shareId) bc.postMessage({ type: "share-opened", shareId });
    window.addEventListener("beforeunload", () => {
        if (shareId) bc.postMessage({ type: "share-closed", shareId });
    });

    let pc: RTCPeerConnection | null = null;
    let ws: WebSocket | null = null;
    let reconnectDelay = 1000;
    let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
    let streamSized = false;
    let isZoom = false;
    let inputCtrl: InputController | null = null;
    let overlay: OverlayRenderer | null = null;
    let iceServers: RTCIceServer[] = [
        { urls: "stun:stun.cloudflare.com:3478" },
    ];

    // ── Stats overlay state ─────────────────────────────────────────

    interface StatsSample {
        ts: number;
        framesDecoded: number;
        bytesReceived: number;
        totalDecodeTime: number;
        totalProcessingDelay: number;
        jitterBufferDelay: number;
        jitterBufferEmittedCount: number;
    }

    let statsInterval: ReturnType<typeof setInterval> | null = null;
    let statsPanelVisible = false;
    let lastSample: StatsSample | null = null;
    let rvfcHandle: number | null = null;
    let lastBrowserDelay: number | null = null;
    let lastE2eLatency: number | null = null;
    let lastProcessMs: number | null = null;

    // Stream section
    const sRes = document.getElementById("s-res")!;
    const sFps = document.getElementById("s-fps")!;
    const sBitrate = document.getElementById("s-bitrate")!;
    const sCodec = document.getElementById("s-codec")!;
    // Latency section
    const sE2e = document.getElementById("s-e2e")!;
    const sServer = document.getElementById("s-server")!;
    const sNetwork = document.getElementById("s-network")!;
    const sDecode = document.getElementById("s-decode")!;
    const sJbuf = document.getElementById("s-jbuf")!;
    const sRender = document.getElementById("s-render")!;
    // Connection section
    const sRtt = document.getElementById("s-rtt")!;
    const sLost = document.getElementById("s-lost")!;
    const sVia = document.getElementById("s-via")!;

    function startStatsPolling() {
        stopStatsPolling();
        startVideoFrameCallbacks();
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
            let totalDecodeTime = 0;
            let totalProcessingDelay = 0;
            let jitterBufferDelay = 0;
            let jitterBufferEmittedCount = 0;
            let framesDropped = 0;
            let decoderImpl = "";

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
                    totalDecodeTime = s.totalDecodeTime || 0;
                    totalProcessingDelay = s.totalProcessingDelay || 0;
                    jitterBufferDelay = s.jitterBufferDelay || 0;
                    jitterBufferEmittedCount = s.jitterBufferEmittedCount || 0;
                    framesDropped = s.framesDropped || 0;
                    decoderImpl = s.decoderImplementation || "";
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

            // FPS, bitrate, and latency from deltas
            const now = Date.now();
            if (lastSample) {
                const dtSec = (now - lastSample.ts) / 1000;
                const dFrames = framesDecoded - lastSample.framesDecoded;
                if (dtSec > 0) {
                    const fps = dFrames / dtSec;
                    sFps.textContent = fps.toFixed(1);
                    const bitrateKbps = ((bytesReceived - lastSample.bytesReceived) * 8) / dtSec / 1000;
                    sBitrate.textContent = bitrateKbps >= 1000
                        ? `${(bitrateKbps / 1000).toFixed(1)} Mbps`
                        : `${Math.round(bitrateKbps)} kbps`;

                    // Decode time (delta of cumulative seconds → ms per frame)
                    if (dFrames > 0) {
                        const dDecode = totalDecodeTime - lastSample.totalDecodeTime;
                        sDecode.textContent = `${((dDecode / dFrames) * 1000).toFixed(1)} ms`;

                        const dProcess = totalProcessingDelay - lastSample.totalProcessingDelay;
                        lastProcessMs = (dProcess / dFrames) * 1000;
                    }

                    // Jitter buffer delay (delta of cumulative)
                    const dJbufEmitted = jitterBufferEmittedCount - lastSample.jitterBufferEmittedCount;
                    if (dJbufEmitted > 0) {
                        const dJbuf = jitterBufferDelay - lastSample.jitterBufferDelay;
                        sJbuf.textContent = `${((dJbuf / dJbufEmitted) * 1000).toFixed(1)} ms`;
                    }

                    console.debug(`[stats] bitrate=${bitrateKbps.toFixed(1)}kbps fps=${fps.toFixed(1)} rtt=${rtt >= 0 ? Math.round(rtt * 1000) : -1}ms lost=${packetsLost} jitter=${(jitter * 1000).toFixed(1)}ms res=${frameWidth}x${frameHeight}`);
                }
            }
            lastSample = { ts: now, framesDecoded, bytesReceived, totalDecodeTime, totalProcessingDelay, jitterBufferDelay, jitterBufferEmittedCount };

            // RTT
            sRtt.textContent = rtt >= 0 ? `${Math.round(rtt * 1000)} ms` : "\u2014";

            // Codec + raw decoder implementation
            if (codecName !== "\u2014") {
                sCodec.textContent = decoderImpl ? `${codecName} (${decoderImpl})` : codecName;
            }

            // Packets lost
            sLost.textContent = String(packetsLost);

            // Connection
            sVia.textContent = candidateType;

            // Latency breakdown
            const rttMs = rtt >= 0 ? Math.round(rtt * 1000) : null;
            sNetwork.textContent = rttMs !== null ? `${Math.round(rttMs / 2)} ms` : "\u2014";

            if (lastE2eLatency !== null) {
                sE2e.textContent = `${Math.round(lastE2eLatency)} ms`;
            }

            // Server = e2e - browser delay (derived)
            if (lastE2eLatency !== null && lastBrowserDelay !== null) {
                const serverMs = Math.max(0, Math.round(lastE2eLatency - lastBrowserDelay));
                sServer.textContent = `${serverMs} ms`;
            }

            // Render = browser delay - process (compositor + vsync wait)
            if (lastBrowserDelay !== null && lastProcessMs !== null) {
                const renderMs = Math.max(0, Math.round(lastBrowserDelay - lastProcessMs));
                sRender.textContent = `${renderMs} ms`;
            }
        }, 1000);
    }

    function startVideoFrameCallbacks() {
        if (!("requestVideoFrameCallback" in video)) return;
        const onFrame = (_now: number, metadata: Record<string, any>) => {
            if (typeof metadata.receiveTime === "number") {
                lastBrowserDelay = performance.now() - metadata.receiveTime;
            }
            // End-to-end latency via abs-capture-time RTP extension.
            // W3C spec defines captureTimestamp as DOMHighResTimeStamp, but
            // Chrome (as of M120+) returns NTP milliseconds (ms since 1900-01-01).
            // Detect which format by checking if the value is plausibly NTP
            // (> year 2000 in NTP = 3155673600000 ms) vs DOMHighResTimeStamp
            // (typically < 86400000 ms = 24h since page load).
            const receiver = pc?.getReceivers().find(r => r.track?.kind === "video");
            if (receiver) {
                const sources = receiver.getSynchronizationSources();
                if (sources.length > 0) {
                    const ct = (sources[0] as any).captureTimestamp;
                    if (typeof ct === "number") {
                        if (ct > 3_155_673_600_000) {
                            // NTP milliseconds — subtract epoch offset, compare with Date.now()
                            lastE2eLatency = Date.now() - (ct - 2_208_988_800_000);
                        } else {
                            // DOMHighResTimeStamp — compare with performance.now()
                            lastE2eLatency = performance.now() - ct;
                        }
                    }
                }
            }
            rvfcHandle = (video as any).requestVideoFrameCallback(onFrame);
        };
        rvfcHandle = (video as any).requestVideoFrameCallback(onFrame);
    }

    function stopVideoFrameCallbacks() {
        if (rvfcHandle !== null && "cancelVideoFrameCallback" in video) {
            (video as any).cancelVideoFrameCallback(rvfcHandle);
            rvfcHandle = null;
        }
        lastBrowserDelay = null;
        lastE2eLatency = null;
        lastProcessMs = null;
    }

    function stopStatsPolling() {
        if (statsInterval) {
            clearInterval(statsInterval);
            statsInterval = null;
        }
        stopVideoFrameCallbacks();
        lastSample = null;
    }

    function hideStatsPanel() {
        statsPanel.classList.remove("visible");
        statsPanelVisible = false;
    }

    function setStatus(msg: string) {
        statusEl.textContent = msg;
        statusEl.classList.remove("hidden");
    }

    function updateModeUI(mode: ViewerMode) {
        if (modeBtn) {
            modeBtn.textContent = mode === "draw" ? "draw" : "input";
            modeBtn.title = `Mode: ${mode} (Tab to toggle)`;
        }
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

    // ── Mode toggle ───────────────────────────────────────────────────

    if (modeBtn) {
        modeBtn.addEventListener("click", () => {
            inputCtrl?.toggleMode();
        });
    }

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
        statusEl.classList.add("hidden");
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
                if (inputCtrl) {
                    inputCtrl.destroy();
                    inputCtrl = null;
                }
                if (overlay) {
                    overlay.destroy();
                    overlay = null;
                }
                setStatus("Waiting for sharer...");
                if (pc) {
                    pc.close();
                    pc = null;
                }
            } else if (msg.type === "shares-list") {
                // Ignored by viewer pop-out — hub handles this
            }
        };
    }

    function scheduleReconnect() {
        stopStatsPolling();
        hideStatsPanel();
        if (inputCtrl) {
            inputCtrl.destroy();
            inputCtrl = null;
        }
        if (overlay) {
            overlay.destroy();
            overlay = null;
        }
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

        // Data channel for input/draw — created by host, received here
        pc.ondatachannel = (event) => {
            const dc = event.channel;
            if (dc.label !== "input") return;

            if (inputCtrl) inputCtrl.destroy();
            if (overlay) overlay.destroy();
            overlay = new OverlayRenderer(video);
            overlay.start();
            inputCtrl = new InputController(dc, video, {
                overlay,
                onModeChange: (mode) => updateModeUI(mode),
                onColorAssign: (index) => {
                    if (colorDot) {
                        colorDot.style.background =
                            VIEWER_COLORS[index % VIEWER_COLORS.length];
                        colorDot.classList.add("visible");
                    }
                },
            });
            if (modeBtn) modeBtn.classList.add("visible");
            updateModeUI("draw");
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
            if (!pc) return;
            if (pc.iceConnectionState === "connected" || pc.iceConnectionState === "completed") {
                statusEl.classList.add("hidden");
                toggle.classList.add("visible");
                info.classList.add("visible");
                startStatsPolling();
            } else if (pc.iceConnectionState === "disconnected" || pc.iceConnectionState === "failed") {
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
