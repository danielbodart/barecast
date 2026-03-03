/**
 * Terminal viewer — connects via WebRTC data channel to a terminal share.
 * Uses xterm.js for rendering, sends keyboard input back via the same channel.
 */

import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";

const roomId = window.location.pathname.split("/")[2];
const wsScheme = window.location.protocol === "https:" ? "wss:" : "ws:";
const wsUrl = `${wsScheme}//${window.location.host}/room/${roomId}/ws?role=viewer`;

let pc: RTCPeerConnection | null = null;
let dc: RTCDataChannel | null = null;
let ws: WebSocket | null = null;
let term: Terminal | null = null;
let fitAddon: FitAddon | null = null;

function init() {
    // Create terminal
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

    fitAddon = new FitAddon();
    term.loadAddon(fitAddon);

    const container = document.getElementById("terminal");
    if (container) {
        term.open(container);
        fitAddon.fit();
    }

    // Handle window resize
    window.addEventListener("resize", () => {
        if (fitAddon) fitAddon.fit();
        sendResize();
    });

    // Handle keyboard input — send to data channel
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

    ws.onmessage = (event) => {
        const msg = JSON.parse(event.data);

        if (msg.type === "offer") {
            handleOffer(msg);
        } else if (msg.type === "ice" && msg.from) {
            handleIce(msg);
        } else if (msg.type === "turn-credentials") {
            // Store TURN credentials for next PC creation
            console.log("TURN credentials received");
        }
    };

    ws.onclose = () => {
        console.log("Signaling closed, reconnecting in 3s...");
        setTimeout(connectSignaling, 3000);
    };
}

async function handleOffer(msg: { sdp: string; from: string }) {
    const config: RTCConfiguration = {
        iceServers: [{ urls: "stun:stun.cloudflare.com:3478" }],
    };

    pc = new RTCPeerConnection(config);

    pc.onicecandidate = (event) => {
        if (event.candidate && ws && ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({
                type: "ice",
                to: msg.from,
                candidate: event.candidate.candidate,
                mid: event.candidate.sdpMid || "0",
            }));
        }
    };

    pc.ondatachannel = (event) => {
        if (event.channel.label === "terminal") {
            dc = event.channel;
            dc.binaryType = "arraybuffer";

            dc.onopen = () => {
                console.log("Terminal channel open");
                if (term) term.write("\r\n\x1b[32mConnected.\x1b[0m\r\n\r\n");
                sendResize();
            };

            dc.onmessage = (e) => {
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
            to: msg.from,
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
        // Send resize as JSON on the data channel
        // Format: \x1b[R<cols>;<rows> (escape sequence prefix to distinguish from input)
        const msg = `\x1b[R${term.cols};${term.rows}`;
        dc.send(msg);
    }
}

// Auto-init
if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
} else {
    init();
}
