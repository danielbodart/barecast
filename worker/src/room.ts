// @ts-ignore
import { DurableObject } from "cloudflare:workers";

/**
 * SignalingRoom — one Durable Object per room.
 *
 * Holds WebSocket connections for sharer + viewer(s). Routes signaling messages
 * (SDP offers/answers, ICE candidates) between peers. Uses the WebSocket
 * Hibernation API so the DO sleeps when signaling is idle (after WebRTC connects).
 *
 * Rooms auto-create on first WebSocket connection. Room IDs are client-generated
 * (8-byte random hex → 16 chars) — no server round-trip needed to create a room.
 */
export class SignalingRoom extends DurableObject<Env> {
    async fetch(request: Request): Promise<Response> {
        const upgrade = request.headers.get("Upgrade");
        if (upgrade !== "websocket") {
            return new Response("Expected WebSocket upgrade", { status: 426 });
        }

        // Extract role from query param
        const url = new URL(request.url);
        const role = url.searchParams.get("role") || "unknown";

        const pair = new WebSocketPair();
        const [client, server] = Object.values(pair);

        // Tag the WebSocket with its role for identification
        this.ctx.acceptWebSocket(server, [role]);

        // Notify existing peers about the new connection
        const sockets = this.ctx.getWebSockets();
        for (const socket of sockets) {
            if (socket !== server) {
                socket.send(JSON.stringify({ type: "peer-joined", role }));
            }
        }

        return new Response(null, { status: 101, webSocket: client });
    }

    async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
        // Route message to all other connected WebSockets in this room
        const sockets = this.ctx.getWebSockets();
        for (const socket of sockets) {
            if (socket !== ws) {
                socket.send(message);
            }
        }
    }

    async webSocketClose(ws: WebSocket, code: number, reason: string, wasClean: boolean): Promise<void> {
        // Notify remaining peers that someone disconnected
        const sockets = this.ctx.getWebSockets();
        for (const socket of sockets) {
            if (socket !== ws) {
                socket.send(JSON.stringify({ type: "peer-disconnected" }));
            }
        }
    }
}
