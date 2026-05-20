import { Socket } from "phoenix"

// LiveView hook that:
//  - Opens a Phoenix socket to /ambient
//  - Joins the "ambient:lobby" channel
//  - Receives binary 16-bit PCM chunks from the server
//  - Plays them via WebAudio with sample-accurate scheduling
//  - Updates an SVG oscilloscope polyline from an AnalyserNode
//
// All audio synthesis happens in Elixir (Loopyard.Ambient.Engine).
// The browser is a dumb player + visualizer.
export function createAmbientHook() {
  return {
    mounted() {
      this._ctx = null
      this._analyser = null
      this._nextStartTime = 0
      this._playing = false
      this._socket = null
      this._channel = null
      this._rafId = null
      this._gain = null

      const toggle = document.getElementById("ambient-toggle")
      const status = document.getElementById("ambient-status")

      toggle?.addEventListener("click", () => this._handleToggle(status))
    },

    destroyed() {
      this._teardown()
    },

    _handleToggle(status) {
      if (this._playing) {
        this._pause(status)
      } else {
        this._play(status)
      }
    },

    _play(status) {
      this._ensureContext()

      // Browser autoplay policy — must resume on user gesture.
      if (this._ctx.state === "suspended") {
        this._ctx.resume()
      }

      // Reset scheduling baseline so we don't try to play in the past
      // after a long pause.
      this._nextStartTime = this._ctx.currentTime + 0.1

      if (!this._channel) {
        this._connect()
      }

      this._channel.push("play", {})
      this._setPlayingUI(true, status, "Streaming")
      this._startAnimation()
    },

    _pause(status) {
      this._channel?.push("stop", {})
      this._setPlayingUI(false, status, "Paused")
      this._stopAnimation()
      // Ctx stays alive so resuming is instant; just stop scheduling
      // new buffers — the in-flight ones finish naturally.
    },

    _ensureContext() {
      if (this._ctx) return

      this._ctx = new (window.AudioContext || window.webkitAudioContext)({
        sampleRate: 44100
      })

      this._gain = this._ctx.createGain()
      this._gain.gain.value = 0.9

      this._analyser = this._ctx.createAnalyser()
      this._analyser.fftSize = 1024
      this._analyser.smoothingTimeConstant = 0.6

      this._gain.connect(this._analyser)
      this._analyser.connect(this._ctx.destination)
    },

    _connect() {
      this._socket = new Socket("/ambient", {})
      this._socket.connect()

      this._channel = this._socket.channel("ambient:lobby", {})

      this._channel.on("chunk", (payload) => {
        // payload is an ArrayBuffer of little-endian int16 samples.
        const samples = new Int16Array(payload)
        const floats = new Float32Array(samples.length)
        for (let i = 0; i < samples.length; i++) {
          floats[i] = samples[i] / 32768
        }

        const buffer = this._ctx.createBuffer(1, floats.length, 44100)
        buffer.copyToChannel(floats, 0)

        const src = this._ctx.createBufferSource()
        src.buffer = buffer
        src.connect(this._gain)

        const startAt = Math.max(this._nextStartTime, this._ctx.currentTime + 0.02)
        src.start(startAt)
        this._nextStartTime = startAt + buffer.duration
      })

      this._channel.join()
    },

    _setPlayingUI(playing, status, statusText) {
      this._playing = playing
      const iconPlay = document.getElementById("ambient-icon-play")
      const iconPause = document.getElementById("ambient-icon-pause")
      if (playing) {
        iconPlay?.classList.add("hidden")
        iconPause?.classList.remove("hidden")
      } else {
        iconPlay?.classList.remove("hidden")
        iconPause?.classList.add("hidden")
      }
      if (status) status.textContent = statusText
    },

    _startAnimation() {
      if (this._rafId) return

      const line = document.getElementById("ambient-scope-line")
      const buf = new Uint8Array(this._analyser.fftSize)
      const width = 800
      const height = 120
      const mid = height / 2

      const tick = () => {
        this._analyser.getByteTimeDomainData(buf)

        // Downsample to ~80 points for a clean SVG path.
        const step = Math.floor(buf.length / 80)
        let pts = ""
        for (let i = 0; i < buf.length; i += step) {
          const x = (i / buf.length) * width
          // buf[i] is 0-255, 128 = silence.
          const y = mid + ((buf[i] - 128) / 128) * (mid - 10)
          pts += (pts ? " " : "") + x.toFixed(1) + "," + y.toFixed(1)
        }
        // Close the rightmost edge so the polyline reaches the full width.
        pts += " " + width + "," + mid.toFixed(1)
        line?.setAttribute("points", pts)

        this._rafId = requestAnimationFrame(tick)
      }
      this._rafId = requestAnimationFrame(tick)
    },

    _stopAnimation() {
      if (this._rafId) {
        cancelAnimationFrame(this._rafId)
        this._rafId = null
      }
      // Reset the line to flat after a beat.
      setTimeout(() => {
        document
          .getElementById("ambient-scope-line")
          ?.setAttribute("points", "0,60 800,60")
      }, 400)
    },

    _teardown() {
      this._stopAnimation()
      this._channel?.leave()
      this._socket?.disconnect()
      this._channel = null
      this._socket = null
    }
  }
}
