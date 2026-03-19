import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

let Hooks = {}

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
    this.el.addEventListener("submit", () => {
      const input = this.el.querySelector("#chat-input")
      if (input) {
        setTimeout(() => { input.value = ""; input.focus() }, 10)
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

      // If source is a URL path, fetch the content first
      if (source.startsWith("/")) {
        fetch(source).then(r => r.text()).then(copyText)
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
