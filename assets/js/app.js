import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {createTerminalHook} from "./terminal"
import {createAuralHook} from "aural"

let Hooks = {}
Hooks.Terminal = createTerminalHook()
Hooks.Aural = createAuralHook()

// ScrollBottom: lives on #chat-page (ancestor), scrolls #messages
// (descendant). Hooks on deeply nested elements (inside function
// components with phx-id) don't mount in LiveView — so the hook
// must live on the root-level element.
//
// Scrolls on every `updated()` callback and on mount. Pauses when
// user scrolls up; resumes when they scroll back to the bottom.
// #messages uses flex-direction: column-reverse — the browser anchors
// scroll to the bottom automatically. scrollTop=0 IS the bottom.
// No JS needed for initial scroll or new message scroll.
//
// This hook only handles:
// 1. Load-more: detect when user scrolls to the top (high scrollTop
//    in column-reverse) and fetch older messages
// 2. Scroll-to-bottom: when server pushes scroll_bottom event, reset
//    scrollTop to 0 (which is the bottom in column-reverse)
Hooks.ScrollBottom = {
  mounted() {
    this._loading = false
    this._bind()
  },

  updated() {
    this._bind()
  },

  _bind() {
    const el = document.getElementById("messages")
    if (!el || el === this._el) return
    this._el = el

    el.addEventListener("scroll", () => {
      // In column-reverse, scrollTop=0 is bottom. Large scrollTop = near top.
      // scrollTop is NEGATIVE in column-reverse in some browsers, positive in others.
      // The "top" (oldest messages) is at max scroll distance from 0.
      const maxScroll = el.scrollHeight - el.clientHeight
      const distFromTop = maxScroll - Math.abs(el.scrollTop)

      if (distFromTop < 300 && maxScroll > 300 && !this._loading) {
        this._loading = true
        this.pushEvent("load_more", {})
        setTimeout(() => { this._loading = false }, 5000)
      }
    }, { passive: true })

    this.handleEvent("scroll_bottom", () => {
      // Only auto-scroll if you're already AT/near the bottom. In
      // column-reverse, bottom is scrollTop ~ 0; a large |scrollTop|
      // means you scrolled up to read — don't yank you back down while
      // messages stream in. Auto-scroll resumes once you return to the
      // bottom. ~120px of slack so a tiny manual nudge still counts as
      // "at the bottom".
      if (Math.abs(el.scrollTop) < 120) {
        el.scrollTop = 0
      }
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
      let settled = false
      const settle = (ok) => {
        if (settled) return
        settled = true
        sending = false
        if (btn) btn.disabled = false
        if (ok) {
          ta.value = ""
          ta.style.height = "auto"
        } else {
          // Text is still in the box — just flag it so the user knows to retry.
          ta.style.boxShadow = "0 0 0 2px rgb(248 113 113)"
          setTimeout(() => { ta.style.boxShadow = "" }, 2500)
          ta.focus()
        }
      }

      const timer = setTimeout(() => settle(false), 6000)
      this.pushEvent("send_message", { message: text }, (reply) => {
        clearTimeout(timer)
        settle(reply && reply.ok)
      })
    }

    // Enter sends, Shift+Enter for newline
    ta.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send() }
    })

    // Auto-resize textarea
    ta.addEventListener("input", () => {
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

  }
}

// Renders markdown content and provides a copy-source button
Hooks.Markdown = {
  mounted() {
    this.render()
  },
  updated() {
    this.render()
  },
  render() {
    const source = this.el.dataset.source
    if (!source || !window.marked) return

    const container = this.el.querySelector(".markdown-body")
    if (container) {
      const renderer = new marked.Renderer()
      const origLink = renderer.link.bind(renderer)
      renderer.link = function(href, title, text) {
        const html = origLink(href, title, text)
        // Open all links in new tabs
        return html.replace('<a ', '<a target="_blank" rel="noopener noreferrer" ')
      }
      container.innerHTML = marked.parse(source, { breaks: true, renderer })
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
