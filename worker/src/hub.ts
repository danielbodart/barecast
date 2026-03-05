/**
 * Hub page — room landing page that shows active shares and opens pop-out windows.
 * Connects to the DO as a lobby viewer (no share_id) to receive shares-list updates.
 */

interface ShareInfo {
    shareId: string;
    kind: string;
    title: string;
    meta: Record<string, unknown>;
    popout: Window | null;
}

// Extract room ID from pathname: /room/:id
const pattern = new URLPattern({ pathname: "/room/:id" });
const pathMatch = pattern.exec(window.location.href);
const roomId = pathMatch?.pathname.groups.id ?? null;

if (!roomId) {
    window.location.href = "/";
} else {
    const shares = new Map<string, ShareInfo>();
    const grid = document.getElementById("share-grid")!;
    const emptyState = document.getElementById("empty-state")!;
    const roomName = document.getElementById("room-name")!;

    const dollar = document.createElement("span");
    dollar.className = "prompt-dollar";
    dollar.textContent = "$";
    const roomSpan = document.createElement("span");
    roomSpan.className = "prompt-room";
    roomSpan.textContent = roomId;
    roomName.append(dollar, " zerocast room ", roomSpan);

    // BroadcastChannel for pop-out window sync
    const bc = new BroadcastChannel(`zerocast-room-${roomId}`);
    bc.onmessage = (e) => {
        if (e.data.type === "share-opened") {
            const card = document.getElementById(`card-${e.data.shareId}`);
            card?.classList.add("viewing");
        } else if (e.data.type === "share-closed") {
            const card = document.getElementById(`card-${e.data.shareId}`);
            card?.classList.remove("viewing");
        }
    };

    // Poll popout.closed as fallback (beforeunload doesn't always fire)
    setInterval(() => {
        for (const [shareId, info] of shares) {
            if (info.popout && info.popout.closed) {
                info.popout = null;
                const card = document.getElementById(`card-${shareId}`);
                card?.classList.remove("viewing");
            }
        }
    }, 1000);

    // WebSocket connection (lobby viewer)
    let ws: WebSocket | null = null;
    let reconnectDelay = 1000;
    let reconnectTimer: ReturnType<typeof setTimeout> | null = null;

    function connect() {
        if (reconnectTimer) {
            clearTimeout(reconnectTimer);
            reconnectTimer = null;
        }

        const wsProto = location.protocol === "https:" ? "wss:" : "ws:";
        const peerId = Array.from(crypto.getRandomValues(new Uint8Array(8)))
            .map((b) => b.toString(16).padStart(2, "0"))
            .join("");

        ws = new WebSocket(
            `${wsProto}//${location.host}/room/${roomId}/ws?role=viewer&peer_id=${peerId}`
        );

        ws.onopen = () => {
            reconnectDelay = 1000;
        };

        ws.onclose = () => {
            scheduleReconnect();
        };

        ws.onerror = () => {
            /* onclose fires after */
        };

        ws.onmessage = (event) => {
            const msg = JSON.parse(event.data);

            if (msg.type === "shares-list") {
                reconcileShares(msg.shares as Record<string, unknown>[]);
            }
            // Ignore turn-credentials, offer, ice etc — hub doesn't do WebRTC
        };
    }

    function scheduleReconnect() {
        reconnectTimer = setTimeout(() => {
            reconnectTimer = null;
            connect();
        }, reconnectDelay);
        reconnectDelay = Math.min(reconnectDelay * 2, 30000);
    }

    function reconcileShares(incoming: Record<string, unknown>[]) {
        const incomingIds = new Set(incoming.map((s) => s.share_id as string));

        for (const [shareId] of shares) {
            if (!incomingIds.has(shareId)) {
                removeShare(shareId);
            }
        }

        for (const s of incoming) {
            const shareId = s.share_id as string;
            const kind = (s.share_type as string) ?? "screen";
            const title = (s.title as string) ?? "";
            const meta = { ...s };
            delete meta.share_id;
            delete meta.share_type;
            delete meta.title;

            if (!shares.has(shareId)) {
                addShare(shareId, kind, title, meta);
            } else {
                updateShare(shareId, title, meta);
            }
        }

        updateEmptyState();
    }

    function addShare(shareId: string, kind: string, title: string, meta: Record<string, unknown>) {
        shares.set(shareId, { shareId, kind, title, meta, popout: null });
        renderCard(shareId, kind, title, meta);
    }

    function updateShare(shareId: string, title: string, meta: Record<string, unknown>) {
        const info = shares.get(shareId);
        if (!info) return;
        info.title = title;
        info.meta = meta;

        const titleEl = document.querySelector(`#card-${shareId} .titlebar-text`) as HTMLElement | null;
        if (titleEl) titleEl.textContent = title || (info.kind === "terminal" ? "Terminal" : "Screen");

        updateCardStats(shareId, info.kind, meta);
    }

    function removeShare(shareId: string) {
        shares.delete(shareId);
        const card = document.getElementById(`card-${shareId}`);
        card?.remove();
    }

    function renderCard(shareId: string, kind: string, title: string, meta: Record<string, unknown>) {
        const card = document.createElement("div");
        card.className = "card";
        card.id = `card-${shareId}`;

        // Title bar
        const titlebar = document.createElement("div");
        titlebar.className = "card-titlebar";

        const icon = document.createElement("span");
        icon.className = "titlebar-icon";
        icon.textContent = kind === "terminal" ? ">_" : "\u25a1";

        const liveDot = document.createElement("span");
        liveDot.className = "live-dot";

        const titleText = document.createElement("span");
        titleText.className = "titlebar-text";
        titleText.textContent = title || (kind === "terminal" ? "Terminal" : "Screen");

        const protocol = document.createElement("span");
        protocol.className = "titlebar-protocol";
        protocol.textContent = kind === "terminal" ? "PTY" : "AV1";

        const badge = document.createElement("span");
        badge.className = "titlebar-badge";
        badge.textContent = "viewing";

        titlebar.append(icon, liveDot, titleText, protocol, badge);

        const body = document.createElement("div");
        body.className = "card-body";
        appendStats(body, kind, meta);

        card.append(titlebar, body);
        card.addEventListener("click", () => openShare(shareId));
        grid.appendChild(card);
    }

    function updateCardStats(shareId: string, kind: string, meta: Record<string, unknown>) {
        const body = document.querySelector(`#card-${shareId} .card-body`) as HTMLElement | null;
        if (!body) return;
        body.replaceChildren();
        appendStats(body, kind, meta);
    }

    function appendStats(container: HTMLElement, kind: string, meta: Record<string, unknown>) {
        const stats: [string, string][] = kind === "screen"
            ? [
                ["res", formatRes(meta)],
                ["fps", String(meta.fps ?? "\u2014")],
                ["rate", formatBitrate(meta.bitrate as number)],
                ["eyes", String(meta.viewers ?? 0)],
            ]
            : [
                ["size", formatTermSize(meta)],
                ["rate", formatBytesPerSec(meta.bytes_per_sec as number)],
                ["eyes", String(meta.viewers ?? 0)],
            ];

        for (const [key, value] of stats) {
            const line = document.createElement("div");
            line.className = "line";

            const keyEl = document.createElement("span");
            keyEl.className = "line-key";
            keyEl.textContent = key;

            const valEl = document.createElement("span");
            valEl.className = "line-val";
            valEl.textContent = value;

            line.append(keyEl, valEl);
            container.appendChild(line);
        }
    }

    function formatRes(meta: Record<string, unknown>): string {
        return (meta.res as string) ?? "\u2014";
    }

    function formatTermSize(meta: Record<string, unknown>): string {
        const cols = meta.cols as number | undefined;
        const rows = meta.rows as number | undefined;
        if (cols && rows) return `${cols}\u00d7${rows}`;
        return "\u2014";
    }

    function formatBitrate(bps: number | undefined): string {
        if (!bps || bps === 0) return "\u2014";
        if (bps >= 1_000_000) return `${(bps / 1_000_000).toFixed(1)} Mbps`;
        if (bps >= 1_000) return `${(bps / 1_000).toFixed(0)} Kbps`;
        return `${bps} bps`;
    }

    function formatBytesPerSec(bps: number | undefined): string {
        if (!bps || bps === 0) return "\u2014";
        if (bps >= 1_000_000) return `${(bps / 1_000_000).toFixed(1)} MB/s`;
        if (bps >= 1_000) return `${(bps / 1_000).toFixed(1)} KB/s`;
        return `${bps} B/s`;
    }

    function openShare(shareId: string) {
        const info = shares.get(shareId);
        if (!info) return;

        // If already open and not closed, focus it
        if (info.popout && !info.popout.closed) {
            info.popout.focus();
            return;
        }

        const path = info.kind === "terminal"
            ? `/room/${roomId}/terminal?share=${shareId}`
            : `/room/${roomId}/view?share=${shareId}`;

        const w = window.open(
            path,
            `zerocast-${shareId}`,
            "width=1280,height=720,menubar=no,toolbar=no,location=no"
        );
        if (w) {
            info.popout = w;
            const card = document.getElementById(`card-${shareId}`);
            card?.classList.add("viewing");
        }
    }

    function updateEmptyState() {
        if (shares.size === 0) {
            emptyState.style.display = "block";
        } else {
            emptyState.style.display = "none";
        }
    }

    connect();
}

// Service worker registration
if ("serviceWorker" in navigator) {
    navigator.serviceWorker.register("/sw.js").catch(() => {});
}
