import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {createTerminalHook} from "./terminal"

let Hooks = {}
Hooks.Terminal = createTerminalHook()

// ScrollBottom: lives on #chat-page (ancestor), scrolls #messages
// (descendant). Hooks on deeply nested elements (inside function
// components with phx-id) don't mount in LiveView — so the hook
// must live on the root-level element.
//
// Scrolls on every `updated()` callback and on mount. Pauses when
// user scrolls up; resumes when they scroll back to the bottom.
Hooks.ScrollBottom = {
  mounted() {
    this._userScrolledUp = false
    this._pendingPrepend = false
    this._loading = false
    this._bindScroll()
    this._scrollToBottom()

    this.handleEvent("scroll_bottom", () => {
      if (!this._userScrolledUp) this._scrollToBottom()
    })
  },

  updated() {
    this._bindScroll()
    const el = document.getElementById("messages")
    if (!el) return

    // Detect prepend: scrollHeight grew significantly while user was
    // scrolled up AND we triggered a load_more. Correct scroll position
    // so the same content stays in view.
    if (this._loading && this._snapshotHeight && el.scrollHeight > this._snapshotHeight + 100) {
      const added = el.scrollHeight - this._snapshotHeight
      el.scrollTop = this._snapshotTop + added
      this._loading = false
      this._snapshotHeight = el.scrollHeight
      this._snapshotTop = el.scrollTop
      return
    }

    this._snapshotHeight = el.scrollHeight
    this._snapshotTop = el.scrollTop

    if (!this._userScrolledUp) this._scrollToBottom()
  },

  _bindScroll() {
    const el = document.getElementById("messages")
    if (!el || el === this._boundEl) return
    this._boundEl = el
    this._userScrolledUp = false

    el.addEventListener("scroll", () => {
      const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 50
      this._userScrolledUp = !atBottom

      // Snapshot scroll state on every scroll so we have the pre-patch
      // values when messages_prepended fires
      this._captureScroll()

      // Load more when near the top
      if (el.scrollTop < 200 && !this._loading) {
        this._loading = true
        this.pushEvent("load_more", {})
        setTimeout(() => { this._loading = false }, 3000)
      }
    }, { passive: true })
  },

  _scrollToBottom() {
    const el = document.getElementById("messages")
    if (!el) return
    el.scrollTop = el.scrollHeight
    // Single delayed scroll for layout that resolves after the patch
    requestAnimationFrame(() => { if (el) el.scrollTop = el.scrollHeight })
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
