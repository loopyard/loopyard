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
// Clip: copy this element's data-copy to the clipboard, with a brief
// "Copied — paste on your Mac" confirmation. Used by the per-tool "Copy for Mac".
Hooks.Clip = {
  mounted() {
    this.el.addEventListener("click", () => {
      navigator.clipboard?.writeText(this.el.dataset.copy || "")
      const label = this.el.dataset.label || this.el.textContent
      this.el.textContent = "✓ Copied — paste on your Mac"
      setTimeout(() => { this.el.textContent = label }, 1600)
    })
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
        navigator.clipboard?.writeText(code.textContent)
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

    // Expand/collapse toggle
    if (btn) {
      btn.addEventListener("click", () => {
        this._expanded = !this._expanded
        if (this._expanded) {
          pre.style.maxHeight = "none"
          btn.textContent = "collapse"
        } else {
          pre.style.maxHeight = ""
          btn.textContent = "expand"
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
          if (status) status.classList.add("hidden")
        } else {
          // Text is still in the box — flag it AND say why, so a failed send is
          // never a silent red flash.
          ta.style.boxShadow = "0 0 0 2px rgb(248 113 113)"
          setTimeout(() => { ta.style.boxShadow = "" }, 2500)
          if (status) {
            status.textContent = reason || "Send didn't go through — your text is kept, press Send to retry."
            status.classList.remove("hidden")
          }
          ta.focus()
        }
      }

      const timer = setTimeout(() =>
        settle(false, "⚠ Couldn't reach the server — connection blip or the page is reloading. Your text is safe; press Send to retry."),
      6000)
      this.pushEvent("send_message", { message: text }, (reply) => {
        clearTimeout(timer)
        if (reply && reply.ok) settle(true)
        else settle(false, "⚠ The server rejected the send — make sure an agent is selected, then try again.")
      })
    }

    // Enter inserts a newline; you submit with the Send button (or, for
    // keyboard users, Cmd/Ctrl+Enter). Much friendlier on mobile — the return
    // key composes text instead of firing off a half-written message.
    ta.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); send() }
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
        navigator.clipboard.writeText(text).then(() => {
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

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken}
})

liveSocket.connect()
window.liveSocket = liveSocket

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
})()
