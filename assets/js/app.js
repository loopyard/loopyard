import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {createTerminalHook} from "./terminal"

let Hooks = {}
Hooks.Terminal = createTerminalHook()

// Auto-scrolls messages to bottom — but only if the user hasn't scrolled up.
// Once they scroll up to read, we leave them alone. Resumes when they
// scroll back to the bottom.
Hooks.ScrollBottom = {
  mounted() {
    this._userScrolledUp = false
    this._lastPath = window.location.pathname
    this._lastHeight = 0
    this._setupScroll()

    this.handleEvent("scroll_bottom", () => {
      if (!this._userScrolledUp) {
        const el = document.getElementById("messages")
        if (el) el.scrollTop = el.scrollHeight
      }
    })
  },

  updated() {
    const currentPath = window.location.pathname
    if (currentPath !== this._lastPath) {
      // Navigated to a different agent/page — reset scroll state
      this._lastPath = currentPath
      this._userScrolledUp = false
      this._lastHeight = 0
      this._setupScroll()
      return
    }

    // Content changed (messages loaded, new message arrived).
    // Scroll to bottom unless user has scrolled up to read.
    if (!this._userScrolledUp) {
      const el = document.getElementById("messages")
      if (el && el.scrollHeight !== this._lastHeight) {
        this._lastHeight = el.scrollHeight
        requestAnimationFrame(() => { el.scrollTop = el.scrollHeight })
      }
    }
  },

  _setupScroll() {
    const el = document.getElementById("messages")
    if (el) {
      requestAnimationFrame(() => {
        el.scrollTop = el.scrollHeight
        this._lastHeight = el.scrollHeight
      })

      if (!this._scrollListenerAdded) {
        el.addEventListener("scroll", () => {
          const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 50
          this._userScrolledUp = !atBottom
        })
        this._scrollListenerAdded = true
      }
    }
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

// Clears input after submit, focuses on agent select
Hooks.ChatForm = {
  mounted() {
    this._lastSent = null  // tracks the last sent text to prevent dupes
    const textarea = this.el.querySelector("#chat-input")
    this._textarea = textarea

    if (textarea) {
      // Enter submits, Shift+Enter adds newline
      textarea.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && !e.shiftKey) {
          e.preventDefault()
          this._submit()
        }
      })

      // Auto-resize textarea
      textarea.addEventListener("input", () => {
        textarea.style.height = "auto"
        textarea.style.height = Math.min(textarea.scrollHeight, 200) + "px"
      })
    }

    // Intercept native form submit (Send button click)
    this.el.addEventListener("submit", (e) => {
      e.preventDefault()
      this._submit()
    })

    this.handleEvent("focus_input", () => {
      if (this._textarea) this._textarea.focus()
    })
  },

  _submit() {
    const textarea = this._textarea
    if (!textarea) return

    // Grab and clear atomically — the buffer is consumed in one shot.
    // Any subsequent submit (double-click, rapid Enter) reads "" and no-ops.
    const text = textarea.value.trim()
    textarea.value = ""
    textarea.style.height = "auto"

    if (!text) return

    this.pushEvent("send_message", { message: text })
    textarea.focus()
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
      container.innerHTML = marked.parse(source, { breaks: true })
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
