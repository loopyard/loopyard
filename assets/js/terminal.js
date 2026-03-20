import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import { Socket } from "phoenix"

export function createTerminalHook() {
  return {
    mounted() {
      const container = this.el.dataset.container
      if (!container) return

      // Create xterm instance
      const term = new Terminal({
        cursorBlink: true,
        fontSize: 13,
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

      // Connect to Phoenix Channel
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

      // Terminal input → channel
      term.onData((data) => {
        channel.push("input", { data })
      })

      // Channel output → terminal
      channel.on("output", ({ data }) => {
        term.write(data)
      })

      channel.on("exit", ({ code }) => {
        term.write(`\r\n\x1b[33mSession exited (code ${code})\x1b[0m\r\n`)
      })

      // Handle resize
      const handleResize = () => {
        fitAddon.fit()
        channel.push("resize", { cols: term.cols, rows: term.rows })
      }

      window.addEventListener("resize", handleResize)
      new ResizeObserver(handleResize).observe(this.el)

      // Store for cleanup
      this._term = term
      this._channel = channel
      this._socket = socket
      this._resizeHandler = handleResize
    },

    destroyed() {
      if (this._channel) this._channel.leave()
      if (this._socket) this._socket.disconnect()
      if (this._term) this._term.dispose()
      window.removeEventListener("resize", this._resizeHandler)
    }
  }
}
