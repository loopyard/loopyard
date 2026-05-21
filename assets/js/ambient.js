// Ambient player hook.
//
// Audio plays via the browser's native <audio> element pointed at
// /ambient/stream.mp3. The browser handles all the streaming,
// buffering, jitter, and decoding — we just toggle play/pause and
// tap the output for the SVG oscilloscope visualization.

// Ship any browser-side error back to the server log so the human
// debugging can read it without copy-pasting from DevTools.
function logToServer(label, data) {
  try {
    fetch("/ambient/diag", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ label, ...data, ts: Date.now() }),
      keepalive: true
    }).catch(() => {})
  } catch (_) {}
}

export function createAmbientHook() {
  return {
    mounted() {
      this._audio = this.el.querySelector("#ambient-audio")
      this._toggle = this.el.querySelector("#ambient-toggle")
      this._status = this.el.querySelector("#ambient-status")
      this._iconPlay = this.el.querySelector("#ambient-icon-play")
      this._iconPause = this.el.querySelector("#ambient-icon-pause")
      this._scopeLine = this.el.querySelector("#ambient-scope-line")

      this._ctx = null
      this._analyser = null
      this._rafId = null
      this._currentSrc = this._audio.src

      this._toggle.addEventListener("click", () => this._handleToggle())
      this._audio.addEventListener("playing", () => {
        this._setUI(true, "Streaming")
        logToServer("audio:playing", { src: this._audio.src })
      })
      this._audio.addEventListener("pause", () => {
        this._setUI(false, "Paused")
        logToServer("audio:pause", {})
      })
      this._audio.addEventListener("stalled", () => {
        logToServer("audio:stalled", {
          networkState: this._audio.networkState,
          readyState: this._audio.readyState
        })
      })
      this._audio.addEventListener("waiting", () => {
        logToServer("audio:waiting", {
          networkState: this._audio.networkState,
          readyState: this._audio.readyState
        })
      })
      this._audio.addEventListener("error", (e) => {
        const err = this._audio.error
        const codes = {
          1: "MEDIA_ERR_ABORTED",
          2: "MEDIA_ERR_NETWORK",
          3: "MEDIA_ERR_DECODE",
          4: "MEDIA_ERR_SRC_NOT_SUPPORTED"
        }
        const info = {
          code: err?.code,
          codeName: codes[err?.code] || "unknown",
          message: err?.message,
          networkState: this._audio.networkState,
          readyState: this._audio.readyState,
          src: this._audio.src,
          currentSrc: this._audio.currentSrc
        }
        console.error("[ambient] audio error", info, e)
        logToServer("audio:error", info)
        this._setUI(false, "Stream error (see console)")
      })

      // Surface uncaught exceptions on this page back to the server too
      window.addEventListener("error", (e) => {
        logToServer("window:error", {
          message: e.message,
          filename: e.filename,
          lineno: e.lineno,
          colno: e.colno,
          stack: e.error?.stack
        })
      })
      window.addEventListener("unhandledrejection", (e) => {
        logToServer("window:unhandledrejection", {
          reason: String(e.reason),
          stack: e.reason?.stack
        })
      })
    },

    destroyed() {
      this._stopAnimation()
      this._audio?.pause()
    },

    // LiveView re-renders when the user picks a different track,
    // changing the <audio src=...>. Browsers don't auto-reload on
    // src change — we have to call .load() (and resume playback if
    // we were playing).
    updated() {
      this._audio = this.el.querySelector("#ambient-audio")
      const newSrc = this._audio.src
      if (newSrc && newSrc !== this._currentSrc) {
        const wasPlaying = !this._audio.paused
        this._currentSrc = newSrc
        this._audio.load()
        if (wasPlaying) {
          this._audio.play().catch((err) => {
            console.error("[ambient] track-switch play failed", err)
          })
        }
      }
    },

    _handleToggle() {
      if (this._audio.paused) {
        this._ensureAnalyser()
        this._audio.play().catch((err) => {
          console.error("[ambient] play failed", err)
          logToServer("play:rejected", {
            name: err?.name,
            message: err?.message,
            stack: err?.stack
          })
          this._setUI(false, "Play failed")
        })
        this._startAnimation()
      } else {
        this._audio.pause()
        this._stopAnimation()
      }
    },

    // Tap the <audio> element into a WebAudio graph so we can read
    // its waveform for the SVG oscilloscope. Audio still plays
    // through the AudioContext's destination, not the audio
    // element's own output (createMediaElementSource takes over).
    _ensureAnalyser() {
      if (this._ctx) return

      const AudioCtor = window.AudioContext || window.webkitAudioContext
      this._ctx = new AudioCtor()
      const source = this._ctx.createMediaElementSource(this._audio)
      this._analyser = this._ctx.createAnalyser()
      this._analyser.fftSize = 1024
      this._analyser.smoothingTimeConstant = 0.6
      source.connect(this._analyser)
      this._analyser.connect(this._ctx.destination)
    },

    _setUI(playing, statusText) {
      if (playing) {
        this._iconPlay.classList.add("hidden")
        this._iconPause.classList.remove("hidden")
      } else {
        this._iconPlay.classList.remove("hidden")
        this._iconPause.classList.add("hidden")
      }
      if (this._status) this._status.textContent = statusText
    },

    _startAnimation() {
      if (this._rafId || !this._analyser) return
      const buf = new Uint8Array(this._analyser.fftSize)
      const width = 800
      const mid = 60

      const tick = () => {
        this._analyser.getByteTimeDomainData(buf)
        const step = Math.floor(buf.length / 80)
        let pts = ""
        for (let i = 0; i < buf.length; i += step) {
          const x = (i / buf.length) * width
          const y = mid + ((buf[i] - 128) / 128) * (mid - 10)
          pts += (pts ? " " : "") + x.toFixed(1) + "," + y.toFixed(1)
        }
        pts += " " + width + "," + mid.toFixed(1)
        this._scopeLine?.setAttribute("points", pts)
        this._rafId = requestAnimationFrame(tick)
      }
      this._rafId = requestAnimationFrame(tick)
    },

    _stopAnimation() {
      if (this._rafId) {
        cancelAnimationFrame(this._rafId)
        this._rafId = null
      }
      setTimeout(() => {
        this._scopeLine?.setAttribute("points", "0,60 800,60")
      }, 400)
    }
  }
}
