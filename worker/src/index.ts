export { SignalingRoom } from "./room.ts";

export default {
    async fetch(request: Request, env: Env): Promise<Response> {
        const url = new URL(request.url);

        // WebSocket signaling — route to Durable Object
        const match = url.pathname.match(/^\/room\/([a-zA-Z0-9_-]+)\/ws$/);
        if (match) {
            const roomId = match[1];
            const id = env.ROOMS.idFromName(roomId);
            const room = env.ROOMS.get(id);
            return room.fetch(request);
        }

        return env.ASSETS.fetch(request);
    },
};
