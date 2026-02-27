export { SignalingRoom } from "./room.ts";

export default {
    async fetch(request: Request, env: Env): Promise<Response> {
        const url = new URL(request.url);

        // Static viewer app
        if (url.pathname === "/") {
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
    <title>barecast</title>
    <style>
        body { margin: 0; background: #000; display: flex; align-items: center; justify-content: center; height: 100vh; }
        video { max-width: 100vw; max-height: 100vh; }
        #status { position: fixed; top: 16px; left: 16px; color: #666; font-family: monospace; font-size: 14px; }
    </style>
</head>
<body>
    <div id="status">Connecting...</div>
    <video id="video" autoplay playsinline></video>
    <script>
        // Viewer client — connects to signaling WebSocket, establishes WebRTC peer connection.
        // Implementation will go here once the signaling protocol is defined.
        document.getElementById('status').textContent = 'Viewer not yet implemented';
    </script>
</body>
</html>`;
}
