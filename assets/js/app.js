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

    this.handleEvent("scroll_bottom", () => {
      if (!this._userScrolledUp) this._scrollToBottom()
    })

    // Watch for messages appearing in the DOM (handle_params loads them
    // after mount, so the div is empty on first render).
    this._observeMessages()
  },

  updated() {
    // Nothing — all scrolling is driven by MutationObserver + push_event.
    // updated() was unreliable because LiveView doesn't always re-render
    // the hook's parent element when assigns change.
  },

  _scrollToBottom() {
    const el = document.getElementById("messages")
    if (el) el.scrollTop = el.scrollHeight
  },

  _observeMessages() {
    const el = document.getElementById("messages")
    if (!el) return

    // Scroll listener: track if user scrolled up
    el.addEventListener("scroll", () => {
      const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 50
      this._userScrolledUp = !atBottom
    }, { passive: true })

    // MutationObserver: scroll to bottom when new children appear
    // (messages loaded from handle_params, or new message from PubSub)
    const observer = new MutationObserver(() => {
      if (!this._userScrolledUp) {
        requestAnimationFrame(() => this._scrollToBottom())
      }
    })

    observer.observe(el, { childList: true, subtree: true })

    // Also scroll now in case messages already rendered
    requestAnimationFrame(() => this._scrollToBottom())
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
