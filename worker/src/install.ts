let deferredPrompt: BeforeInstallPromptEvent | null = null;
const btn = document.getElementById("install-btn") as HTMLButtonElement;
const note = document.querySelector(".install-note") as HTMLElement;

interface BeforeInstallPromptEvent extends Event {
    prompt(): Promise<void>;
    userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
}

// Capture the install prompt event
window.addEventListener("beforeinstallprompt", (e) => {
    e.preventDefault();
    deferredPrompt = e as BeforeInstallPromptEvent;
    btn.disabled = false;
    btn.textContent = "Install barecast";
    note.textContent = "";
});

btn.addEventListener("click", async () => {
    if (!deferredPrompt) return;
    const prompt = deferredPrompt;
    deferredPrompt = null;
    btn.disabled = true;
    prompt.prompt();
    const { outcome } = await prompt.userChoice;
    if (outcome === "accepted") {
        btn.textContent = "Installed";
    } else {
        btn.disabled = false;
    }
});

// If already installed as PWA (standalone mode)
if (window.matchMedia("(display-mode: standalone)").matches) {
    btn.disabled = true;
    btn.textContent = "Already installed";
    note.textContent = "Open a room link to start viewing.";
}

// Service worker registration
if ("serviceWorker" in navigator) {
    navigator.serviceWorker.register("/sw.js").catch(() => {});
}
