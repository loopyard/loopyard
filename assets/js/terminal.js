import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import { WebLinksAddon } from "@xterm/addon-web-links"
import { ClipboardAddon } from "@xterm/addon-clipboard"
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
      // Make URLs in the output tappable — a tap opens a real browser tab.
      // This is how device-flow logins work from a phone: `gh auth login`,
      // `claude login`, `fly auth login` all PRINT the URL+code (then fail to
      // auto-open a browser, harmlessly, since the container is headless). The
      // tap is a user gesture, so it dodges popup blockers.
      term.loadAddon(new WebLinksAddon((_ev, uri) => window.open(uri, "_blank", "noopener")))
      // Honor OSC 52 clipboard writes — that's how TUIs like `claude login`'s
      // "(c to copy)" put a URL on the clipboard. xterm ignores OSC 52 by
      // default; this addon bridges it to the browser clipboard.
      term.loadAddon(new ClipboardAddon())
      term.open(this.el)

      let lastCols = 0, lastRows = 0
      // Fit xterm to its container AND tell the server PTY the new size, so the
      // remote shell wraps at the same width xterm renders. Guarded against the
      // zero-size measurement you get before layout/fonts settle.
      const syncFit = () => {
        try { fitAddon.fit() } catch (_) { return }
        if (!term.cols || !term.rows) return
        if (term.cols !== lastCols || term.rows !== lastRows) {
          lastCols = term.cols
          lastRows = term.rows
          if (channel.state === "joined") {
            channel.push("resize", { cols: term.cols, rows: term.rows })
          }
        }
      }

      const socket = new Socket("/terminal", {})
      socket.connect()

      const channel = socket.channel(`terminal:${container}`, {})

      channel.join()
        .receive("ok", () => {
          // Layout + web-font metrics aren't final on mount; fit after a frame,
          // and again once the mono font loads, then push the real size to the
          // PTY (the very first resize the server hears).
          requestAnimationFrame(syncFit)
          if (document.fonts && document.fonts.ready) {
            document.fonts.ready.then(syncFit)
          }
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
      const handleResize = () => {
        clearTimeout(resizeTimer)
        resizeTimer = setTimeout(syncFit, 150)
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
