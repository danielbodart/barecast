let deferredPrompt: BeforeInstallPromptEvent | null = null;
let gotInstallPrompt = false;
const btn = document.getElementById("install-btn") as HTMLButtonElement;
const installNote = document.getElementById("install-note") as HTMLElement;
const roomInput = document.getElementById("room-input") as HTMLElement;
const roomField = document.getElementById("room-field") as HTMLInputElement;
const openInAppHint = document.getElementById("open-in-app-hint") as HTMLElement;

interface BeforeInstallPromptEvent extends Event {
    prompt(): Promise<void>;
    userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
}

const isStandalone = window.matchMedia("(display-mode: standalone)").matches;

function showRoomInput() {
    btn.hidden = true;
    installNote.hidden = true;
    openInAppHint.hidden = true;
    roomInput.hidden = false;
    roomField.focus();
}

function showInstalledHint() {
    btn.hidden = true;
    installNote.hidden = true;
    openInAppHint.hidden = false;
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
    gotInstallPrompt = true;
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

// Detect display mode transitions (e.g. user clicks "Open in app")
const standaloneQuery = window.matchMedia("(display-mode: standalone)");
standaloneQuery.addEventListener("change", (e) => {
    if (e.matches) showRoomInput();
});

// If already installed as PWA (standalone mode), show room input directly
if (isStandalone) {
    showRoomInput();
} else {
    // If beforeinstallprompt hasn't fired after 1.5s, the PWA is likely
    // already installed — show a hint pointing to Chrome's "Open in app" button
    setTimeout(() => {
        if (!gotInstallPrompt && !isStandalone) {
            showInstalledHint();
        }
    }, 500);
}

// Service worker registration
if ("serviceWorker" in navigator) {
    navigator.serviceWorker.register("/sw.js").catch(() => {});
}
