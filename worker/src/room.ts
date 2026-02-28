// @ts-ignore
import { DurableObject } from "cloudflare:workers";

/**
 * SignalingRoom — one Durable Object per room.
 *
 * Per-peer routing: each WebSocket is tagged with "role:peerId" (e.g.,
 * "sharer:abc123" or "viewer:def456"). Sharer→viewer messages include a "to"
 * field for routing. Viewer→sharer messages get a "from" field stamped by the DO.
 *
 * Uses the WebSocket Hibernation API — the DO sleeps when signaling is idle.
 */
export class SignalingRoom extends DurableObject<Env> {
    async fetch(request: Request): Promise<Response> {
        const upgrade = request.headers.get("Upgrade");
        if (upgrade !== "websocket") {
            return new Response("Expected WebSocket upgrade", { status: 426 });
        }

        const url = new URL(request.url);
        const role = url.searchParams.get("role") || "viewer";
        const peerId =
            url.searchParams.get("peer_id") ||
            crypto.randomUUID().replace(/-/g, "").slice(0, 16);

        const pair = new WebSocketPair();
        const [client, server] = Object.values(pair);

        // Close any existing socket with the same tag (fast reconnect dedup)
        const tag = `${role}:${peerId}`;
        for (const existing of this.ctx.getWebSockets()) {
            if (this.getTag(existing) === tag) {
                existing.close(1001, "reconnected");
            }
        }

        this.ctx.acceptWebSocket(server, [tag]);

        if (role === "viewer") {
            // Notify the sharer about the new viewer
            this.safeSendToSharer(
                JSON.stringify({ type: "viewer-joined", peer_id: peerId })
            );
        } else if (role === "sharer") {
            // Notify the new sharer about all existing viewers
            for (const ws of this.ctx.getWebSockets()) {
                const t = this.getTag(ws);
                if (t && t.startsWith("viewer:") && ws !== server) {
                    const viewerPeerId = t.slice(7);
                    server.send(
                        JSON.stringify({
                            type: "viewer-joined",
                            peer_id: viewerPeerId,
                        })
                    );
                }
            }
        }

        return new Response(null, { status: 101, webSocket: client });
    }

    async webSocketMessage(
        ws: WebSocket,
        message: string | ArrayBuffer
    ): Promise<void> {
        if (typeof message !== "string") return;

        const tag = this.getTag(ws);
        if (!tag) return;

        const role = tag.split(":")[0];
        const senderId = tag.split(":")[1];

        if (role === "sharer") {
            // Sharer → specific viewer: route by "to" field
            const msg = JSON.parse(message) as Record<string, unknown>;
            const targetId = msg.to as string;
            if (!targetId) return;

            // Strip "to" before forwarding
            delete msg.to;
            const payload = JSON.stringify(msg);

            for (const sock of this.ctx.getWebSockets()) {
                const t = this.getTag(sock);
                if (
                    t === `viewer:${targetId}` &&
                    sock.readyState === WebSocket.OPEN
                ) {
                    sock.send(payload);
                    return;
                }
            }
        } else {
            // Viewer → sharer: stamp "from" with sender's peer ID
            const msg = JSON.parse(message) as Record<string, unknown>;
            msg.from = senderId;
            this.safeSendToSharer(JSON.stringify(msg));
        }
    }

    async webSocketClose(ws: WebSocket): Promise<void> {
        const tag = this.getTag(ws);
        if (!tag) return;

        const role = tag.split(":")[0];
        const peerId = tag.split(":")[1];

        if (role === "viewer") {
            // Notify sharer that this viewer left
            this.safeSendToSharer(
                JSON.stringify({ type: "viewer-left", peer_id: peerId })
            );
        } else if (role === "sharer") {
            // Notify all viewers that sharer left
            for (const sock of this.ctx.getWebSockets()) {
                const t = this.getTag(sock);
                if (
                    t &&
                    t.startsWith("viewer:") &&
                    sock.readyState === WebSocket.OPEN
                ) {
                    sock.send(JSON.stringify({ type: "sharer-left" }));
                }
            }
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────

    private getTag(ws: WebSocket): string | undefined {
        const tags = this.ctx.getTags(ws);
        return tags[0];
    }

    private safeSendToSharer(message: string): void {
        for (const sock of this.ctx.getWebSockets()) {
            const tag = this.getTag(sock);
            if (
                tag &&
                tag.startsWith("sharer:") &&
                sock.readyState === WebSocket.OPEN
            ) {
                sock.send(message);
                return;
            }
        }
    }
}
