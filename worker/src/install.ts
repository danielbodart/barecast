let deferredPrompt: BeforeInstallPromptEvent | null = null;
const btn = document.getElementById("install-btn") as HTMLButtonElement;
const installNote = document.getElementById("install-note") as HTMLElement;
const roomInput = document.getElementById("room-input") as HTMLElement;
const roomField = document.getElementById("room-field") as HTMLInputElement;

interface BeforeInstallPromptEvent extends Event {
    prompt(): Promise<void>;
    userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
}

function showRoomInput() {
    btn.hidden = true;
    installNote.hidden = true;
    roomInput.hidden = false;
    roomField.focus();
}

function extractRoomId(input: string): string | null {
    const trimmed = input.trim();
    if (!trimmed) return null;

    // If it contains /room/, extract the ID after it
    const roomIdx = trimmed.indexOf("/room/");
    if (roomIdx !== -1) {
        const id = trimmed.slice(roomIdx + 6).split(/[?#\/]/)[0];
        return id || null;
    }

    // Otherwise treat the whole input as a room ID
    return trimmed;
}

// Navigate to room on Enter
roomField.addEventListener("keydown", (e) => {
    if (e.key !== "Enter") return;
    const id = extractRoomId(roomField.value);
    if (id) {
        window.location.href = `/room/${encodeURIComponent(id)}`;
    }
});

// Capture the install prompt event
window.addEventListener("beforeinstallprompt", (e) => {
    e.preventDefault();
    deferredPrompt = e as BeforeInstallPromptEvent;
});

btn.addEventListener("click", async () => {
    if (!deferredPrompt) {
        showRoomInput();
        return;
    }
    const prompt = deferredPrompt;
    deferredPrompt = null;
    btn.disabled = true;
    prompt.prompt();
    const { outcome } = await prompt.userChoice;
    if (outcome === "accepted") {
        showRoomInput();
    } else {
        btn.disabled = false;
    }
});

// If already installed as PWA (standalone mode), show room input directly
if (window.matchMedia("(display-mode: standalone)").matches) {
    showRoomInput();
}

// Service worker registration
if ("serviceWorker" in navigator) {
    navigator.serviceWorker.register("/sw.js").catch(() => {});
}
