import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {Terminal} from "@xterm/xterm"

// Fixed terminal size — must match PTY size in agent.ex
const COLS = 120
const ROWS = 40

let Hooks = {}

Hooks.Terminal = {
  mounted() {
    this.term = new Terminal({
      cols: COLS,
      rows: ROWS,
      fontSize: 13,
      fontFamily: '"JetBrains Mono", "SF Mono", "Menlo", monospace',
      theme: this.getTheme(),
      cursorBlink: true,
      cursorStyle: "bar",
      scrollback: 10000,
      convertEol: true,
    })

    this.term.open(this.el)

    // Send every keystroke to the server as raw input
    this.term.onData((data) => {
      this.pushEvent("terminal_input", {data: data})
    })

    // Focus terminal on click
    this.el.addEventListener("click", () => this.term.focus())

    // Listen for dark mode changes
    this.darkModeQuery = window.matchMedia("(prefers-color-scheme: dark)")
    this.darkModeListener = () => {
      this.term.options.theme = this.getTheme()
    }
    this.darkModeQuery.addEventListener("change", this.darkModeListener)

    // Handle server push events
    this.handleEvent("init_terminal", ({output}) => {
      this.term.clear()
      if (output) {
        this.term.write(output)
      }
      this.term.focus()
    })

    this.handleEvent("terminal_data", ({data}) => {
      this.term.write(data)
    })
  },

  destroyed() {
    if (this.darkModeQuery) this.darkModeQuery.removeEventListener("change", this.darkModeListener)
    if (this.term) this.term.dispose()
  },

  getTheme() {
    const isDark = window.matchMedia("(prefers-color-scheme: dark)").matches
    if (isDark) {
      return {
        background: "#18181b",
        foreground: "#d4d4d8",
        cursor: "#d4d4d8",
        selectionBackground: "#3f3f4640",
        black: "#27272a",
        red: "#f87171",
        green: "#4ade80",
        yellow: "#facc15",
        blue: "#60a5fa",
        magenta: "#c084fc",
        cyan: "#22d3ee",
        white: "#e4e4e7",
        brightBlack: "#52525b",
        brightRed: "#fca5a5",
        brightGreen: "#86efac",
        brightYellow: "#fde68a",
        brightBlue: "#93c5fd",
        brightMagenta: "#d8b4fe",
        brightCyan: "#67e8f9",
        brightWhite: "#fafafa",
      }
    } else {
      return {
        background: "#ffffff",
        foreground: "#18181b",
        cursor: "#18181b",
        selectionBackground: "#d4d4d840",
        black: "#18181b",
        red: "#dc2626",
        green: "#16a34a",
        yellow: "#ca8a04",
        blue: "#2563eb",
        magenta: "#9333ea",
        cyan: "#0891b2",
        white: "#f4f4f5",
        brightBlack: "#71717a",
        brightRed: "#ef4444",
        brightGreen: "#22c55e",
        brightYellow: "#eab308",
        brightBlue: "#3b82f6",
        brightMagenta: "#a855f7",
        brightCyan: "#06b6d4",
        brightWhite: "#fafafa",
      }
    }
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
