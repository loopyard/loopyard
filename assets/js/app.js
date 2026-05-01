import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {createTerminalHook} from "./terminal"

let Hooks = {}
Hooks.Terminal = createTerminalHook()

// Auto-scrolls #messages to bottom. Pauses when user scrolls up;
// resumes when they scroll back to the bottom.
//
// Strategy: scroll on every LiveView `updated()` callback. No
// MutationObserver, no polling — LiveView tells us when the DOM
// changed, and we scroll. Simple, works on mobile.
Hooks.ScrollBottom = {
  mounted() {
    this._userScrolledUp = false
    this._scrollEl = null
    this._bound = false

    this.handleEvent("scroll_bottom", () => {
      if (!this._userScrolledUp) this._scroll()
    })

    this._attach()
  },

  updated() {
    this._attach()
    if (!this._userScrolledUp) this._scroll()
  },

  _attach() {
    const el = document.getElementById("messages")
    if (!el || el === this._scrollEl) {
      // Same element, just scroll
      if (el && !this._userScrolledUp) this._scroll()
      return
    }

    // New #messages element (LiveView navigation)
    this._userScrolledUp = false
    this._scrollEl = el

    if (!this._bound) {
      // Single delegated scroll listener on the hook root — survives
      // element replacement. Checks if the scroll target is #messages.
      this.el.addEventListener("scroll", (e) => {
        if (e.target.id === "messages") {
          const t = e.target
          const atBottom = t.scrollHeight - t.scrollTop - t.clientHeight < 50
          this._userScrolledUp = !atBottom
        }
      }, { passive: true, capture: true })
      this._bound = true
    }

    this._scroll()
  },

  _scroll() {
    const el = this._scrollEl || document.getElementById("messages")
    if (el) el.scrollTop = el.scrollHeight
  }
}

// Auto-scroll element to bottom on every update (tail mode).
// Pauses when user scrolls up; resumes when they scroll back to bottom.
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
      ta.value = ""
      ta.style.height = "auto"
      this.pushEvent("send_message", { message: text })
      // Reset guard after a tick so the next message can be sent
      requestAnimationFrame(() => { sending = false })
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
