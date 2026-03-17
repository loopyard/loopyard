import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {Terminal} from "@xterm/xterm"

let Hooks = {}

// --- Screen Size Hook ---
// Measures available space and reports ideal terminal cols/rows to the server.
// This runs on the main container so it's always mounted.
Hooks.ScreenSize = {
  mounted() {
    // Report once on mount so the new-agent form gets good defaults
    this._report()
    // Re-report on orientation change (mobile rotation)
    this._orientationHandler = () => setTimeout(() => this._report(), 200)
    window.addEventListener("orientationchange", this._orientationHandler)
  },
  destroyed() {
    if (this._orientationHandler) window.removeEventListener("orientationchange", this._orientationHandler)
  },
  _report() {
    // Estimate how many cols/rows fit in the main panel area.
    // Main panel = screen width minus sidebar (320px on md+, 0 on mobile)
    const isMobile = window.innerWidth < 768
    const sidebarWidth = isMobile ? 0 : 320
    const availWidth = window.innerWidth - sidebarWidth - 32 // 16px padding
    const availHeight = window.innerHeight - 140 // header + agent header + padding

    // Character cell size at font size 13 (JetBrains Mono)
    const charWidth = 7.8
    const charHeight = 17

    // At minimum font size 11, chars are proportionally smaller
    const minFontSize = 11
    const scaledCharWidth = charWidth * (minFontSize / 13)

    const cols = Math.max(40, Math.min(300, Math.floor(availWidth / scaledCharWidth)))
    const rows = Math.max(10, Math.min(100, Math.floor(availHeight / charHeight)))

    this.pushEvent("screen_size", {cols, rows})
  }
}

// --- Connection Status Hook ---
// Shows a banner when the WebSocket disconnects and auto-recovers
Hooks.ConnectionStatus = {
  mounted() {
    this.banner = this.el
    // LiveSocket fires phx:disconnect / phx:connect on the window
    window.addEventListener("phx:disconnect", () => {
      this.banner.classList.remove("hidden")
    })
    window.addEventListener("phx:connect", () => {
      this.banner.classList.add("hidden")
    })
  }
}

// --- Terminal Hook ---
Hooks.Terminal = {
  mounted() {
    // Default size — will be updated by init_terminal with actual PTY dimensions
    this._ptyCols = 120
    this._ptyRows = 40

    this.term = new Terminal({
      cols: this._ptyCols,
      rows: this._ptyRows,
      fontSize: this._calcFontSize(this._ptyCols),
      fontFamily: '"JetBrains Mono", "SF Mono", "Menlo", monospace',
      theme: this.getTheme(),
      cursorBlink: true,
      cursorStyle: "bar",
      scrollback: 10000,
      convertEol: true,
    })

    this.term.open(this.el)

    // Send every keystroke to the server as raw input.
    // Filter out focus report sequences (\e[I = focus in, \e[O = focus out)
    // which xterm.js sends but confuse the PTY on mobile.
    this.term.onData((data) => {
      if (data === "\x1b[I" || data === "\x1b[O") return
      this.pushEvent("terminal_input", {data: data})
    })

    // Prevent ALL click/touch events inside the terminal from bubbling
    // up to LiveView (which would trigger phx-click handlers like toggle_sidebar).
    // This is critical on mobile where taps near the keyboard can propagate.
    this.el.addEventListener("click", (e) => {
      e.stopPropagation()
      this.term.focus()
    })
    this.el.addEventListener("touchend", (e) => {
      e.stopPropagation()
      if (!this._touchMoved) {
        this.term.focus()
      }
      this._touchMoved = false
    })
    this.el.addEventListener("touchmove", (e) => {
      this._touchMoved = true
    })
    this.el.addEventListener("touchstart", (e) => {
      e.stopPropagation()
      this._touchMoved = false
    })

    // Also prevent keyboard events from bubbling out of the terminal
    this.el.addEventListener("keydown", (e) => e.stopPropagation())
    this.el.addEventListener("keyup", (e) => e.stopPropagation())
    this.el.addEventListener("keypress", (e) => e.stopPropagation())

    // Drag-and-drop visual indicator
    let dragCounter = 0
    this.el.addEventListener("dragenter", (e) => {
      e.preventDefault()
      dragCounter++
      const indicator = document.getElementById("drop-indicator")
      if (indicator) indicator.classList.remove("hidden")
    })
    this.el.addEventListener("dragleave", (e) => {
      dragCounter--
      if (dragCounter <= 0) {
        dragCounter = 0
        const indicator = document.getElementById("drop-indicator")
        if (indicator) indicator.classList.add("hidden")
      }
    })
    this.el.addEventListener("dragover", (e) => {
      e.preventDefault()
    })
    this.el.addEventListener("drop", () => {
      dragCounter = 0
      const indicator = document.getElementById("drop-indicator")
      if (indicator) indicator.classList.add("hidden")
    })

    // Recalculate font size when container changes (e.g. orientation change)
    this._resizeObserver = new ResizeObserver(() => {
      const newSize = this._calcFontSize(this._ptyCols)
      if (this.term.options.fontSize !== newSize) {
        this.term.options.fontSize = newSize
      }
    })
    this._resizeObserver.observe(this.el)

    // Listen for dark mode changes
    this.darkModeQuery = window.matchMedia("(prefers-color-scheme: dark)")
    this.darkModeListener = () => {
      this.term.options.theme = this.getTheme()
    }
    this.darkModeQuery.addEventListener("change", this.darkModeListener)

    // Handle server push events
    this.handleEvent("init_terminal", ({output, cols, rows}) => {
      if (cols && rows) {
        this._ptyCols = cols
        this._ptyRows = rows
        this.term.options.fontSize = this._calcFontSize(cols)
        this.term.resize(cols, rows)
      }
      this.term.clear()
      if (output) {
        this.term.write(output)
      }
      this.term.focus()
    })

    this.handleEvent("terminal_data", ({data}) => {
      this.term.write(data)
    })

    this.handleEvent("terminal_resize", ({cols, rows}) => {
      this._ptyCols = cols
      this._ptyRows = rows
      this.term.options.fontSize = this._calcFontSize(cols)
      this.term.resize(cols, rows)
    })
  },

  destroyed() {
    if (this._resizeObserver) this._resizeObserver.disconnect()
    if (this.darkModeQuery) this.darkModeQuery.removeEventListener("change", this.darkModeListener)
    if (this.term) this.term.dispose()
  },

  // Calculate font size — never go below 11px (readability floor).
  // If 120 cols can't fit at 11px, the terminal scrolls horizontally instead.
  _calcFontSize(ptyCols) {
    const containerWidth = this.el.clientWidth - 16 // 8px padding each side
    const baseCharWidth = 7.8 // JetBrains Mono at 13px ≈ 7.8px per char
    const neededWidth = ptyCols * baseCharWidth
    if (containerWidth > 0 && containerWidth < neededWidth) {
      return Math.max(11, Math.floor(13 * containerWidth / neededWidth))
    }
    return 13
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
