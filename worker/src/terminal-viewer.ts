/**
 * Terminal viewer — connects via WebRTC data channel to a terminal share.
 * xterm.js is loaded from CDN in terminal.html.
 * This script initializes the terminal and handles WebRTC signaling.
 */

declare const Terminal: any;
declare const FitAddon: any;

const roomId = window.location.pathname.split("/")[2];
const shareId = new URLSearchParams(window.location.search).get("share") || undefined;
const wsScheme = window.location.protocol === "https:" ? "wss:" : "ws:";
const peerId = Array.from(crypto.getRandomValues(new Uint8Array(8)))
    .map((b: number) => b.toString(16).padStart(2, "0"))
    .join("");
const shareParam = shareId ? `&share_id=${shareId}` : "";
const wsUrl = `${wsScheme}//${window.location.host}/room/${roomId}/ws?role=viewer&peer_id=${peerId}${shareParam}`;

// BroadcastChannel for hub page sync
const bc = new BroadcastChannel(`zerocast-room-${roomId}`);
if (shareId) bc.postMessage({ type: "share-opened", shareId });
window.addEventListener("beforeunload", () => {
    if (shareId) bc.postMessage({ type: "share-closed", shareId });
});

let pc: RTCPeerConnection | null = null;
let dc: RTCDataChannel | null = null;
let ws: WebSocket | null = null;
let term: any = null;
let fitAddon: any = null;
let iceServers: RTCIceServer[] = [
    { urls: "stun:stun.cloudflare.com:3478" },
];

function init() {
    term = new Terminal({
        cursorBlink: true,
        fontSize: 14,
        fontFamily: "'JetBrains Mono', 'Fira Code', 'Cascadia Code', monospace",
        theme: {
            background: "#1a1a2e",
            foreground: "#e0e0e0",
            cursor: "#e0e0e0",
        },
    });

    fitAddon = new FitAddon.FitAddon();
    term.loadAddon(fitAddon);

    const container = document.getElementById("terminal");
    if (container) {
        term.open(container);
        fitAddon.fit();
    }

    window.addEventListener("resize", () => {
        if (fitAddon) fitAddon.fit();
        sendResize();
    });

    // Update browser tab title when program sets terminal title (OSC 0/2)
    term.onTitleChange((title: string) => {
        document.title = title || "zerocast terminal";
    });

    term.onData((data: string) => {
        if (dc && dc.readyState === "open") {
            dc.send(data);
        }
    });

    connectSignaling();
}

function connectSignaling() {
    ws = new WebSocket(wsUrl);

    ws.onopen = () => {
        console.log("Signaling connected");
    };

    ws.onmessage = (event: MessageEvent) => {
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
            handleOffer(msg);
        } else if (msg.type === "ice") {
            handleIce(msg);
        } else if (msg.type === "sharer-left") {
            if (pc) { pc.close(); pc = null; }
            if (dc) { dc = null; }
            if (term) term.write("\r\n\x1b[31mSharer disconnected.\x1b[0m\r\n");
        } else if (msg.type === "shares-list") {
            // Ignored by terminal viewer pop-out
        }
    };

    ws.onclose = () => {
        console.log("Signaling closed, reconnecting...");
        if (pc) { pc.close(); pc = null; }
        dc = null;
        setTimeout(connectSignaling, 1000);
    };
}

async function handleOffer(msg: { sdp: string; from?: string }) {
    pc = new RTCPeerConnection({ iceServers });

    pc.onicecandidate = (event: RTCPeerConnectionIceEvent) => {
        if (event.candidate && ws && ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({
                type: "ice",
                candidate: event.candidate.candidate,
                mid: event.candidate.sdpMid || "0",
            }));
        }
    };

    pc.ondatachannel = (event: RTCDataChannelEvent) => {
        if (event.channel.label === "terminal") {
            dc = event.channel;
            dc.binaryType = "arraybuffer";

            dc.onopen = () => {
                console.log("Terminal channel open");
                if (term) term.write("\r\n\x1b[32mConnected.\x1b[0m\r\n\r\n");
                sendResize();
            };

            dc.onmessage = (e: MessageEvent) => {
                if (term) {
                    if (typeof e.data === "string") {
                        term.write(e.data);
                    } else {
                        term.write(new Uint8Array(e.data));
                    }
                }
            };

            dc.onclose = () => {
                console.log("Terminal channel closed");
                if (term) term.write("\r\n\x1b[31mDisconnected.\x1b[0m\r\n");
            };
        }
    };

    await pc.setRemoteDescription(new RTCSessionDescription({
        type: "offer",
        sdp: msg.sdp,
    }));

    const answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);

    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({
            type: "answer",
            sdp: answer.sdp,
        }));
    }
}

function handleIce(msg: { candidate: string; mid: string }) {
    if (pc) {
        pc.addIceCandidate(new RTCIceCandidate({
            candidate: msg.candidate,
            sdpMid: msg.mid,
        })).catch(console.warn);
    }
}

function sendResize() {
    if (dc && dc.readyState === "open" && term) {
        const msg = `\x1b[R${term.cols};${term.rows}`;
        dc.send(msg);
    }
}

if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
} else {
    init();
}
