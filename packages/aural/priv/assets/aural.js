// Aural player hook.
//
// Audio plays via the browser's native <audio> element pointed at
// /aural/stream.mp3. The browser handles all the streaming,
// buffering, jitter, and decoding — we just toggle play/pause and
// tap the output for the SVG oscilloscope visualization.

// Ship any browser-side error back to the server log so the human
// debugging can read it without copy-pasting from DevTools.
function logToServer(label, data) {
  try {
    fetch("/aural/diag", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ label, ...data, ts: Date.now() }),
      keepalive: true
    }).catch(() => {})
  } catch (_) {}
}

export function createAuralHook() {
  return {
    mounted() {
      this._audio = this.el.querySelector("#aural-audio")
      this._toggle = this.el.querySelector("#aural-toggle")
      this._toggleLabel = this.el.querySelector("#aural-toggle-label")
      this._status = this.el.querySelector("#aural-status")
      this._iconPlay = this.el.querySelector("#aural-icon-play")
      this._iconPause = this.el.querySelector("#aural-icon-pause")
      this._scopeLine = this.el.querySelector("#aural-scope-line")

      this._ctx = null
      this._analyser = null
      this._rafId = null
      this._currentSrc = this._audio.src

      this._toggle.addEventListener("click", () => this._handleToggle())

      // Both track rows and chime buttons need to act in the same
      // click tick — going through a server round-trip loses the
      // user-gesture token in Safari and audio.play() rejects with
      // NotAllowedError. Track rows ALSO fire phx-click for
      // server-side state; chime buttons are pure JS (data-chime
      // attr only) so the LV is uninvolved.
      this.el.addEventListener("click", (e) => {
        const trackBtn = e.target.closest('button[phx-click="pick_track"]')
        if (trackBtn) {
          this._startPlayback()
          return
        }
        const chimeBtn = e.target.closest('button[data-chime]')
        if (chimeBtn) {
          const kind = chimeBtn.getAttribute("data-chime")
          if (kind) this._playChime(kind)
        }
      })

      // Kept as a fallback for any future server-initiated play
      // request (e.g. "tune everyone in now").
      this.handleEvent("play", () => this._startPlayback())

      // Cache references to the preloaded chime audio elements. The
      // server pushes an `alert` event when a chime fires (button
      // click or system event); we play the matching one with
      // near-zero latency — WS RTT only, no decode buffer.
      this._chimes = {
        done: this.el.querySelector("#aural-chime-done"),
        attention: this.el.querySelector("#aural-chime-attention"),
        alert: this.el.querySelector("#aural-chime-alert")
      }
      this.handleEvent("alert", ({ kind }) => this._playChime(kind))

      // Server-pushed bed waveform. Safari can't analyse the
      // streaming MP3 directly via WebAudio, so the server sends a
      // downsampled snapshot of every chunk (16 samples in [-1,1]
      // per 100ms = 160Hz effective rate). The ring buffer holds
      // the last 80 samples = ~500ms of bed audio.
      this._waveBuf = new Float32Array(80)
      this._waveIdx = 0
      this._lastPeak = 0
      this.handleEvent("peak", ({ p, s }) => {
        this._lastPeak = p
        if (!s) return
        for (let i = 0; i < s.length; i++) {
          this._waveBuf[this._waveIdx] = s[i]
          this._waveIdx = (this._waveIdx + 1) % this._waveBuf.length
        }
      })

      // Scope animates from the moment the page is alive — server
      // peaks drive the bed visualization regardless of whether the
      // user has clicked play. Tells them the channel is alive.
      this._startAnimation()
      this._audio.addEventListener("playing", () => {
        this._setUI("playing", "Streaming")
        logToServer("audio:playing", { src: this._audio.src })
      })
      this._audio.addEventListener("pause", () => {
        this._setUI("paused", "Paused")
        logToServer("audio:pause", {})
      })
      // `waiting` fires when the player wants to play but has
      // outrun its buffer — that's the "loading" state the user
      // notices. `stalled` is similar (network slowed). Both
      // surface as "Loading" so the toggle label tells the truth
      // about why nothing's coming out of the speakers yet.
      this._audio.addEventListener("waiting", () => {
        this._setUI("loading", "Loading")
        logToServer("audio:waiting", {
          networkState: this._audio.networkState,
          readyState: this._audio.readyState
        })
      })
      this._audio.addEventListener("stalled", () => {
        this._setUI("loading", "Loading")
        logToServer("audio:stalled", {
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
        console.error("[aural] audio error", info, e)
        logToServer("audio:error", info)
        this._setUI("paused", "Stream error (see console)")
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
      this._audio = this.el.querySelector("#aural-audio")
      // Re-query scope line in case morphdom replaced the SVG
      // subtree — stale reference is the silent way to make the
      // viz flat-line after a re-render.
      this._scopeLine = this.el.querySelector("#aural-scope-line")
      const newSrc = this._audio.src
      if (newSrc && newSrc !== this._currentSrc) {
        const wasPlaying = !this._audio.paused
        this._currentSrc = newSrc
        this._audio.load()
        if (wasPlaying) {
          this._audio.play().catch((err) => {
            console.error("[aural] track-switch play failed", err)
          })
        }
      }
    },

    // Play a preloaded chime. Reset currentTime so rapid repeats
    // re-fire cleanly instead of stalling on the first decode.
    // If play() rejects (autoplay block, no gesture yet), just log
    // and move on — the chime is non-critical.
    _playChime(kind) {
      const el = this._chimes?.[kind]
      if (!el) return
      // First chime click can be the first user gesture — set up
      // the WebAudio graph here so the chime gets visualized on the
      // oscilloscope. Idempotent.
      this._ensureAnalyser()
      try {
        el.currentTime = 0
      } catch (_) {}
      el.play().catch((err) => {
        logToServer("chime:rejected", { kind, name: err?.name, message: err?.message })
      })
    },

    _handleToggle() {
      if (this._audio.paused) {
        this._startPlayback()
      } else {
        this._audio.pause()
        // Don't stop the rAF loop — it keeps running so chimes still
        // draw on the scope even while the bed is paused. The scope's
        // tick reads `audio.paused` and renders flat for the bed.
      }
    },

    // Start (or restart) playback of the current <audio> source.
    // Called from the dedicated toggle and from track-row clicks.
    // Immediately flips the UI to "Loading" — the browser doesn't
    // emit `waiting` until it actively underflows, which means the
    // user sees no feedback during the initial buffer fill.
    _startPlayback() {
      this._ensureAnalyser()
      this._setUI("loading", "Loading")
      this._audio.play().catch((err) => {
        console.error("[aural] play failed", err)
        logToServer("play:rejected", {
          name: err?.name,
          message: err?.message,
          stack: err?.stack
        })
        this._setUI("paused", "Play failed")
      })
      // Animation already running since mount; rAF tick reads
      // audio.paused, so no need to (re)start.
    },

    // Tap every audio element into a single WebAudio graph so the
    // analyser sees both bed and chime signals. Audio plays through
    // the AudioContext destination, not each element's own output —
    // createMediaElementSource takes over the element. Idempotent;
    // safe to call before any kind of playback (bed, track, chime).
    _ensureAnalyser() {
      if (this._ctx) {
        // Browsers (especially Safari) frequently leave the
        // AudioContext in "suspended" state across user
        // interactions. If we don't explicitly resume, the analyser
        // reads pure silence and the oscilloscope flat-lines even
        // though the audio is playing through the WebAudio graph.
        if (this._ctx.state === "suspended") {
          this._ctx.resume().catch(() => {})
        }
        return
      }

      const AudioCtor = window.AudioContext || window.webkitAudioContext
      this._ctx = new AudioCtor()
      this._analyser = this._ctx.createAnalyser()
      this._analyser.fftSize = 1024
      this._analyser.smoothingTimeConstant = 0.6
      this._analyser.connect(this._ctx.destination)

      // Route the CHIMES through the analyser — they're preloaded
      // WAVs and Safari can capture them via createMediaElementSource
      // fine. The bed audio is deliberately NOT routed: Safari can't
      // capture chunked-streaming MP3 via this API. The bed plays
      // natively, and the scope's bed portion comes from
      // server-pushed peak amplitudes (see this._peakBuf above).
      const sources = Object.values(this._chimes || {})
      for (const el of sources) {
        if (!el) continue
        try {
          const src = this._ctx.createMediaElementSource(el)
          src.connect(this._analyser)
        } catch (err) {
          logToServer("audio:source-failed", {
            id: el.id,
            name: err?.name,
            message: err?.message
          })
        }
      }

      // Animation already started in mount(). Once this analyser
      // exists, the rAF tick begins reading it for chime visuals.

      // Even the very first creation can land suspended — Safari
      // ships AudioContext in suspended state until explicitly
      // resumed inside a user gesture. We're inside a click handler,
      // so this resume call counts.
      if (this._ctx.state === "suspended") {
        this._ctx.resume().catch(() => {})
      }
    },

    // state: "playing" | "paused" | "loading"
    // - playing: pause icon + "Pause" label (button toggles to stop)
    // - paused:  play icon  + "Play"  label (button toggles to start)
    // - loading: play icon  + "Loading" label (we're between user
    //            intent to play and audio actually flowing)
    _setUI(state, statusText) {
      if (state === "playing") {
        this._iconPlay.classList.add("hidden")
        this._iconPause.classList.remove("hidden")
        if (this._toggleLabel) this._toggleLabel.textContent = "Pause"
      } else {
        // paused or loading — both show the play icon
        this._iconPlay.classList.remove("hidden")
        this._iconPause.classList.add("hidden")
        if (this._toggleLabel) {
          this._toggleLabel.textContent = state === "loading" ? "Loading" : "Play"
        }
      }
      if (this._status) this._status.textContent = statusText
    },

    // Animation can start even before _ensureAnalyser runs — the
    // server-pushed peak buffer is enough to draw the bed waveform.
    // Local analyser data is added on top when chimes play.
    _startAnimation() {
      if (this._rafId) return
      const width = 800
      const mid = 60
      const amp = mid - 10 // max vertical excursion from mid
      // Track-domain buffer for chime samples (only present once
      // the WebAudio graph has been built — i.e. after a click).
      let timeBuf = null

      const tick = () => {
        // Sample-accurate chime waveform if available (Chrome and
        // Safari can both decode preloaded WAVs into WebAudio).
        if (this._analyser) {
          if (!timeBuf || timeBuf.length !== this._analyser.fftSize) {
            timeBuf = new Uint8Array(this._analyser.fftSize)
          }
          this._analyser.getByteTimeDomainData(timeBuf)
        }

        // Server-pushed peaks drive the bed waveform regardless of
        // whether this client has hit Play. That's the point of
        // server-side downsampling: the channel is always alive,
        // every visitor sees it move, the Play button is for joining
        // the audible side of what's already visibly going on.

        // 80 sample points across the scope width. The wave buffer
        // is exactly 80 long, so each column reads one sample.
        const N = 80
        const waveBuf = this._waveBuf
        const waveHead = this._waveIdx
        const samplesPerPoint = timeBuf ? Math.floor(timeBuf.length / N) : 0

        // Visual gain — bed audio is fairly low-amplitude (ambient
        // pads ~ 0.3-0.4 peak), so we scale it up so the wave is
        // visible without clipping. Chimes are louder and already
        // close to the rails.
        const bedGain = 2.0

        let pts = ""
        for (let i = 0; i < N; i++) {
          const x = (i / N) * width

          // Bed contribution: read the i-th oldest sample from the
          // ring buffer. Real PCM, so this is an actual waveform —
          // not a fake LFO modulation.
          const slot = (waveHead + i) % waveBuf.length
          const bedY = waveBuf[slot] * amp * bedGain

          // Chime contribution: time-domain sample at this column.
          let chimeY = 0
          if (timeBuf) {
            const sample = timeBuf[i * samplesPerPoint] // 0..255, 128 = silence
            chimeY = ((sample - 128) / 128) * amp
          }

          // Sum and clamp. Chimes punch through the bed waveform.
          let y = mid + bedY + chimeY
          if (y < mid - amp) y = mid - amp
          if (y > mid + amp) y = mid + amp

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
