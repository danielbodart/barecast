/**
 * Hub page — room landing page that shows active shares and opens pop-out windows.
 * Connects to the DO as a lobby viewer (no share_id) to receive shares-list updates.
 */

interface ShareInfo {
    shareId: string;
    kind: string;
    title: string;
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

    roomName.textContent = roomId;

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
                reconcileShares(msg.shares as { share_id: string; share_type: string }[]);
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

    function reconcileShares(incoming: { share_id: string; share_type: string; title?: string }[]) {
        const incomingIds = new Set(incoming.map((s) => s.share_id));

        // Remove shares that are no longer active
        for (const [shareId] of shares) {
            if (!incomingIds.has(shareId)) {
                removeShare(shareId);
            }
        }

        // Add or update shares
        for (const s of incoming) {
            const title = s.title ?? "";
            if (!shares.has(s.share_id)) {
                addShare(s.share_id, s.share_type, title);
            } else {
                updateShareTitle(s.share_id, title);
            }
        }

        updateEmptyState();
    }

    function addShare(shareId: string, kind: string, title: string) {
        shares.set(shareId, { shareId, kind, title, popout: null });
        renderCard(shareId, kind, title);
    }

    function updateShareTitle(shareId: string, title: string) {
        const info = shares.get(shareId);
        if (!info || info.title === title) return;
        info.title = title;
        const el = document.querySelector(`#card-${shareId} .share-card-title`);
        if (el) {
            (el as HTMLElement).textContent = title;
            (el as HTMLElement).style.display = title ? "block" : "none";
        }
    }

    function removeShare(shareId: string) {
        shares.delete(shareId);
        const card = document.getElementById(`card-${shareId}`);
        card?.remove();
    }

    function renderCard(shareId: string, kind: string, title: string) {
        const card = document.createElement("div");
        card.className = "share-card";
        card.id = `card-${shareId}`;

        const kindEl = document.createElement("div");
        kindEl.className = "share-card-kind";
        kindEl.textContent = kind;

        const label = document.createElement("div");
        label.className = "share-card-label";
        label.textContent = kind === "terminal" ? "Terminal" : "Screen";

        const titleEl = document.createElement("div");
        titleEl.className = "share-card-title";
        titleEl.textContent = title;
        titleEl.style.display = title ? "block" : "none";

        const badge = document.createElement("div");
        badge.className = "share-card-badge";
        badge.textContent = "viewing";

        card.appendChild(kindEl);
        card.appendChild(label);
        card.appendChild(titleEl);
        card.appendChild(badge);

        card.addEventListener("click", () => openShare(shareId));
        grid.appendChild(card);
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
