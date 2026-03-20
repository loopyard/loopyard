import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {createTerminalHook} from "./terminal"

let Hooks = {}
Hooks.Terminal = createTerminalHook()

// Auto-scrolls messages to bottom on new content
Hooks.ScrollBottom = {
  mounted() {
    this.handleEvent("scroll_bottom", () => {
      const el = document.getElementById("messages")
      if (el) el.scrollTop = el.scrollHeight
    })
  }
}

// Clears input after submit, focuses on agent select
Hooks.ChatForm = {
  mounted() {
    const textarea = this.el.querySelector("#chat-input")

    // Enter submits, Shift+Enter adds newline
    if (textarea) {
      textarea.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && !e.shiftKey) {
          e.preventDefault()
          this.el.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))
        }
      })

      // Auto-resize textarea
      textarea.addEventListener("input", () => {
        textarea.style.height = "auto"
        textarea.style.height = Math.min(textarea.scrollHeight, 200) + "px"
      })
    }

    this.el.addEventListener("submit", () => {
      if (textarea) {
        setTimeout(() => {
          textarea.value = ""
          textarea.style.height = "auto"
          textarea.focus()
        }, 10)
      }
    })

    this.handleEvent("focus_input", () => {
      setTimeout(() => {
        const input = document.getElementById("chat-input")
        if (input) input.focus()
      }, 100)
    })
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
        fetch(source).then(r => r.ok ? r.text() : source).then(copyText)
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
