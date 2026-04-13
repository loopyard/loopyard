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
    this._initialScrollDone = false

    // Server pushes this when a new message arrives
    this.handleEvent("scroll_bottom", () => {
      if (!this._userScrolledUp) {
        const el = document.getElementById("messages")
        if (el) el.scrollTop = el.scrollHeight
      }
    })

    this._attachScrollListener()
  },

  updated() {
    const currentPath = window.location.pathname
    if (currentPath !== this._lastPath) {
      this._lastPath = currentPath
      this._userScrolledUp = false
      this._initialScrollDone = false
    }

    // Scroll to bottom ONCE after messages first render (handle_params loads them
    // after mount, so mounted() fires with an empty list). After that, only the
    // server's push_event("scroll_bottom") triggers scrolling — never updated().
    // This prevents fighting with the user's scroll on mobile.
    if (!this._initialScrollDone) {
      const el = document.getElementById("messages")
      if (el && el.scrollHeight > el.clientHeight) {
        this._initialScrollDone = true
        requestAnimationFrame(() => { el.scrollTop = el.scrollHeight })
      }
    }
  },

  _attachScrollListener() {
    const el = document.getElementById("messages")
    if (!el) return

    // Use a small delay so scroll events from programmatic scrolls settle
    // before we check position. Prevents touch-scroll on mobile from being
    // immediately overridden.
    el.addEventListener("scroll", () => {
      const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 50
      this._userScrolledUp = !atBottom
    }, { passive: true })
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

Hooks.ChatForm = {
  mounted() {
    const ta = this.el.querySelector("#chat-input")

    const submit = () => {
      const text = ta.value.trim()
      ta.value = ""
      ta.style.height = "auto"
      if (text) this.pushEvent("send_message", { message: text })
      ta.focus()
    }

    ta.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); submit() }
    })

    ta.addEventListener("input", () => {
      requestAnimationFrame(() => {
        ta.style.height = "auto"
        ta.style.height = Math.min(ta.scrollHeight, 200) + "px"
      })
    })

    this.el.addEventListener("submit", (e) => { e.preventDefault(); submit() })
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
