import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {createTerminalHook} from "./terminal"
import {createAuralHook} from "aural"

let Hooks = {}
Hooks.Terminal = createTerminalHook()
Hooks.Aural = createAuralHook()

// AmbientAudio — the ENGINE. Lives on #ambient in the root layout (outside
// {@inner_content}); the whole app runs in one live_session, so it mounts ONCE
// and the bed keeps playing across navigation. It has no visible control: the
// speaker button/panel live in the page headers (SoundControl) and drive this
// via window events, so the control can be anywhere and re-render freely while
// the audio stays put. Off by default (autoplay needs a gesture). State is
// mirrored to <html data-ambient-*> + broadcast as `ambient:changed` so a
// freshly-mounted control can sync its icon/slider.
Hooks.AmbientAudio = {
  mounted() {
    this.audio = this.el.querySelector("#ambient-el")
    const channel = this.el.dataset.channel || "activity"
    this.streamSrc = `/aural/${channel}/stream.mp3`

    const vol = parseFloat(localStorage.getItem("loopyard:ambient:vol"))
    this.audio.volume = isNaN(vol) ? 0.35 : Math.min(1, Math.max(0, vol))

    this._onToggle = () => this.toggle()
    this._onSetVol = (e) => this.setVolume(e.detail)
    this._onQuery = () => this.broadcast()
    window.addEventListener("ambient:toggle", this._onToggle)
    window.addEventListener("ambient:set-volume", this._onSetVol)
    window.addEventListener("ambient:query", this._onQuery)

    // Operator `music` tool → server pushes play/pause/volume here (via the
    // operator LiveView). We drive the engine directly; the sound pill follows
    // through the ambient:changed broadcast.
    this.handleEvent("aural_command", ({action, value}) => {
      if (action === "play") this.start().catch(() => {})
      else if (action === "pause") this.stop()
      else if (action === "volume") this.setVolume(value)
    })

    // Restore intent. Autoplay is blocked without a gesture on a fresh load, so
    // if play() rejects we just reflect "off" — a tap on the control re-arms it.
    if (localStorage.getItem("loopyard:ambient") === "on") {
      this.start().catch(() => this.broadcast())
    } else {
      this.broadcast()
    }
  },

  destroyed() {
    window.removeEventListener("ambient:toggle", this._onToggle)
    window.removeEventListener("ambient:set-volume", this._onSetVol)
    window.removeEventListener("ambient:query", this._onQuery)
  },

  start() {
    if (!this.audio.getAttribute("src")) this.audio.setAttribute("src", this.streamSrc)
    // "connecting" until the stream actually reaches the device (the `playing`
    // event) — so the control shows a transitional state instead of looking
    // dead while the MP3 buffers, and you don't tap it five more times.
    this._connecting = true
    const onPlaying = () => {
      this._connecting = false
      this.broadcast()
    }
    this.audio.addEventListener("playing", onPlaying, {once: true})

    const p = this.audio.play()
    // Reflect "on" immediately (audio.paused flips false synchronously on
    // play()), with connecting=true, so the UI responds on tap.
    localStorage.setItem("loopyard:ambient", "on")
    this.broadcast()
    return (p || Promise.resolve()).catch(() => {
      this._connecting = false
      this.audio.removeEventListener("playing", onPlaying)
      localStorage.setItem("loopyard:ambient", "off")
      this.broadcast()
    })
  },

  stop() {
    this._connecting = false
    this.audio.pause()
    localStorage.setItem("loopyard:ambient", "off")
    this.broadcast()
  },

  toggle() {
    if (this.audio.paused) this.start()
    else this.stop()
  },

  setVolume(v) {
    const vol = Math.min(1, Math.max(0, Number(v)))
    if (Number.isNaN(vol)) return
    this.audio.volume = vol
    localStorage.setItem("loopyard:ambient:vol", String(vol))
    this.broadcast()
  },

  broadcast() {
    const on = !this.audio.paused
    const connecting = on && !!this._connecting
    document.documentElement.dataset.ambientOn = on ? "1" : "0"
    window.dispatchEvent(
      new CustomEvent("ambient:changed", {detail: {on, connecting, volume: this.audio.volume}})
    )
  }
}

// SoundIcon — the header speaker. It's just a LINK to the full /sound page (no
// popover); this hook only mirrors the engine's on/off onto the icon so you can
// see at a glance whether the bed is playing. Navigating to /sound is live (same
// live_session), so the engine — and the audio — never cut.
Hooks.SoundIcon = {
  mounted() {
    this.iconOn = this.el.querySelector('[data-sound-icon="on"]')
    this.iconOff = this.el.querySelector('[data-sound-icon="off"]')
    this._onChanged = (e) => this.render(e.detail)
    window.addEventListener("ambient:changed", this._onChanged)
    this.render({on: document.documentElement.dataset.ambientOn === "1", connecting: false})
    window.dispatchEvent(new CustomEvent("ambient:query"))
  },
  destroyed() {
    window.removeEventListener("ambient:changed", this._onChanged)
  },
  render({on}) {
    if (this.iconOn) this.iconOn.classList.toggle("hidden", !on)
    if (this.iconOff) this.iconOff.classList.toggle("hidden", on)
    // A quiet static tint so you can see it's on — no pulse (that was annoying).
    this.el.classList.toggle("text-violet-600", on)
    this.el.classList.toggle("dark:text-violet-400", on)
    this.el.classList.toggle("text-zinc-400", !on)
    this.el.classList.toggle("dark:text-zinc-500", !on)
  }
}

// SoundPanel — the /sound page's ENGINE controls (on/off + volume). Commands the
// persistent AmbientAudio engine over window events and mirrors its state back;
// track picking is separate (server-side LiveView → Aural.Channel, which
// crossfades the same stream so nothing cuts).
Hooks.SoundPanel = {
  mounted() {
    this.power = this.el.querySelector("[data-sound-power]")
    this.slider = this.el.querySelector("[data-sound-volume]")
    this.iconOn = this.el.querySelector('[data-sound-icon="on"]')
    this.iconOff = this.el.querySelector('[data-sound-icon="off"]')
    this.state = this.el.querySelector("[data-sound-state]")

    this.power.addEventListener("click", () =>
      window.dispatchEvent(new CustomEvent("ambient:toggle"))
    )
    this.slider.addEventListener("input", (e) =>
      window.dispatchEvent(new CustomEvent("ambient:set-volume", {detail: parseFloat(e.target.value)}))
    )

    this._onChanged = (e) => this.render(e.detail)
    window.addEventListener("ambient:changed", this._onChanged)

    const on = document.documentElement.dataset.ambientOn === "1"
    const vol = parseFloat(localStorage.getItem("loopyard:ambient:vol"))
    this.render({on, volume: Number.isNaN(vol) ? 0.35 : vol})
    window.dispatchEvent(new CustomEvent("ambient:query"))
  },
  updated() {
    // A LiveView patch (e.g. picking a track re-renders this panel) can reset
    // the controls to their server markup — re-apply the engine's real state.
    const on = document.documentElement.dataset.ambientOn === "1"
    const vol = parseFloat(localStorage.getItem("loopyard:ambient:vol"))
    this.render({on, connecting: false, volume: Number.isNaN(vol) ? 0.35 : vol})
    window.dispatchEvent(new CustomEvent("ambient:query"))
  },
  destroyed() {
    window.removeEventListener("ambient:changed", this._onChanged)
  },
  render({on, connecting, volume}) {
    if (this.iconOn) this.iconOn.classList.toggle("hidden", !on)
    if (this.iconOff) this.iconOff.classList.toggle("hidden", on)
    if (this.state) this.state.textContent = connecting ? "Connecting…" : on ? "Playing" : "Paused"
    this.power.setAttribute("aria-pressed", on ? "true" : "false")
    this.power.classList.toggle("animate-pulse", !!connecting)
    this.power.classList.toggle("bg-violet-600", on)
    this.power.classList.toggle("text-white", on)
    this.power.classList.toggle("bg-zinc-200", !on)
    this.power.classList.toggle("dark:bg-zinc-700", !on)
    if (volume != null && document.activeElement !== this.slider) this.slider.value = volume
  }
}

// SoundPill — the compact ambient control (operator surface). Same engine
// commands as SoundPanel (toggle + volume over window events), but it lives
// inline in a header pill: the whole pill swaps to the accent class set when
// playing and grays when off, and the speaker icon flips waves↔muted. Track
// picking is a link to /sound (live nav, so the audio never cuts).
Hooks.SoundPill = {
  mounted() {
    this.root = this.el
    this.power = this.el.querySelector("[data-sound-power]")
    this.slider = this.el.querySelector("[data-sound-volume]")
    this.iconOn = this.el.querySelector('[data-sound-icon="on"]')
    this.iconOff = this.el.querySelector('[data-sound-icon="off"]')
    this.onCls = (this.root.dataset.on || "").split(" ").filter(Boolean)
    this.offCls = (this.root.dataset.off || "").split(" ").filter(Boolean)

    this.power.addEventListener("click", () =>
      window.dispatchEvent(new CustomEvent("ambient:toggle"))
    )
    this.slider.addEventListener("input", (e) =>
      window.dispatchEvent(new CustomEvent("ambient:set-volume", {detail: parseFloat(e.target.value)}))
    )

    this._onChanged = (e) => this.render(e.detail)
    window.addEventListener("ambient:changed", this._onChanged)

    const on = document.documentElement.dataset.ambientOn === "1"
    const vol = parseFloat(localStorage.getItem("loopyard:ambient:vol"))
    this.render({on, volume: Number.isNaN(vol) ? 0.35 : vol})
    window.dispatchEvent(new CustomEvent("ambient:query"))
  },
  destroyed() {
    window.removeEventListener("ambient:changed", this._onChanged)
  },
  render({on, connecting, volume}) {
    if (this.iconOn) this.iconOn.classList.toggle("hidden", !on)
    if (this.iconOff) this.iconOff.classList.toggle("hidden", on)
    // Swap the whole pill between the accent (on) and muted (off) class sets.
    this.root.classList.remove(...(on ? this.offCls : this.onCls))
    this.root.classList.add(...(on ? this.onCls : this.offCls))
    if (this.power) this.power.classList.toggle("animate-pulse", !!connecting)
    if (volume != null && this.slider && document.activeElement !== this.slider) {
      this.slider.value = volume
    }
  }
}

// ScrollBottom: lives on #chat-page (ancestor), scrolls #messages
// (descendant). Hooks on deeply nested elements (inside function
// components with phx-id) don't mount in LiveView — so the hook
// must live on the root-level element.
//
// #messages is NORMAL flow (flex-col), so position:sticky on the prompt
// band works flush (column-reverse broke it). That means the hook now owns
// scroll behavior:
//  - Tail mode: snap to bottom on mount and on every update IF the user was
//    already at the bottom (so streaming/new messages follow). If they
//    scrolled up to read, leave them be.
//  - Load-more: when they scroll near the TOP, fetch older messages. Older
//    messages prepend above the viewport; browser overflow-anchor (default)
//    keeps the visible content from jumping, and we also pin scrollTop by the
//    height delta as a belt-and-suspenders.
// StreamAppend — client-side accumulation for live streaming text (the
// in-progress assistant reply and thinking blocks). The server pushes each
// delta CHUNK (event name from data-stream-event) and this appends it as a
// text node inside [data-stream-target] — O(chunk) per update. The container
// is phx-update="ignore", so LiveView never re-ships or re-patches the
// accumulated text; the finalized message replaces the whole element. If the
// target scrolls (thinking's max-h pre), keep it tailed.
Hooks.StreamAppend = {
  mounted() {
    const target = this.el.querySelector("[data-stream-target]") || this.el
    this.handleEvent(this.el.dataset.streamEvent, ({text}) => {
      target.appendChild(document.createTextNode(text))
      if (target.scrollHeight > target.clientHeight) target.scrollTop = target.scrollHeight
    })
  }
}

// StreamMarkdown — server-side incremental markdown for the live assistant
// reply. The server (Markdown.Stream) emits COMPLETE blocks as safe HTML plus
// the current incomplete block as plain text. We append each HTML block ONCE
// into [data-stream-blocks] (insertAdjacentHTML, never re-diffed → no DOM
// thrash, no fighting LiveView's patcher — the container is phx-update="ignore")
// and mirror the small plain remainder into [data-stream-tail]. The finalized
// Message re-renders identically server-side and replaces the whole element.
Hooks.StreamMarkdown = {
  mounted() {
    const blocks = this.el.querySelector("[data-stream-blocks]")
    const tail = this.el.querySelector("[data-stream-tail]")
    this.handleEvent("stream_html", ({html, tail: tailHtml}) => {
      if (html) blocks.insertAdjacentHTML("beforeend", html)
      // Tail is server-rendered HTML for the in-progress block (small, one block)
      // — swap it in place. Balanced markdown renders; a truly-unclosed marker
      // resolves on the next delta.
      tail.innerHTML = tailHtml || ""
    })
  }
}

// PerfProbe — lightweight client-health beacon for real sessions. Samples
// worst main-thread frame gap (rAF drift ≈ typing jank), DOM node count, and
// JS heap, and pushes one compact event every 20s while the tab is visible.
// The server logs it to the EventLog, so "the UI feels slow" is diagnosable
// from /system/events (or rpc) with real numbers instead of vibes.
Hooks.PerfProbe = {
  mounted() {
    this.gap = {max: 0, over50: 0}
    let last = performance.now()
    let raf = () => {
      const now = performance.now()
      const g = now - last
      if (g > this.gap.max) this.gap.max = g
      if (g > 50) this.gap.over50++
      last = now
      this.rafId = requestAnimationFrame(raf)
    }
    this.rafId = requestAnimationFrame(raf)

    this.timer = setInterval(() => {
      if (document.hidden) { this.gap = {max: 0, over50: 0}; return }
      const sample = {
        max_gap_ms: Math.round(this.gap.max),
        gaps_over_50: this.gap.over50,
        dom: document.querySelectorAll("*").length,
        heap_mb: performance.memory ? Math.round(performance.memory.usedJSHeapSize / 1048576) : null
      }
      this.gap = {max: 0, over50: 0}
      this.pushEvent("perf_sample", sample)
    }, 20000)
  },
  destroyed() {
    clearInterval(this.timer)
    cancelAnimationFrame(this.rafId)
  }
}

Hooks.ScrollBottom = {
  mounted() {
    this._loading = false
    this._atBottom = true
    this._prevHeight = 0
    this._revealed = false
    this._bind()
    this._initialReveal()
  },

  updated() {
    this._bind()
    const el = this._el
    if (!el) return
    // First time #messages appears, reveal it (mask the scroll-into-place).
    if (!this._revealed) { this._initialReveal(); return }
    if (this._loading && this._prevHeight) {
      // Older messages just prepended at the top — keep the reading position
      // fixed by the amount the content grew.
      el.scrollTop += el.scrollHeight - this._prevHeight
      this._prevHeight = 0
    } else if (this._atBottom) {
      this._toBottom()
    }
  },

  // Hide #messages until it's scrolled to the bottom, THEN fade it in — so the
  // sticky "YOU" prompt never visibly pops from its flow position up to the
  // top. Deferred to after layout (double rAF) so the scroll lands at the true
  // bottom. No-op for content that already fits (mt-auto anchors it).
  _initialReveal() {
    const el = this._el
    if (!el || this._revealed) return
    this._revealed = true
    el.style.opacity = "0"
    requestAnimationFrame(() => requestAnimationFrame(() => {
      this._toBottom()
      el.style.transition = "opacity 100ms ease"
      el.style.opacity = "1"
    }))
  },

  // Instant jump to bottom (NO smooth animation — the animated slide-down after
  // load was the jank). Content shorter than the viewport is anchored to the
  // bottom by CSS (mt-auto), so this is a no-op there; it only matters when the
  // transcript overflows.
  _toBottom() {
    const el = this._el
    if (!el) return
    const prev = el.style.scrollBehavior
    el.style.scrollBehavior = "auto"
    el.scrollTop = el.scrollHeight
    el.style.scrollBehavior = prev
  },

  _bind() {
    const el = document.getElementById("messages")
    if (!el || el === this._el) return
    this._el = el

    el.addEventListener("scroll", () => {
      const distFromBottom = el.scrollHeight - el.clientHeight - el.scrollTop
      this._atBottom = distFromBottom < 120

      if (el.scrollTop < 300 && (el.scrollHeight - el.clientHeight) > 300 && !this._loading) {
        this._loading = true
        this._prevHeight = el.scrollHeight
        this.pushEvent("load_more", {})
        setTimeout(() => { this._loading = false; this._prevHeight = 0 }, 5000)
      }
    }, { passive: true })

    this.handleEvent("scroll_bottom", () => {
      // Only follow if you're already near the bottom — don't yank you down
      // while you're scrolled up reading. ~120px slack.
      if (this._atBottom) this._toBottom()
    })

    this.handleEvent("jump_bottom", () => {
      // "Jump to latest" — force it, regardless of current scroll position.
      this._atBottom = true
      this._toBottom()
    })
  }
}

// Auto-scroll element to bottom on every update (tail mode).
// Pauses when user scrolls up; resumes when they scroll back to bottom.
// Clipboard that also works OUTSIDE a secure context. `navigator.clipboard` is
// undefined on plain-HTTP LAN origins (e.g. http://10.0.1.129:4000), so every
// copy button silently failed there — and Loopyard is meant to be reached over
// the LAN. Use the async API when it's actually available (secure context),
// otherwise fall back to a hidden-textarea + execCommand. Always resolves.
function copyToClipboard(text) {
  if (navigator.clipboard && window.isSecureContext) {
    return navigator.clipboard.writeText(text).catch(() => legacyCopy(text))
  }
  return Promise.resolve(legacyCopy(text))
}
function legacyCopy(text) {
  const ta = document.createElement("textarea")
  ta.value = text
  ta.setAttribute("readonly", "")
  ta.style.position = "fixed"
  ta.style.top = "-1000px"
  ta.style.opacity = "0"
  document.body.appendChild(ta)
  ta.select()
  try { document.execCommand("copy") } catch (_) {}
  document.body.removeChild(ta)
}

// StickyShadow — put on a scroll container; toggles `data-stuck` on each
// `[data-sticky-header]` inside it the moment that header pins (i.e. rows begin
// sliding UNDER it). Paired with a `data-[stuck]:…` class so the stuck look
// appears ONLY while a header is actually stuck, never at rest. A header's own
// `top` offset counts: one pinned at `top-11` under another bar is stuck at
// 44px, not 0 — the decisions deck stacks its collapsed-card band under the
// "asked by" row that way.
Hooks.StickyShadow = {
  mounted() {
    this.update = () => {
      const top = this.el.getBoundingClientRect().top
      this.el.querySelectorAll("[data-sticky-header]").forEach((h) => {
        const offset = parseFloat(getComputedStyle(h).top) || 0
        h.toggleAttribute("data-stuck", h.getBoundingClientRect().top <= top + offset + 0.5)
      })
    }
    this.el.addEventListener("scroll", this.update, {passive: true})
    this.update()
  },
  updated() { if (this.update) this.update() },
  destroyed() { this.el.removeEventListener("scroll", this.update) }
}

// StickyEdge — on a scroll container with sticky top/bottom bands (the detail
// panel's hero + action footer), show a SOFT shadow on a band ONLY while there's
// content scrolled under it. So a short panel that doesn't scroll has no lines at
// all (one cohesive card); the divider appears exactly when it's earning its
// keep. Toggles [data-stuck] on [data-sticky-edge="top"|"bottom"]; CSS draws it.
Hooks.StickyEdge = {
  mounted() {
    this.update = () => {
      const el = this.el
      const atTop = el.scrollTop <= 0.5
      const atBottom = el.scrollTop + el.clientHeight >= el.scrollHeight - 0.5
      el.querySelectorAll('[data-sticky-edge="top"]').forEach((h) =>
        h.toggleAttribute("data-stuck", !atTop))
      el.querySelectorAll('[data-sticky-edge="bottom"]').forEach((f) =>
        f.toggleAttribute("data-stuck", !atBottom))
    }
    this.el.addEventListener("scroll", this.update, {passive: true})
    this.ro = new ResizeObserver(this.update)
    this.ro.observe(this.el)
    this.update()
  },
  updated() { if (this.update) this.update() },
  destroyed() {
    this.el.removeEventListener("scroll", this.update)
    if (this.ro) this.ro.disconnect()
  }
}


// Clip: copy this element's data-copy to the clipboard, with a brief
// "Copied — paste on your Mac" confirmation. Used by the per-tool "Copy for Mac".
// QuestionOptions: a tap while the websocket is DOWN (phone-wake reconnect)
// would otherwise be silently DROPPED — the user re-taps "like crazy" until
// one lands. Capture the tap, mark the row held, and replay it the moment the
// socket reconnects. Client-side only for the click→receipt sliver; the
// server draft remains the multiplayer truth.
// AppBadge: mirror the "needs you" count onto the installed PWA's app icon
// (Badging API — supported on iOS 16.4+ Home Screen web apps and desktop
// Chrome/Edge; silently a no-op elsewhere).
Hooks.AppBadge = {
  mounted() { this.apply() },
  updated() { this.apply() },
  apply() {
    if (!("setAppBadge" in navigator)) return
    const n = parseInt(this.el.dataset.count || "0", 10)
    if (n > 0) navigator.setAppBadge(n).catch(() => {})
    else navigator.clearAppBadge().catch(() => {})
  },
}

// PushBell: subscribe THIS device to question push notifications. The click
// is the required user gesture: permission → pushManager.subscribe with the
// server's VAPID key → hand the subscription to the LV. Label reflects state.
Hooks.PushBell = {
  async mounted() {
    this.label = this.el.querySelector("[data-bell-label]")
    if (!("serviceWorker" in navigator) || !("PushManager" in window) || !this.el.dataset.vapid) {
      this.el.classList.add("hidden")
      return
    }
    this.sub = await this.currentSub()
    this.render()
    this.el.addEventListener("click", () => this.toggle())
  },
  async currentSub() {
    try {
      const reg = await navigator.serviceWorker.ready
      return await reg.pushManager.getSubscription()
    } catch (_) { return null }
  },
  render() {
    if (this.label) this.label.textContent = this.sub
      ? "Question notifications on ✓ (tap to turn off)"
      : "Notify me about questions"
  },
  async toggle() {
    if (this.sub) {
      const endpoint = this.sub.endpoint
      await this.sub.unsubscribe().catch(() => {})
      this.sub = null
      this.pushEvent("push_unsubscribe", { endpoint })
      this.render()
      return
    }
    try {
      const perm = await Notification.requestPermission()
      if (perm !== "granted") return
      const reg = await navigator.serviceWorker.ready
      this.sub = await reg.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: this.urlB64ToUint8(this.el.dataset.vapid),
      })
      this.pushEvent("push_subscribe", { subscription: this.sub.toJSON() })
      this.render()
    } catch (e) {
      if (this.label) this.label.textContent = "Couldn't enable notifications"
    }
  },
  urlB64ToUint8(base64) {
    const padding = "=".repeat((4 - (base64.length % 4)) % 4)
    const b64 = (base64 + padding).replace(/-/g, "+").replace(/_/g, "/")
    const raw = atob(b64)
    return Uint8Array.from([...raw].map((c) => c.charCodeAt(0)))
  },
}

Hooks.QuestionOptions = {
  mounted() {
    this.pending = null
    this.el.addEventListener("click", (e) => {
      const btn = e.target.closest(".q-option[phx-click]")
      if (!btn) return
      const main = document.querySelector("[data-phx-main]")
      if (main && main.classList.contains("phx-connected")) return // normal path
      this.el.querySelectorAll(".q-held").forEach((n) => n.classList.remove("q-held"))
      btn.classList.add("q-held")
      this.pending = {
        event: btn.getAttribute("phx-click"),
        question_id: btn.getAttribute("phx-value-question_id"),
        q: btn.getAttribute("phx-value-q"),
        option: btn.getAttribute("phx-value-option"),
      }
    })
  },
  reconnected() {
    if (!this.pending) return
    const { event, ...values } = this.pending
    this.pending = null
    if (event) this.pushEvent(event, values)
  },

  // The selection belongs to the person who made it. A patch triggered by
  // ANYTHING else on the page (a streaming reply, another viewer, a status
  // tick) re-renders these inputs from server state, and if the server's
  // draft hasn't landed yet that state says "nothing checked" — which is
  // precisely the tap-then-uncheck flicker. Snapshot before, restore after,
  // so no unrelated update can ever take your choice away.
  beforeUpdate() {
    this.checked = [...this.el.querySelectorAll("input[type=radio],input[type=checkbox]")]
      .filter((i) => i.checked)
      .map((i) => i.value)
    this.hadFocus = document.activeElement && this.el.contains(document.activeElement)
      ? document.activeElement.value
      : null
  },

  updated() {
    if (!this.checked) return
    this.el.querySelectorAll("input[type=radio],input[type=checkbox]").forEach((i) => {
      i.checked = this.checked.includes(i.value)
    })
    this.checked = null
  },
}

Hooks.Clip = {
  mounted() {
    // Fill the real browser origin into any __ORIGIN__ placeholder — the command
    // must target the host the user actually reached (LAN IP, Teleport tunnel),
    // which the server can't reliably know behind a proxy. Both the copied text
    // (data-copy) and the visible command (sibling <pre>) get substituted.
    const origin = window.location.origin
    if (this.el.dataset.copy) {
      this.el.dataset.copy = this.el.dataset.copy.replaceAll("__ORIGIN__", origin)
    }
    const box = this.el.closest("div")
    const pre = box && box.querySelector("pre")
    if (pre && pre.textContent.includes("__ORIGIN__")) {
      pre.textContent = pre.textContent.replaceAll("__ORIGIN__", origin)
    }
    this.el.addEventListener("click", () => {
      copyToClipboard(this.el.dataset.copy || "")
      const label = this.el.dataset.label || this.el.textContent
      this.el.textContent = "✓ Copied — paste on your Mac"
      setTimeout(() => { this.el.textContent = label }, 1600)
    })
  }
}

// OriginText: swap __ORIGIN__ for the real browser origin in rendered text (the
// tool reference doc's curl examples). Runs on mount + after LiveView updates.
Hooks.OriginText = {
  mounted() { this.sub() },
  updated() { this.sub() },
  sub() {
    if (this.el.innerHTML.includes("__ORIGIN__")) {
      this.el.innerHTML = this.el.innerHTML.replaceAll("__ORIGIN__", window.location.origin)
    }
  }
}

// PushCmd: fills the real server origin into the "push from your Mac" curl and
// copies the whole command (token included) to the clipboard.
Hooks.PushCmd = {
  mounted() {
    const code = this.el.querySelector(".ws-push-cmd")
    if (code) code.textContent = code.textContent.replace("__ORIGIN__", window.location.origin)
    const btn = this.el.querySelector(".ws-push-copy")
    if (btn && code) {
      btn.addEventListener("click", () => {
        copyToClipboard(code.textContent)
        const prev = btn.textContent
        btn.textContent = "Copied"
        setTimeout(() => { btn.textContent = prev }, 1200)
      })
    }
  }
}

// WsScroll: on the Workstation page, scroll the console into view when a
// runnable-doc "▶ Run" sends a command to it (the terminal lives where the
// instruction is, so we bring it into view after you click Run).
Hooks.WsScroll = {
  mounted() {
    this.handleEvent("ws_focus_console", () => {
      document.getElementById("ws-console")?.scrollIntoView({behavior: "smooth", block: "start"})
    })
  }
}

Hooks.TailScroll = {
  mounted() {
    this._userScrolledUp = false
    this.el.scrollTop = this.el.scrollHeight

    this.el.addEventListener("scroll", () => {
      const el = this.el
      // "At bottom" means within 30px of the bottom edge
      const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 30
      this._userScrolledUp = !atBottom
    })
  },
  updated() {
    if (!this._userScrolledUp) {
      this.el.scrollTop = this.el.scrollHeight
    }
  }
}

// Log output viewer: tails output while streaming, expand button to
// remove height constraint and show full output inline.
Hooks.LogExpand = {
  mounted() {
    this._userScrolledUp = false
    this._expanded = false

    const pre = this.el.querySelector("[data-log-pre]")
    const btn = this.el.querySelector("[data-expand]")
    if (!pre) return

    // Tail: scroll to bottom on mount
    pre.scrollTop = pre.scrollHeight

    // Pause tail when user scrolls up, resume when back at bottom
    pre.addEventListener("scroll", () => {
      const atBottom = pre.scrollHeight - pre.scrollTop - pre.clientHeight < 30
      this._userScrolledUp = !atBottom
    }, { passive: true })

    // Show expand button when content overflows
    if (pre.scrollHeight > pre.clientHeight + 10) {
      btn.classList.remove("hidden")
    }

    // Expand/collapse toggle. NEVER btn.textContent — that replaced the
    // chevron SVG with a raw unstyled "expand"/"collapse" word (the giant
    // text bug). The chevron rotates to point up when expanded instead.
    if (btn) {
      btn.addEventListener("click", () => {
        this._expanded = !this._expanded
        const icon = btn.querySelector("svg")
        if (this._expanded) {
          pre.style.maxHeight = "none"
          btn.title = "Collapse output"
          if (icon) icon.classList.add("rotate-180")
        } else {
          pre.style.maxHeight = ""
          btn.title = "Show full output"
          if (icon) icon.classList.remove("rotate-180")
          pre.scrollTop = pre.scrollHeight
        }
      })
    }
  },
  updated() {
    const pre = this.el.querySelector("[data-log-pre]")
    const btn = this.el.querySelector("[data-expand]")
    if (!pre) return

    // Tail scroll on update
    if (!this._userScrolledUp && !this._expanded) {
      pre.scrollTop = pre.scrollHeight
    }

    // Show expand button once content overflows
    if (btn && pre.scrollHeight > pre.clientHeight + 10) {
      btn.classList.remove("hidden")
    }
  }
}

// Live elapsed-time counter for a running command's build bubble. Ticks
// every second from data-since (unix ms), entirely client-side — no server
// round-trips. Makes a silent long command visibly "alive" so you can tell
// working from wedged. phx-update="ignore" keeps LiveView off our textContent.
// ONE timer, both directions: counts UP from data-since (elapsed) or DOWN to
// data-until (countdown, epoch ms). The server owns the timestamp — the browser
// only animates the display between server updates, like a CSS transition, so a
// turn or a wait visibly progresses without a socket round-trip every second.
// No client state. Optional data-prefix / data-suffix wrap the number.
Hooks.Elapsed = {
  mounted() { this._start() },
  updated() { this._start() },
  _start() {
    if (this._timer) { clearInterval(this._timer); this._timer = null }
    const since = parseInt(this.el.dataset.since, 10)
    const until = parseInt(this.el.dataset.until, 10)
    if (!since && !until) { this.el.textContent = ""; return }
    const prefix = this.el.dataset.prefix || ""
    const suffix = this.el.dataset.suffix || ""
    const fmt = (ms) => {
      const s = Math.max(0, Math.round(ms / 1000))
      if (until && s <= 0) return "now"
      if (s < 60) return `${s}s`
      const m = Math.floor(s / 60), r = s % 60
      if (m < 60) return `${m}m ${r}s`
      return `${Math.floor(m / 60)}h ${m % 60}m`
    }
    const tick = () => {
      const ms = until ? until - Date.now() : Date.now() - since
      this.el.textContent = prefix + fmt(ms) + suffix
      if (until && until - Date.now() <= 0 && this._timer) {
        clearInterval(this._timer); this._timer = null
      }
    }
    tick()
    this._timer = setInterval(tick, 1000)
  },
  destroyed() { if (this._timer) clearInterval(this._timer) }
}

// DetailLevel hook deleted with the All | Actions | Chat control it served —
// see the note in chat/header.ex. Nothing persists a detail level now; the
// transcript always renders at :trace (full reasoning + tool calls + output).

// ShareSheet — the native share affordance for focused/share views. Click:
// data-share="sheet" opens the OS share sheet (navigator.share — iOS/macOS pass
// title+url to Messages/AirDrop/etc), falling back to copying the URL;
// data-share="url" copies the URL outright. Generalized: any element with this
// hook + data attributes works.
Hooks.ShareSheet = {
  mounted() {
    this.el.addEventListener("click", async (e) => {
      e.preventDefault()
      const url = this.el.dataset.url || window.location.href
      const title = this.el.dataset.title || document.title
      const mode = this.el.dataset.share || "sheet"
      if (mode === "sheet" && navigator.share) {
        try { await navigator.share({title, url}) } catch (_) {}
        return
      }
      try {
        await navigator.clipboard.writeText(url)
        this.flash("Copied link")
      } catch (_) {}
    })
  },
  flash(text) {
    const prev = this.el.dataset.flashPrev ?? (this.el.dataset.flashPrev = this.el.innerHTML)
    this.el.textContent = text
    setTimeout(() => { this.el.innerHTML = prev }, 1200)
  }
}

// ChatAttachments — the composer's upload tray (LV-rendered). Its only job is
// to tell the ChatForm hook (which lives in a phx-update="ignore" island and
// can't observe LV renders) that the file count changed.
Hooks.ChatAttachments = {
  mounted() { this.ping() },
  updated() { this.ping() },
  destroyed() { window.dispatchEvent(new CustomEvent("loopyard:attachments", { detail: { count: 0 } })) },
  ping() {
    const count = parseInt(this.el.dataset.count || "0", 10)
    window.dispatchEvent(new CustomEvent("loopyard:attachments", { detail: { count } }))
  }
}

// ChatForm — the composer. THE CONTRACT, in one place:
//
//   ENTER (decided per keydown by layout width, md=768px):
//     desktop ≥768px : Enter SENDS · Shift+Enter newline · ⌘/⌃+Enter sends
//     mobile  <768px : Enter NEWLINES (Send is the button) · ⌘/⌃+Enter sends
//   Plain Enter on desktop preventDefaults BEFORE anything else — a newline
//   can never enter the box on the send path.
//
//   SEND is OPTIMISTIC: the box clears INSTANTLY and the text appears in the
//   #send-echo band (same spot/skin as the server queue band), so there is
//   zero perceived latency even when the LiveView is seconds behind on a busy
//   stream. The server ack then swaps the echo for the real queue band (the
//   ack reply carries the pending list, so the swap is one render). On
//   failure/timeout the text returns to the box — never lost.
//
//   The element persists across LiveView reconnects (phx-update="ignore"
//   wrapper), so mounted() can run again on the SAME dom — the wire-once
//   guard prevents duplicate listeners (double-send, double-resize).
Hooks.ChatForm = {
  mounted() {
    // Scoped to THIS form, never a page-wide id: the decisions deck mounts one
    // composer per slide (each talks about its own decision), so ids can't be
    // the contract. `data-re` on the form names the decision a send is about
    // and rides along in the payload; it also keys the draft so slides don't
    // share one.
    const ta = this.el.querySelector("textarea[name=message]")
    const btn = this.el.querySelector("button[type=submit]")
    if (!ta || ta.dataset.wired) return
    ta.dataset.wired = "1"
    let sending = false
    const re = this.el.dataset.re || ""
    const scope = location.pathname + (re ? "#" + re : "")
    const statusEl = () =>
      (this.el.parentElement && this.el.parentElement.querySelector("[data-send-status]")) ||
      document.getElementById("send-status")

    // ATTACHMENTS — three ways in, ONE LiveView upload ("attachments"):
    //   paperclip → clicks the LV file input in the #chat-attachments tray
    //   paste     → files on the clipboard go straight to the upload
    //   drop      → phx-drop-target on the chat pane (LiveView handles it)
    // The tray (LV-rendered, next to this ignored form) shows chips + progress
    // and pings "loopyard:attachments" on every render so the send cue and
    // the "is there anything to send" check track it. Send consumes the tray
    // server-side; this hook never touches the files themselves.
    const attachmentCount = () => {
      const tray = document.getElementById("chat-attachments")
      return tray ? parseInt(tray.dataset.count || "0", 10) : 0
    }
    const attachBtn = this.el.querySelector("#chat-attach")
    if (attachBtn) attachBtn.addEventListener("click", () => {
      const input = document.querySelector("#chat-attachments input[type=file]")
      if (input) input.click()
    })
    ta.addEventListener("paste", (e) => {
      const files = Array.from((e.clipboardData && e.clipboardData.files) || [])
      if (files.length === 0) return
      e.preventDefault()
      this.upload("attachments", files)
    })
    window.addEventListener("loopyard:attachments", () => updateSend())

    // Draft persistence — the LAST line of defense for a half-typed message.
    // phx-update="ignore" already protects the box from LiveView patches, but a
    // FULL reload (Elixir code reload, server restart → remount, browser refresh)
    // rebuilds the DOM from scratch and would wipe it. So we mirror every
    // keystroke into localStorage (keyed per-agent via the path) and restore it
    // on mount. Cleared only on a confirmed send.
    const draftKey = "loopyard:draft:" + scope
    // A draft carries a TIMESTAMP and only restores inside a freshness window.
    // Without one it lived forever: a message typed days ago whose send was
    // never confirmed came back into the box on a later visit, and the next
    // Send fired it — so an agent acted on an instruction from another day that
    // the user had no idea was still queued up. The focus key below already had
    // this guard ("reopening the tab later never steals focus"); the draft is
    // the one where being stale actually DOES something.
    //
    // The window only has to cover the case this exists for: a reload, a code
    // reload, a server restart. Minutes, not days.
    const DRAFT_TTL = 30 * 60 * 1000
    const writeDraft = () => {
      try {
        ta.value
          ? localStorage.setItem(draftKey, JSON.stringify({ text: ta.value, t: Date.now() }))
          : localStorage.removeItem(draftKey)
      } catch (_) {}
    }
    // Writing localStorage on EVERY keystroke is a synchronous disk hit that
    // shows up as type latency. Debounce to ~300ms after you stop typing; a
    // blur (below) flushes immediately, so leaving the box always persists.
    let draftTimer = null
    const saveDraft = () => { clearTimeout(draftTimer); draftTimer = setTimeout(writeDraft, 300) }
    // Clearing (on a confirmed send) must also kill any pending debounced write,
    // or it would resurrect the just-sent draft a moment later.
    const clearDraft = () => { clearTimeout(draftTimer); try { localStorage.removeItem(draftKey) } catch (_) {} }

    // Restore a draft from a prior session, but never clobber text already in the
    // box (e.g. server-restored input that mounted first).
    try {
      const raw = localStorage.getItem(draftKey)
      // Tolerate the pre-TTL format (a bare string): treat it as expired rather
      // than restoring text of unknown age — that's the exact failure this fixes.
      let saved = null
      if (raw && raw.startsWith("{")) {
        const { text, t } = JSON.parse(raw)
        if (text && Date.now() - t < DRAFT_TTL) saved = text
      }
      if (!saved) localStorage.removeItem(draftKey)

      if (saved && ta.value.trim() === "") {
        ta.value = saved
        requestAnimationFrame(() => {
          ta.style.height = "auto"
          ta.style.height = Math.min(ta.scrollHeight, 200) + "px"
        })
      }
    } catch (_) {}

    // Focus persistence across a FULL reload (dev live-reload, server restart) —
    // if you're mid-type and the page rebuilds, land back in the box at the same
    // caret. Guarded by a freshness WINDOW, not just a flag: we only restore if
    // you were in the box within the last few seconds, so reopening the tab later
    // never steals focus (or pops the mobile keyboard) when you didn't ask. Blur
    // clears it, so clicking away means "leave me out of it."
    const focusKey = "loopyard:focus:" + scope
    const FOCUS_TTL = 15000
    const saveFocus = () => {
      try { localStorage.setItem(focusKey, JSON.stringify({ pos: ta.selectionStart, t: Date.now() })) } catch (_) {}
    }
    const clearFocus = () => { try { localStorage.removeItem(focusKey) } catch (_) {} }
    // keyup fires per keystroke, so its focus write is debounced too (same disk-
    // latency reason as the draft). focus/click are rare → write immediately.
    let focusTimer = null
    const saveFocusDebounced = () => { clearTimeout(focusTimer); focusTimer = setTimeout(saveFocus, 300) }
    ta.addEventListener("focus", saveFocus)
    // Blur flushes the draft (immediate persist on leaving) then clears focus.
    ta.addEventListener("blur", () => { clearTimeout(draftTimer); writeDraft(); clearFocus() })
    // Keep the caret/timestamp fresh while actively editing (typing, arrowing,
    // clicking within the box) so a long-but-active session still counts as "in it."
    ta.addEventListener("keyup", () => { if (document.activeElement === ta) saveFocusDebounced() })
    ta.addEventListener("click", () => { if (document.activeElement === ta) saveFocus() })
    try {
      const raw = localStorage.getItem(focusKey)
      if (raw) {
        const { pos, t } = JSON.parse(raw)
        if (Date.now() - t < FOCUS_TTL) {
          ta.focus()
          const p = Number.isInteger(pos) ? Math.min(pos, ta.value.length) : ta.value.length
          ta.setSelectionRange(p, p)
        } else {
          clearFocus()
        }
      }
    } catch (_) {}

    // Subtle "ready to send" cue: the arrow fills violet when there's text.
    const updateSend = () => {
      if (btn) btn.classList.toggle("send-ready", ta.value.trim() !== "" || attachmentCount() > 0)
    }
    updateSend()

    const send = () => {
      if (sending) return
      const text = ta.value.trim()
      const files = attachmentCount()
      if (!text && files === 0) return
      sending = true
      if (btn) btn.disabled = true

      // OPTIMISTIC: clear the box NOW and echo the text where the queue band
      // will render — the message is visible instantly, nothing jumps later.
      ta.value = ""
      ta.style.height = "auto"
      clearDraft()
      updateSend()
      // iOS: a pending autocorrect can commit the just-cleared text right back
      // within a frame. Anything in the box one frame after our clear (a human
      // can't type that fast) is that artifact — clear it again.
      requestAnimationFrame(() => {
        if (sending && ta.value !== "") {
          ta.value = ""
          ta.style.height = "auto"
          ta.dispatchEvent(new Event("input", { bubbles: true }))
        }
      })

      const echo = document.getElementById("send-echo")
      const echoText = echo && echo.querySelector("[data-echo-text]")
      const echoLabel = echo && echo.querySelector("[data-echo-label]")
      if (echoText) echoText.textContent = text || `📎 ${files} file${files === 1 ? "" : "s"}`
      if (echoLabel) echoLabel.textContent = "Sending…"
      if (echo) echo.classList.remove("hidden")

      // If the ack is slow, SAY WHY rather than leaving a static label. The
      // common cause is the idle reaper: after 4h the harness subprocess is
      // stopped, so the first message has to respawn it (docker exec + an ACP
      // handshake — seconds). Sitting on "Queued" through that reads as stuck,
      // which is exactly how it got reported: "turn is queued and it should be
      // running". It was running; nothing said so.
      const slowLabel = setTimeout(() => {
        if (echoLabel) echoLabel.textContent = "Waking the agent…"
      }, 1200)

      const hideEcho = () => {
        clearTimeout(slowLabel)
        if (echo) echo.classList.add("hidden")
      }

      const status = statusEl()
      const setStatus = (text2, tone) => {
        if (!status) return
        status.textContent = text2
        status.className =
          "mt-1.5 text-sm " +
          (tone === "error" ? "text-red-500 dark:text-red-400" : "text-zinc-400 dark:text-zinc-500")
      }
      let settled = false
      const settle = (ok, reason) => {
        if (settled) return
        settled = true
        sending = false
        if (btn) btn.disabled = false
        if (ok) {
          // The ack render carries the pending list — the server queue band is
          // already on screen; drop the echo in the same frame.
          hideEcho()
          if (status) status.classList.add("hidden")
          // A send should take you to where the answer will appear. On a
          // decision slide the thread sits below the card, so a message sent
          // from the top of the slide landed out of sight — "I hit send and
          // nothing happened". `data-scroll-to` names the thread; native
          // scrollIntoView (with the thread's scroll-margin clearing the
          // pinned bar + collapsed card) brings it up.
          const target = this.el.dataset.scrollTo && document.getElementById(this.el.dataset.scrollTo)
          if (target) target.scrollIntoView({ block: "start", behavior: "smooth" })
        } else {
          // Put the text back (unless the user already started the next
          // message) and say why — a failed send is never silent, never lost.
          hideEcho()
          if (ta.value.trim() === "") {
            ta.value = text
            ta.dispatchEvent(new Event("input", { bubbles: true }))
          }
          ta.style.boxShadow = "0 0 0 2px rgb(248 113 113)"
          setTimeout(() => { ta.style.boxShadow = "" }, 2500)
          setStatus(reason || "Send didn't go through — your text is kept, press Send to retry.", "error")
          ta.focus()
        }
      }

      // 25s: a send into an ASLEEP agent legitimately takes a while (the server
      // wakes the workspace + agent). Dead sockets are reported faster by the
      // conn-banner; this is only the never-acked backstop.
      const timer = setTimeout(() =>
        settle(false, "⚠ Couldn't reach the server — your text is safe; press Send to retry."),
      25000)
      const payload = re ? { message: text, re } : { message: text }
      this.pushEvent("send_message", payload, (reply) => {
        clearTimeout(timer)
        if (reply && reply.ok) settle(true)
        else settle(false, (reply && reply.note) || "⚠ Send didn't land — your text is kept; try again.")
      })
    }

    // Submit semantics, keyed to the LAYOUT (Tailwind's md breakpoint, 768px) —
    // NOT pointer type. A desktop narrowed to a mobile viewport behaves like
    // mobile, and a real phone is always below the breakpoint:
    //   DESKTOP (≥768px): Enter SENDS · Shift+Enter newline
    //   MOBILE  (<768px):  Enter does NOTHING — you tap the send button
    // Shift+Enter is the ONLY way plain-Enter inserts a newline; ⌘/Ctrl+Enter
    // ALWAYS sends. Evaluated live on each keydown so resizing flips behavior
    // without a remount. `isComposing` guards IME users (CJK): Enter picks a
    // candidate.
    //
    // CRITICAL: plain Enter calls preventDefault UNCONDITIONALLY (before the
    // desktop/mobile branch). Previously the mobile path `return`ed *before*
    // preventDefault, so any time `isDesktop()` read false — a narrow window, an
    // embedded/preview webview, zoom — a newline slipped into the box, growing
    // it then collapsing on the send-ack. Now the newline is impossible either
    // way; only the send-vs-nothing decision depends on the viewport.
    const isDesktop = () => window.matchMedia("(min-width: 768px)").matches
    ta.addEventListener("keydown", (e) => {
      if (e.key !== "Enter" || e.isComposing) return
      if (e.metaKey || e.ctrlKey) { e.preventDefault(); send(); return }  // ⌘/⌃+Enter: always send
      if (e.shiftKey) return                                              // Shift+Enter: newline (both)
      if (isDesktop()) { e.preventDefault(); send(); return }             // desktop: Enter SENDS
      // mobile: fall through — Enter inserts a NEWLINE (send is the button)
    })

    // Auto-resize textarea + clear any stale "send failed" notice as you edit
    ta.addEventListener("input", () => {
      const status = statusEl()
      if (status && !status.classList.contains("hidden")) status.classList.add("hidden")
      saveDraft()
      updateSend()
      requestAnimationFrame(() => {
        ta.style.height = "auto"
        ta.style.height = Math.min(ta.scrollHeight, 200) + "px"
      })
    })

    // Keep textarea focused when tapping Send — prevents keyboard
    // dismiss/reappear bounce on iOS.
    if (btn) {
      btn.addEventListener("mousedown", (e) => { e.preventDefault(); send() })
      btn.addEventListener("touchend", (e) => { e.preventDefault(); send() })
    }

    // Catch form submit (phx-submit fallback)
    this.el.addEventListener("submit", (e) => { e.preventDefault(); send() })
    this.handleEvent("focus_input", () => ta.focus())

    // NOTE deliberately NO "restore_input" handler: the composer is for
    // HUMANS ONLY. Recovery never writes into it — a machine-built resume
    // seed once got "restored" here, dumping the whole chat history at the
    // user. fill_input below survives because it is a deliberate USER action.

    // Explicit edit (tapping a queued message to pull it back) — always fills,
    // even over existing text, since it's a deliberate action.
    this.handleEvent("fill_input", ({ text }) => { if (text) fillBox(text) })

    function fillBox(text) {
      ta.value = text
      updateSend()
      ta.style.height = "auto"
      ta.style.height = Math.min(ta.scrollHeight, 200) + "px"
      saveDraft()
      ta.focus()
    }
  }
}

Hooks.CopySource = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      e.preventDefault()
      const source = this.el.dataset.source
      if (!source) return

      const copyText = (text) => {
        copyToClipboard(text).then(() => {
          const icon = this.el.querySelector(".copy-icon")
          const check = this.el.querySelector(".check-icon")
          if (icon && check) {
            icon.classList.add("hidden")
            check.classList.remove("hidden")
            setTimeout(() => {
              icon.classList.remove("hidden")
              check.classList.add("hidden")
            }, 1500)
          }
          const orig = this.el.textContent.trim()
          if (!icon && orig) {
            this.el.textContent = "Copied!"
            setTimeout(() => { this.el.textContent = orig }, 1500)
          }
        })
      }

      const mode = this.el.dataset.copy || "text"
      if (mode === "fetch") {
        fetch(source).then(r => {
          if (r.ok && (r.headers.get("content-type") || "").includes("text/plain")) {
            return r.text()
          }
          // Failed — copy nothing, show error
          return "[content unavailable]"
        }).then(copyText)
      } else {
        copyText(source)
      }
    })
  }
}

// LogTail: keep the service-log panel pinned to the newest line (bottom). On
// mount it jumps to the bottom; as new frames stream in it stays there — UNLESS
// you scroll up (e.g. to read an earlier run or jump via the Runs strip), in
// which case it leaves you be until you scroll back down.
Hooks.LogTail = {
  mounted() {
    this._pinned = true
    // iOS momentum-scroll fight: setting scrollTop mid-gesture (finger down OR
    // the momentum that continues after lift-off) cancels the fling and reads as
    // a "bounce". So we track touch and suppress auto-tail during a gesture and
    // for a short cooldown after it, letting the fling settle. scroll events
    // still fire throughout, so `_pinned` re-evaluates from the real position.
    this._touching = false
    this._lastTouch = 0
    this._onScroll = () => {
      const gap = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
      this._pinned = gap < 48
    }
    this._onTouchStart = () => { this._touching = true }
    this._onTouchEnd = () => { this._touching = false; this._lastTouch = Date.now() }
    this.el.addEventListener("scroll", this._onScroll, {passive: true})
    this.el.addEventListener("touchstart", this._onTouchStart, {passive: true})
    this.el.addEventListener("touchend", this._onTouchEnd, {passive: true})
    this.el.addEventListener("touchcancel", this._onTouchEnd, {passive: true})
    // Pin to the newest line on mount. Re-nudge across a few frames because a big
    // log's real scrollHeight isn't known until it lays out — a single scroll can
    // land short. `force` bypasses the pin/touch guards (mount always tails).
    this.tail(true)
    requestAnimationFrame(() => this.tail(true))
    setTimeout(() => this.tail(true), 80)
    setTimeout(() => this.tail(true), 300)
  },
  updated() {
    this.tail()
  },
  destroyed() {
    this.el.removeEventListener("scroll", this._onScroll)
    this.el.removeEventListener("touchstart", this._onTouchStart)
    this.el.removeEventListener("touchend", this._onTouchEnd)
    this.el.removeEventListener("touchcancel", this._onTouchEnd)
  },
  tail(force) {
    if (!force) {
      if (!this._pinned) return
      // Don't yank while the user is touching or a fling is still settling.
      if (this._touching || Date.now() - this._lastTouch < 400) return
    }
    const el = this.el
    const target = el.scrollHeight - el.clientHeight
    // Already at the bottom (within a couple px) → no-op. Re-setting an
    // unchanged scrollTop is what triggers the iOS rubber-band jitter.
    if (Math.abs(el.scrollTop - target) < 2) return
    el.scrollTop = target
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken}
})

liveSocket.connect()
window.liveSocket = liveSocket

// PWA: register the (network-only) service worker so the app is installable and
// launches standalone from the home screen / dock. Best-effort — a failure here
// must never affect the app. iOS doesn't require the SW for add-to-home-screen
// (the manifest + apple meta cover that), but it enables install elsewhere.
if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/sw.js").catch(() => {})
  })
}

// Connection-lost banner: reveal #conn-banner when the websocket has been down
// past a short grace period (so a quick reconnect — live reload, blip — doesn't
// flash it), hide it the moment we're back. This is the "is it safe to type"
// signal; the ChatForm hook independently keeps your text until the server acks.
;(() => {
  const banner = document.getElementById("conn-banner")
  if (!banner) return
  let downTimer = null
  const show = () => banner.classList.remove("hidden")
  const hide = () => {
    if (downTimer) { clearTimeout(downTimer); downTimer = null }
    banner.classList.add("hidden")
  }
  // 4s grace: a dev code-reload / server restart usually reconnects in 1–4s —
  // narrating those blips isn't calm. A real outage still surfaces within 4s.
  const armDown = (ms = 4000) => { if (!downTimer) downTimer = setTimeout(show, ms) }
  liveSocket.socket.onOpen(hide)
  liveSocket.socket.onError(() => armDown())
  liveSocket.socket.onClose(() => armDown())

  // PHONE WAKE: when the page becomes visible again the user is LOOKING at it
  // and about to tap — the reconnect window (1–4s) with no banner reads as
  // "broken, tap harder". Reveal fast (500ms) for this episode only; a wake
  // that reconnects instantly still shows nothing.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible") return
    const main = document.querySelector("[data-phx-main]")
    if (main && !main.classList.contains("phx-connected")) armDown(500)
  })

  // Belt-and-suspenders for the states socket callbacks can't see: a page
  // served mid-reload whose socket NEVER connected (no onError fires), or a
  // LiveView whose channel JOIN failed on a healthy socket. Both leave a
  // dead-looking page where typing does nothing and no banner shows — poll
  // LiveView's own connected marker instead of trusting socket events alone.
  setInterval(() => {
    const main = document.querySelector("[data-phx-main]")
    if (!main) return
    if (main.classList.contains("phx-connected")) hide()
    else armDown()
  }, 2000)
})()
