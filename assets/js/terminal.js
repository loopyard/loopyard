import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import { Socket } from "phoenix"

// Track active terminal connections globally so we can clean up
// stale connections on remount (longpoll reconnects, LiveView navigation)
const activeTerminals = new Map()

export function createTerminalHook() {
  return {
    mounted() {
      const container = this.el.dataset.container
      if (!container) return

      // Clean up any existing terminal for this container
      // (prevents double-output from stale connections on reconnect)
      const existing = activeTerminals.get(container)
      if (existing) {
        existing.channel.leave()
        existing.socket.disconnect()
        existing.term.dispose()
        window.removeEventListener("resize", existing.resizeHandler)
        activeTerminals.delete(container)
      }

      const term = new Terminal({
        cursorBlink: true,
        fontSize: 14,
        fontFamily: "'JetBrains Mono', 'Fira Code', monospace",
        theme: {
          background: "#18181b",
          foreground: "#e4e4e7",
          cursor: "#a78bfa",
          selectionBackground: "#3f3f46"
        }
      })

      const fitAddon = new FitAddon()
      term.loadAddon(fitAddon)
      term.open(this.el)
      fitAddon.fit()

      const socket = new Socket("/terminal", {})
      socket.connect()

      const channel = socket.channel(`terminal:${container}`, {})

      channel.join()
        .receive("ok", () => {
          term.write("\r\n\x1b[32mConnected to " + container + "\x1b[0m\r\n\r\n")
        })
        .receive("error", (resp) => {
          term.write("\r\n\x1b[31mFailed to connect: " + JSON.stringify(resp) + "\x1b[0m\r\n")
        })

      // Clear screen for all viewers:
      // - Cmd+K (macOS) / Ctrl+K: clear scrollback
      // - Ctrl+L: standard terminal clear — also clears server buffer
      //   so late joiners don't get stale output
      term.attachCustomKeyEventHandler((ev) => {
        if (ev.type !== "keydown") return true

        if (ev.key === "k" && (ev.metaKey || ev.ctrlKey)) {
          ev.preventDefault()
          channel.push("clear")
          return false
        }

        if (ev.key === "l" && ev.ctrlKey && !ev.metaKey) {
          // Let Ctrl+L pass through to the shell (it sends \x0c which
          // the shell handles), but also clear the server buffer
          channel.push("clear")
          return true
        }

        return true
      })

      channel.on("clear", () => {
        term.clear()
      })

      term.onData((data) => {
        channel.push("input", { data })
      })

      channel.on("output", ({ data }) => {
        term.write(data)
      })

      channel.on("exit", ({ code }) => {
        term.write(`\r\n\x1b[33mSession exited (code ${code})\x1b[0m\r\n`)
        channel.leave()
        activeTerminals.delete(container)
      })

      let resizeTimer = null
      let lastCols = 0, lastRows = 0
      const handleResize = () => {
        clearTimeout(resizeTimer)
        resizeTimer = setTimeout(() => {
          fitAddon.fit()
          if (term.cols !== lastCols || term.rows !== lastRows) {
            lastCols = term.cols
            lastRows = term.rows
            channel.push("resize", { cols: term.cols, rows: term.rows })
          }
        }, 150)
      }

      window.addEventListener("resize", handleResize)
      new ResizeObserver(handleResize).observe(this.el.parentElement)

      // Store for cleanup
      this._container = container
      this._term = term
      this._channel = channel
      this._socket = socket
      this._resizeHandler = handleResize

      // Track globally
      activeTerminals.set(container, {
        term, channel, socket, resizeHandler: handleResize
      })
    },

    destroyed() {
      const container = this._container
      if (this._channel) this._channel.leave()
      if (this._socket) this._socket.disconnect()
      if (this._term) this._term.dispose()
      if (this._resizeHandler) window.removeEventListener("resize", this._resizeHandler)
      if (container) activeTerminals.delete(container)
    }
  }
}
