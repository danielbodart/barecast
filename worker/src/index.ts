export { SignalingRoom } from "./room.ts";

export default {
    async fetch(request: Request, env: Env): Promise<Response> {
        const url = new URL(request.url);

        // Serve viewer on / or any path with ?room= query param
        if (url.pathname === "/" || url.searchParams.has("room")) {
            return new Response(viewerHtml(), {
                headers: { "Content-Type": "text/html" },
            });
        }

        // WebSocket signaling — route to Durable Object
        const match = url.pathname.match(/^\/room\/([a-zA-Z0-9_-]+)\/ws$/);
        if (match) {
            const roomId = match[1];
            const id = env.ROOMS.idFromName(roomId);
            const room = env.ROOMS.get(id);
            return room.fetch(request);
        }

        return new Response("Not found", { status: 404 });
    },
};

function viewerHtml(): string {
    return `<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>barecast</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { background: #000; display: flex; align-items: center; justify-content: center; height: 100vh; overflow: hidden; }
        video { max-width: 100vw; max-height: 100vh; background: #000; }
        #status {
            position: fixed; top: 0; left: 0; right: 0; bottom: 0;
            display: flex; align-items: center; justify-content: center;
            color: #888; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            font-size: 16px; pointer-events: none; z-index: 10;
            transition: opacity 0.3s;
        }
        #status.hidden { opacity: 0; }
    </style>
</head>
<body>
    <div id="status">Connecting...</div>
    <video id="video" autoplay playsinline muted></video>
    <script>
    (function() {
        var video = document.getElementById('video');
        var status = document.getElementById('status');
        var params = new URLSearchParams(window.location.search);
        var roomId = params.get('room');

        if (!roomId) {
            status.textContent = 'No room specified. Use ?room=<id>';
            return;
        }

        // Generate a stable peer ID for this browser tab session
        var peerId = Array.from(crypto.getRandomValues(new Uint8Array(8)))
            .map(function(b) { return b.toString(16).padStart(2, '0'); }).join('');

        var wsProto = location.protocol === 'https:' ? 'wss:' : 'ws:';
        var wsBase = wsProto + '//' + location.host + '/room/' + roomId + '/ws?role=viewer&peer_id=' + peerId;

        var pc = null;
        var ws = null;
        var reconnectDelay = 1000;
        var reconnectTimer = null;

        function setStatus(msg) {
            status.textContent = msg;
            status.classList.remove('hidden');
        }

        function connect() {
            if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }

            ws = new WebSocket(wsBase);

            ws.onopen = function() {
                reconnectDelay = 1000;
                setStatus('Waiting for sharer...');
            };

            ws.onclose = function() {
                scheduleReconnect();
            };

            ws.onerror = function() { /* onclose fires after */ };

            ws.onmessage = function(event) {
                var msg = JSON.parse(event.data);

                if (msg.type === 'offer') {
                    handleOffer(msg.sdp);
                } else if (msg.type === 'ice' && pc) {
                    pc.addIceCandidate({ candidate: msg.candidate, sdpMid: msg.mid || '0' })
                        .catch(function() {});
                } else if (msg.type === 'sharer-left') {
                    setStatus('Waiting for sharer...');
                    if (pc) { pc.close(); pc = null; }
                }
            };
        }

        function scheduleReconnect() {
            if (pc) { pc.close(); pc = null; }
            var delaySec = Math.round(reconnectDelay / 1000);
            setStatus('Reconnecting in ' + delaySec + 's...');
            reconnectTimer = setTimeout(function() {
                reconnectTimer = null;
                connect();
            }, reconnectDelay);
            reconnectDelay = Math.min(reconnectDelay * 2, 30000);
        }

        function handleOffer(sdp) {
            // Close any existing PC before handling a new offer
            if (pc) { pc.close(); pc = null; }
            setStatus('Negotiating...');

            pc = new RTCPeerConnection({
                iceServers: [{ urls: 'stun:stun.cloudflare.com:3478' }]
            });

            pc.ontrack = function(event) {
                video.srcObject = event.streams[0] || new MediaStream([event.track]);
                video.play().catch(function() {});
            };

            video.onplaying = function() {
                status.classList.add('hidden');
            };

            pc.onicecandidate = function(event) {
                if (event.candidate && ws && ws.readyState === WebSocket.OPEN) {
                    ws.send(JSON.stringify({
                        type: 'ice',
                        candidate: event.candidate.candidate,
                        mid: event.candidate.sdpMid || '0'
                    }));
                }
            };

            pc.oniceconnectionstatechange = function() {
                if (pc && (pc.iceConnectionState === 'disconnected' || pc.iceConnectionState === 'failed')) {
                    setStatus('Connection lost');
                }
            };

            pc.setRemoteDescription(new RTCSessionDescription({ type: 'offer', sdp: sdp }))
                .then(function() { return pc.createAnswer(); })
                .then(function(answer) {
                    return pc.setLocalDescription(answer);
                })
                .then(function() {
                    if (ws && ws.readyState === WebSocket.OPEN && pc && pc.localDescription) {
                        ws.send(JSON.stringify({ type: 'answer', sdp: pc.localDescription.sdp }));
                    }
                })
                .catch(function(err) {
                    setStatus('Negotiation failed');
                });
        }

        connect();
    })();
    </script>
</body>
</html>`;
}
