// Minimal service worker: present so the app is INSTALLABLE (Chrome/desktop
// install, standalone launch), but deliberately network-only — this is a LIVE
// LiveView app, so caching HTML/assets would serve stale UI and break real-time
// updates. Hashed /assets/* already cache via HTTP headers; nothing to add here.
self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()))
// A fetch listener is required for installability on some engines; pass through.
self.addEventListener("fetch", () => {})
