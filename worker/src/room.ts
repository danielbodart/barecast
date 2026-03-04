// @ts-ignore
import { DurableObject } from "cloudflare:workers";

/**
 * SignalingRoom — one Durable Object per room.
 *
 * Supports multiple sharers per room. Each WebSocket is tagged:
 *   sharer:{shareId}:{peerId}  + secondary tag "sharetype:{type}"
 *   viewer:{peerId}:{shareId}  (subscribed to a specific share)
 *   viewer:{peerId}:lobby      (hub page, receives shares-list only)
 *
 * Uses the WebSocket Hibernation API — the DO sleeps when signaling is idle.
 */
export class SignalingRoom extends DurableObject<Env> {
    constructor(ctx: DurableObjectState, env: Env) {
        super(ctx, env);
        this.ctx.setWebSocketAutoResponse(
            new WebSocketRequestResponsePair("ping", "pong")
        );
    }

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

        if (role === "sharer") {
            await this.acceptSharer(server, peerId, url);
        } else {
            await this.acceptViewer(server, peerId, url);
        }

        return new Response(null, { status: 101, webSocket: client });
    }

    private async acceptSharer(
        server: WebSocket,
        peerId: string,
        url: URL
    ): Promise<void> {
        const shareId = url.searchParams.get("share_id") || peerId;
        const shareType = url.searchParams.get("share_type") || "screen";

        // Dedup: close existing socket with same shareId (reconnect)
        for (const existing of this.ctx.getWebSockets()) {
            const parsed = this.parseTag(existing);
            if (parsed?.role === "sharer" && parsed.shareId === shareId) {
                existing.close(1001, "reconnected");
            }
        }

        this.ctx.acceptWebSocket(server, [
            `sharer:${shareId}:${peerId}`,
            `sharetype:${shareType}`,
        ]);

        // TURN credentials
        const creds = await this.generateTurnCredentials();
        if (creds) {
            server.send(
                JSON.stringify({
                    type: "turn-credentials",
                    username: creds.username,
                    credential: creds.credential,
                })
            );
        }

        // Notify already-subscribed viewers (reconnect scenario)
        for (const ws of this.ctx.getWebSockets()) {
            const parsed = this.parseTag(ws);
            if (
                parsed?.role === "viewer" &&
                parsed.shareId === shareId &&
                ws !== server &&
                ws.readyState === WebSocket.OPEN
            ) {
                server.send(
                    JSON.stringify({
                        type: "viewer-joined",
                        peer_id: parsed.peerId,
                    })
                );
            }
        }

        // Broadcast updated shares-list to all viewers
        this.broadcastSharesList();
    }

    private async acceptViewer(
        server: WebSocket,
        peerId: string,
        url: URL
    ): Promise<void> {
        const shareId = url.searchParams.get("share_id") || "lobby";

        // Dedup: close existing socket with same peerId
        for (const existing of this.ctx.getWebSockets()) {
            const parsed = this.parseTag(existing);
            if (
                parsed?.role === "viewer" &&
                parsed.peerId === peerId
            ) {
                existing.close(1001, "reconnected");
            }
        }

        this.ctx.acceptWebSocket(server, [
            `viewer:${peerId}:${shareId}`,
        ]);

        // TURN credentials (useful for subscribed viewers)
        const creds = await this.generateTurnCredentials();
        if (creds) {
            server.send(
                JSON.stringify({
                    type: "turn-credentials",
                    username: creds.username,
                    credential: creds.credential,
                })
            );
        }

        // Send current shares list
        const shares = this.buildSharesList();
        server.send(JSON.stringify({ type: "shares-list", shares }));

        // If subscribed to a specific share, notify that sharer
        if (shareId !== "lobby") {
            const sharerSock = this.getSharerSocket(shareId);
            if (sharerSock && sharerSock.readyState === WebSocket.OPEN) {
                sharerSock.send(
                    JSON.stringify({
                        type: "viewer-joined",
                        peer_id: peerId,
                    })
                );
            }
        }
    }

    async webSocketMessage(
        ws: WebSocket,
        message: string | ArrayBuffer
    ): Promise<void> {
        if (typeof message !== "string") return;

        const parsed = this.parseTag(ws);
        if (!parsed) return;

        if (parsed.role === "sharer") {
            // Sharer → specific viewer: route by "to" field
            const msg = JSON.parse(message) as Record<string, unknown>;
            const targetViewerPeerId = msg.to as string;
            if (!targetViewerPeerId) return;

            delete msg.to;
            const payload = JSON.stringify(msg);

            // Find the viewer by peerId (any subscription)
            for (const sock of this.ctx.getWebSockets()) {
                const tp = this.parseTag(sock);
                if (
                    tp?.role === "viewer" &&
                    tp.peerId === targetViewerPeerId &&
                    sock.readyState === WebSocket.OPEN
                ) {
                    sock.send(payload);
                    return;
                }
            }
        } else {
            // Viewer → sharer: stamp "from", route to the subscribed share
            if (parsed.shareId === "lobby") return; // lobby viewers don't send signaling

            const msg = JSON.parse(message) as Record<string, unknown>;
            msg.from = parsed.peerId;

            const sharerSock = this.getSharerSocket(parsed.shareId);
            if (sharerSock && sharerSock.readyState === WebSocket.OPEN) {
                sharerSock.send(JSON.stringify(msg));
            }
        }
    }

    async webSocketClose(ws: WebSocket): Promise<void> {
        const parsed = this.parseTag(ws);
        if (!parsed) return;

        if (parsed.role === "viewer") {
            if (parsed.shareId === "lobby") return;
            // Notify the specific sharer that this viewer left
            const sharerSock = this.getSharerSocket(parsed.shareId);
            if (sharerSock && sharerSock.readyState === WebSocket.OPEN) {
                sharerSock.send(
                    JSON.stringify({
                        type: "viewer-left",
                        peer_id: parsed.peerId,
                    })
                );
            }
        } else if (parsed.role === "sharer") {
            const shareId = parsed.shareId;

            // Notify subscribed viewers that this share ended
            for (const sock of this.ctx.getWebSockets()) {
                const tp = this.parseTag(sock);
                if (
                    tp?.role === "viewer" &&
                    tp.shareId === shareId &&
                    sock !== ws &&
                    sock.readyState === WebSocket.OPEN
                ) {
                    sock.send(
                        JSON.stringify({
                            type: "sharer-left",
                            share_id: shareId,
                        })
                    );
                }
            }

            // Broadcast updated shares-list to all viewers
            this.broadcastSharesList(ws);
        }
    }

    async webSocketError(ws: WebSocket): Promise<void> {
        await this.webSocketClose(ws);
    }

    // ── Tag parsing ──────────────────────────────────────────────────

    private parseTag(
        ws: WebSocket
    ): { role: "sharer"; shareId: string; peerId: string } |
       { role: "viewer"; peerId: string; shareId: string } |
       null {
        const tags = this.ctx.getTags(ws);
        if (!tags[0]) return null;
        const parts = tags[0].split(":");
        if (parts.length < 3) return null;

        if (parts[0] === "sharer") {
            return { role: "sharer", shareId: parts[1], peerId: parts[2] };
        } else if (parts[0] === "viewer") {
            return { role: "viewer", peerId: parts[1], shareId: parts[2] };
        }
        return null;
    }

    // ── Routing helpers ──────────────────────────────────────────────

    private getSharerSocket(shareId: string): WebSocket | null {
        for (const ws of this.ctx.getWebSockets()) {
            const parsed = this.parseTag(ws);
            if (
                parsed?.role === "sharer" &&
                parsed.shareId === shareId &&
                ws.readyState === WebSocket.OPEN
            ) {
                return ws;
            }
        }
        return null;
    }

    private buildSharesList(): { share_id: string; share_type: string }[] {
        const shares: { share_id: string; share_type: string }[] = [];
        for (const ws of this.ctx.getWebSockets()) {
            if (ws.readyState !== WebSocket.OPEN) continue;
            const tags = this.ctx.getTags(ws);
            if (!tags[0]?.startsWith("sharer:")) continue;
            const parsed = this.parseTag(ws);
            if (!parsed || parsed.role !== "sharer") continue;
            const typeTag = tags.find((t) => t.startsWith("sharetype:"));
            const shareType = typeTag ? typeTag.slice(10) : "screen";
            shares.push({ share_id: parsed.shareId, share_type: shareType });
        }
        return shares;
    }

    private broadcastSharesList(exclude?: WebSocket): void {
        const shares = this.buildSharesList();
        const msg = JSON.stringify({ type: "shares-list", shares });
        for (const sock of this.ctx.getWebSockets()) {
            const parsed = this.parseTag(sock);
            if (
                parsed?.role === "viewer" &&
                sock !== exclude &&
                sock.readyState === WebSocket.OPEN
            ) {
                sock.send(msg);
            }
        }
    }

    // ── TURN credentials ─────────────────────────────────────────────

    private async generateTurnCredentials(): Promise<{
        username: string;
        credential: string;
    } | null> {
        const keyId = this.env.TURN_KEY_ID;
        const apiToken = this.env.TURN_KEY_API_TOKEN;
        if (!keyId || !apiToken) {
            console.log(
                "TURN: missing creds",
                `keyId.len=${keyId?.length}`,
                `apiToken.len=${apiToken?.length}`
            );
            return null;
        }

        try {
            const resp = await fetch(
                `https://rtc.live.cloudflare.com/v1/turn/keys/${keyId}/credentials/generate-ice-servers`,
                {
                    method: "POST",
                    headers: {
                        Authorization: `Bearer ${apiToken}`,
                        "Content-Type": "application/json",
                    },
                    body: JSON.stringify({ ttl: 86400 }),
                }
            );
            if (!resp.ok) {
                console.log(`TURN: API returned ${resp.status}`);
                return null;
            }

            const data = (await resp.json()) as {
                iceServers?: { username?: string; credential?: string }[];
            };
            const turn = data.iceServers?.find((s) => s.username);
            if (!turn?.username || !turn?.credential) return null;

            console.log("TURN: credentials generated");
            return { username: turn.username, credential: turn.credential };
        } catch (e) {
            console.log(`TURN: error: ${e}`);
            return null;
        }
    }
}
