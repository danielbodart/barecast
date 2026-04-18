export { SignalingRoom } from "./room.ts";

const viewPattern = new URLPattern({ pathname: "/room/:id/view" });
const terminalPattern = new URLPattern({ pathname: "/room/:id/terminal" });
const wsPattern = new URLPattern({ pathname: "/room/:id/ws" });
const roomPattern = new URLPattern({ pathname: "/room/:id" });

export default {
    async fetch(request: Request, env: Env): Promise<Response> {
        const url = request.url;

        // WebSocket signaling — route to Durable Object
        const wsMatch = wsPattern.exec(url);
        if (wsMatch) {
            const roomId = wsMatch.pathname.groups.id!;
            const id = env.ROOMS.idFromName(roomId);
            const room = env.ROOMS.get(id);
            return room.fetch(request);
        }

        // Terminal viewer — serve terminal.html for /room/:id/terminal
        if (terminalPattern.exec(url)) {
            return env.ASSETS.fetch(new Request(new URL("/terminal", url), request));
        }

        // Screen viewer pop-out — serve room.html for /room/:id/view
        if (viewPattern.exec(url)) {
            return env.ASSETS.fetch(new Request(new URL("/room", url), request));
        }

        // Room hub — serve hub.html for /room/:id
        if (roomPattern.exec(url)) {
            return env.ASSETS.fetch(new Request(new URL("/hub", url), request));
        }

        return env.ASSETS.fetch(request);
    },
};
