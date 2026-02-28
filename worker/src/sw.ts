/// <reference lib="webworker" />
declare const self: ServiceWorkerGlobalScope;

self.addEventListener("fetch", (event) => {
    if (event.request.headers.get("Upgrade") === "websocket") return;
    event.respondWith(fetch(event.request));
});
