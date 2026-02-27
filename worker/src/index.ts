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
        const video = document.getElementById('video');
        const status = document.getElementById('status');
        const params = new URLSearchParams(window.location.search);
        const roomId = params.get('room');

        if (!roomId) {
            status.textContent = 'No room specified. Use ?room=<id>';
            return;
        }

        function setStatus(msg) {
            status.textContent = msg;
            status.classList.remove('hidden');
        }

        // Determine WebSocket URL from current page origin
        const wsProto = location.protocol === 'https:' ? 'wss:' : 'ws:';
        const wsUrl = wsProto + '//' + location.host + '/room/' + roomId + '/ws?role=viewer';

        const ws = new WebSocket(wsUrl);
        let pc = null;

        ws.onopen = function() {
            setStatus('Waiting for sharer...');
        };

        ws.onclose = function() {
            setStatus('Disconnected');
        };

        ws.onerror = function() {
            setStatus('Connection error');
        };

        ws.onmessage = function(event) {
            const msg = JSON.parse(event.data);

            if (msg.type === 'offer') {
                handleOffer(msg.sdp);
            } else if (msg.type === 'ice' && pc) {
                pc.addIceCandidate(new RTCIceCandidate({
                    candidate: msg.candidate,
                    sdpMid: msg.mid
                })).catch(function() {});
            } else if (msg.type === 'peer-disconnected') {
                setStatus('Sharer disconnected');
                if (pc) { pc.close(); pc = null; }
            }
        };

        async function handleOffer(sdp) {
            setStatus('Negotiating...');

            pc = new RTCPeerConnection({
                iceServers: [{ urls: 'stun:stun.cloudflare.com:3478' }]
            });

            pc.ontrack = function(event) {
                video.srcObject = event.streams[0] || new MediaStream([event.track]);
                video.play().catch(function() {});
            };

            // Hide status once video starts playing
            video.onplaying = function() {
                status.classList.add('hidden');
            };

            pc.onicecandidate = function(event) {
                if (event.candidate) {
                    ws.send(JSON.stringify({
                        type: 'ice',
                        candidate: event.candidate.candidate,
                        mid: event.candidate.sdpMid || '0'
                    }));
                }
            };

            pc.oniceconnectionstatechange = function() {
                if (pc.iceConnectionState === 'disconnected' || pc.iceConnectionState === 'failed') {
                    setStatus('Connection lost');
                }
            };

            // Set remote offer and create answer
            await pc.setRemoteDescription(new RTCSessionDescription({ type: 'offer', sdp: sdp }));
            const answer = await pc.createAnswer();
            await pc.setLocalDescription(answer);

            ws.send(JSON.stringify({
                type: 'answer',
                sdp: answer.sdp
            }));
        }
    })();
    </script>
</body>
</html>`;
}
