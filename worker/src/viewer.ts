const video = document.getElementById("video") as HTMLVideoElement;
const status = document.getElementById("status")!;
const toggle = document.getElementById("toggle")!;

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

    // ── Auto-resize on first frame ────────────────────────────────────

    video.addEventListener("playing", () => {
        status.classList.add("hidden");
        toggle.classList.add("visible");

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

            if (msg.type === "offer") {
                handleOffer(msg.sdp);
            } else if (msg.type === "ice" && pc) {
                pc.addIceCandidate({
                    candidate: msg.candidate,
                    sdpMid: msg.mid || "0",
                }).catch(() => {});
            } else if (msg.type === "sharer-left") {
                setStatus("Waiting for sharer...");
                if (pc) {
                    pc.close();
                    pc = null;
                }
            }
        };
    }

    function scheduleReconnect() {
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
        if (pc) {
            pc.close();
            pc = null;
        }
        setStatus("Negotiating...");

        pc = new RTCPeerConnection({
            iceServers: [{ urls: "stun:stun.cloudflare.com:3478" }],
        });

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
