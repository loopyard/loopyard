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
// `[data-sticky-header]` inside it the moment that header pins to the top (i.e.
// rows begin sliding UNDER it). Paired with a `data-[stuck]:shadow-…` class so the
// shadow appears ONLY while a header is actually stuck, never at rest.
Hooks.StickyShadow = {
  mounted() {
    this.update = () => {
      const top = this.el.getBoundingClientRect().top
      this.el.querySelectorAll("[data-sticky-header]").forEach((h) => {
        h.toggleAttribute("data-stuck", h.getBoundingClientRect().top <= top + 0.5)
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

// BottomSheet — a mobile "share sheet". The server renders it hidden with the
// panel translated fully down; opening (a `sheet:open` event, via Nav.open_sheet)
// un-hides the container and slides the panel up, closing reverses it. Swiping
// DOWN on the grab handle drags the panel with your finger and dismisses past a
// threshold (snaps back otherwise) — the body scrolls independently.
Hooks.BottomSheet = {
  mounted() {
    this.panel = this.el
    this.container = document.querySelector(this.panel.dataset.sheet)
    this.dragZone = this.panel.querySelector("[data-sheet-drag]")

    this._open = () => this.show()
    this._close = () => this.hide()
    this.panel.addEventListener("sheet:open", this._open)
    this.panel.addEventListener("sheet:close", this._close)

    let startY = 0, dy = 0, dragging = false
    this._onStart = (e) => {
      startY = e.touches[0].clientY; dy = 0; dragging = true
      this.panel.style.transition = "none"
    }
    this._onMove = (e) => {
      if (!dragging) return
      dy = Math.max(0, e.touches[0].clientY - startY)
      this.panel.style.transform = `translateY(${dy}px)`
    }
    this._onEnd = () => {
      if (!dragging) return
      dragging = false
      this.panel.style.transition = ""
      if (dy > 90) this.hide()
      else this.panel.style.transform = ""
    }
    if (this.dragZone) {
      this.dragZone.addEventListener("touchstart", this._onStart, {passive: true})
      this.dragZone.addEventListener("touchmove", this._onMove, {passive: true})
      this.dragZone.addEventListener("touchend", this._onEnd)
    }
  },
  destroyed() {
    this.panel.removeEventListener("sheet:open", this._open)
    this.panel.removeEventListener("sheet:close", this._close)
  },
  show() {
    if (!this.container) return
    this.container.classList.remove("hidden")
    this.panel.style.transform = ""
    void this.panel.offsetHeight // reflow so the slide runs from translate-y-full
    requestAnimationFrame(() => this.panel.classList.remove("translate-y-full"))
  },
  hide() {
    if (!this.container) return
    this.panel.style.transform = ""
    this.panel.classList.add("translate-y-full")
    const done = () => {
      this.container.classList.add("hidden")
      this.panel.removeEventListener("transitionend", done)
    }
    this.panel.addEventListener("transitionend", done)
    setTimeout(() => this.container && this.container.classList.add("hidden"), 350)
  }
}

// Clip: copy this element's data-copy to the clipboard, with a brief
// "Copied — paste on your Mac" confirmation. Used by the per-tool "Copy for Mac".
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
Hooks.Elapsed = {
  mounted() {
    const since = parseInt(this.el.dataset.since, 10)
    if (!since) return
    const fmt = (ms) => {
      const s = Math.max(0, Math.floor(ms / 1000))
      if (s < 60) return `${s}s`
      const m = Math.floor(s / 60), r = s % 60
      if (m < 60) return `${m}m ${r}s`
      return `${Math.floor(m / 60)}h ${m % 60}m`
    }
    const tick = () => { this.el.textContent = fmt(Date.now() - since) }
    tick()
    this._timer = setInterval(tick, 1000)
  },
  destroyed() { if (this._timer) clearInterval(this._timer) }
}

// Persist the activity detail level (All / Actions / Chat) across reloads.
// The server starts everyone at :trace (max visibility); on connect we restore
// the user's saved choice, and we save whenever it changes. localStorage, so
// the preference is per-device and survives reconnects.
Hooks.DetailLevel = {
  mounted() {
    const saved = localStorage.getItem("loopyard:detail_level")
    if (saved && saved !== this.el.dataset.level) {
      this.pushEvent("set_detail_level", { level: saved })
    }
  },
  updated() {
    if (this.el.dataset.level) {
      localStorage.setItem("loopyard:detail_level", this.el.dataset.level)
    }
  }
}

Hooks.ChatForm = {
  mounted() {
    const ta = this.el.querySelector("#chat-input")
    const btn = this.el.querySelector("button[type=submit]")
    let sending = false

    // Draft persistence — the LAST line of defense for a half-typed message.
    // phx-update="ignore" already protects the box from LiveView patches, but a
    // FULL reload (Elixir code reload, server restart → remount, browser refresh)
    // rebuilds the DOM from scratch and would wipe it. So we mirror every
    // keystroke into localStorage (keyed per-agent via the path) and restore it
    // on mount. Cleared only on a confirmed send.
    const draftKey = "loopyard:draft:" + location.pathname
    const saveDraft = () => {
      try { ta.value ? localStorage.setItem(draftKey, ta.value) : localStorage.removeItem(draftKey) } catch (_) {}
    }
    const clearDraft = () => { try { localStorage.removeItem(draftKey) } catch (_) {} }

    // Restore a draft from a prior session, but never clobber text already in the
    // box (e.g. server-restored input that mounted first).
    try {
      const saved = localStorage.getItem(draftKey)
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
    const focusKey = "loopyard:focus:" + location.pathname
    const FOCUS_TTL = 15000
    const saveFocus = () => {
      try { localStorage.setItem(focusKey, JSON.stringify({ pos: ta.selectionStart, t: Date.now() })) } catch (_) {}
    }
    const clearFocus = () => { try { localStorage.removeItem(focusKey) } catch (_) {} }
    ta.addEventListener("focus", saveFocus)
    ta.addEventListener("blur", clearFocus)
    // Keep the caret/timestamp fresh while actively editing (typing, arrowing,
    // clicking within the box) so a long-but-active session still counts as "in it."
    ta.addEventListener("keyup", () => { if (document.activeElement === ta) saveFocus() })
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

    const send = () => {
      if (sending) return
      const text = ta.value.trim()
      if (!text) return
      sending = true
      if (btn) btn.disabled = true

      // Do NOT clear the input yet. Keep the text until the server ACKS the
      // send (the handle_event reply). If the socket is disconnected (live
      // reload, reconnect, flaky phone link), the callback never fires — a
      // timeout restores the box so the message is never silently lost.
      const status = document.getElementById("send-status")
      // Status line under the input. Every caller sets BOTH text and tone so no
      // color state leaks between the busy and error paths. "Sending…" shows the
      // instant you hit Send — otherwise the message only appears after the
      // server round-trip, which visibly lags while the agent is mid-turn.
      const setStatus = (text, tone) => {
        if (!status) return
        status.textContent = text
        status.className =
          "mt-1.5 text-sm " +
          (tone === "error" ? "text-red-500 dark:text-red-400" : "text-zinc-400 dark:text-zinc-500")
      }
      setStatus("Sending…", "busy")
      let settled = false
      const settle = (ok, reason) => {
        if (settled) return
        settled = true
        sending = false
        if (btn) btn.disabled = false
        if (ok) {
          ta.value = ""
          ta.style.height = "auto"
          clearDraft()
          // iOS: tapping Send keeps focus in the field (touchend preventDefault),
          // and a pending autocorrect can COMMIT the just-cleared text right back
          // into it — which our input listener then dutifully re-saves as a
          // draft. Clear again next frame, and fire a synthetic input so the
          // resize + draft listeners see the truly-empty state.
          requestAnimationFrame(() => {
            if (!sending) {
              ta.value = ""
              ta.style.height = "auto"
              clearDraft()
              ta.dispatchEvent(new Event("input", { bubbles: true }))
            }
          })
          if (status) status.classList.add("hidden")
        } else {
          // Text is still in the box — flag it AND say why, so a failed send is
          // never a silent red flash.
          ta.style.boxShadow = "0 0 0 2px rgb(248 113 113)"
          setTimeout(() => { ta.style.boxShadow = "" }, 2500)
          setStatus(reason || "Send didn't go through — your text is kept, press Send to retry.", "error")
          ta.focus()
        }
      }

      // 25s: a send into an ASLEEP agent can legitimately take a while — the
      // server wakes the workspace + agent and delivers (wait ~2s + enqueue
      // call ≤15s). A short timer here mislabeled those as failures while the
      // message actually landed → confusing double-sends. Genuinely-dead
      // sockets are reported separately (and faster) by the conn-banner.
      const timer = setTimeout(() =>
        settle(false, "⚠ Couldn't reach the server — your text is safe; press Send to retry."),
      25000)
      this.pushEvent("send_message", { message: text }, (reply) => {
        clearTimeout(timer)
        if (reply && reply.ok) settle(true)
        // The server's note is THE message (calm "waking…" vs real failure) —
        // one channel, no generic guess, no competing toast.
        else settle(false, (reply && reply.note) || "⚠ Send didn't land — your text is kept; try again.")
      })
    }

    // Submit semantics, keyed to the LAYOUT (Tailwind's md breakpoint, 768px) —
    // NOT pointer type. A desktop narrowed to a mobile viewport should behave
    // like mobile (you're testing the mobile layout), and a real phone is
    // always below the breakpoint, so this is right for both:
    //   DESKTOP (≥768px): Enter sends · Shift+Enter newline
    //   MOBILE  (<768px):  Enter newlines · you send with the button
    // Cmd/Ctrl+Enter ALWAYS sends, everywhere. Evaluated live on each keydown
    // so resizing the window flips behavior without a remount. `isComposing`
    // guards IME users (CJK): Enter during composition picks a candidate.
    const isDesktop = () => window.matchMedia("(min-width: 768px)").matches
    ta.addEventListener("keydown", (e) => {
      if (e.key !== "Enter" || e.isComposing) return
      if (e.metaKey || e.ctrlKey) { e.preventDefault(); send(); return }  // ⌘/⌃+Enter: always send
      if (!isDesktop()) return                                            // mobile: Enter = newline
      if (e.shiftKey) return                                              // desktop: Shift+Enter = newline
      e.preventDefault(); send()                                          // desktop: Enter = send
    })

    // Auto-resize textarea + clear any stale "send failed" notice as you edit
    ta.addEventListener("input", () => {
      const status = document.getElementById("send-status")
      if (status && !status.classList.contains("hidden")) status.classList.add("hidden")
      saveDraft()
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

    // A turn failed (e.g. Anthropic 529) — the server preserved the prompt and
    // pushes it back here. Refill the box ONLY if empty, so we never clobber
    // something the user has since started typing. The text is right where they
    // left it; they hit Enter to retry, as many times as they want.
    this.handleEvent("restore_input", ({ text }) => {
      if (!text || ta.value.trim() !== "") return
      fillBox(text)
    })

    // Explicit edit (tapping a queued message to pull it back) — always fills,
    // even over existing text, since it's a deliberate action.
    this.handleEvent("fill_input", ({ text }) => { if (text) fillBox(text) })

    function fillBox(text) {
      ta.value = text
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
  const armDown = () => { if (!downTimer) downTimer = setTimeout(show, 1500) }
  liveSocket.socket.onOpen(hide)
  liveSocket.socket.onError(armDown)
  liveSocket.socket.onClose(armDown)

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
