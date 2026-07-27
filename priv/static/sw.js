// Minimal service worker: present so the app is INSTALLABLE (Chrome/desktop
// install, standalone launch), but deliberately network-only — this is a LIVE
// LiveView app, so caching HTML/assets would serve stale UI and break real-time
// updates. Hashed /assets/* already cache via HTTP headers; nothing to add here.
self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()))
// A fetch listener is required for installability on some engines; pass through.
self.addEventListener("fetch", () => {})

// Web Push: a question was asked — show it; tapping opens the Reviewer slide
// for that exact card (the payload's url). See Loopyard.WebPush.
self.addEventListener("push", (event) => {
  let data = {}
  try { data = event.data ? event.data.json() : {} } catch (_) {}
  event.waitUntil(
    self.registration.showNotification(data.title || "Loopyard", {
      body: data.body || "",
      icon: "/icons/icon-192.png",
      badge: "/icons/icon-192.png",
      tag: data.tag || undefined,
      data: { url: data.url || "/review" },
    })
  )
})

self.addEventListener("notificationclick", (event) => {
  event.notification.close()
  const url = (event.notification.data && event.notification.data.url) || "/review"
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
      for (const c of list) {
        if ("focus" in c) {
          c.navigate(url)
          return c.focus()
        }
      }
      return self.clients.openWindow(url)
    })
  )
})
