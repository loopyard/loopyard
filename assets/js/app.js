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

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken}
})

liveSocket.connect()
window.liveSocket = liveSocket
