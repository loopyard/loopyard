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

// Convert an array of [x, y] points into an SVG `path` `d` string
// using Catmull-Rom interpolation — each segment between p[i] and
// p[i+1] becomes a cubic Bezier whose control points are tangent
// to the neighboring points. Yields a smooth flowing curve instead
// of the polyline's straight-line zigzag. End points use their own
// position as the missing neighbor (clamps the spline so it doesn't
// fly off at the boundaries).
function catmullRomPath(points) {
  const n = points.length
  if (n === 0) return ""
  if (n === 1) {
    return `M ${points[0][0].toFixed(1)},${points[0][1].toFixed(1)}`
  }

  let d = `M ${points[0][0].toFixed(1)},${points[0][1].toFixed(1)}`
  for (let i = 0; i < n - 1; i++) {
    const p0 = points[Math.max(0, i - 1)]
    const p1 = points[i]
    const p2 = points[i + 1]
    const p3 = points[Math.min(n - 1, i + 2)]

    // Catmull-Rom (tension = 0.5) → cubic Bezier control points.
    const c1x = p1[0] + (p2[0] - p0[0]) / 6
    const c1y = p1[1] + (p2[1] - p0[1]) / 6
    const c2x = p2[0] - (p3[0] - p1[0]) / 6
    const c2y = p2[1] - (p3[1] - p1[1]) / 6

    d +=
      ` C ${c1x.toFixed(1)},${c1y.toFixed(1)} ` +
      `${c2x.toFixed(1)},${c2y.toFixed(1)} ` +
      `${p2[0].toFixed(1)},${p2[1].toFixed(1)}`
  }
  return d
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

      this._rafId = null
      this._currentSrc = this._audio.src

      this._toggle.addEventListener("click", () => this._handleToggle())

      // Track rows: when clicked, kick off audio playback in the
      // SAME tick — Safari rejects audio.play() if a server
      // round-trip happens between the click and the .play() call
      // (user-gesture token expires). The phx-click also fires
      // server-side to pick the track.
      this.el.addEventListener("click", (e) => {
        const trackBtn = e.target.closest('button[phx-click="pick_track"]')
        if (trackBtn) this._startPlayback()
      })

      // Kept as a fallback for any future server-initiated play
      // request (e.g. "tune everyone in now").
      this.handleEvent("play", () => this._startPlayback())

      // The server fires a `"fire"` event whenever Aural.Channel.fire/2
      // runs (either from a button click on this page or a system
      // event elsewhere). The chime is being mixed into the bed
      // stream on the server, so it'll arrive in the audio buffer
      // 2-5s later — flash the matching button immediately so the
      // operator gets click feedback without waiting for the audio.
      this.handleEvent("fire", ({ kind }) => this._flashFire(kind))

      // Server pushes the peak amplitude (0..1) of every 100ms chunk.
      // 80-slot ring = 8 seconds of channel history. _peakDisplay is
      // the smoothly-tweened version the rAF tick reads, so the line
      // glides at 60 fps between the 10 Hz updates. _lastPeakAt is
      // the timestamp of the most recent arrival; the render uses it
      // to slide the wave LEFT continuously between peak arrivals
      // (sub-frame scroll), so new data doesn't pop in at x=width.
      this._peakBuf = new Float32Array(80)
      this._peakDisplay = new Float32Array(80)
      this._peakIdx = 0
      this._playScale = 0
      this._lastPeakAt = 0
      this.handleEvent("peak", ({ p }) => {
        this._peakBuf[this._peakIdx] = p || 0
        this._peakIdx = (this._peakIdx + 1) % this._peakBuf.length
        this._lastPeakAt = performance.now()
      })

      // _audioPlaying tracks whether audio is ACTUALLY emitting, not
      // just whether .play() has been called. The browser fires
      // `playing` when the buffer is full enough to start decoding
      // (i.e. when sound actually reaches the speakers), and
      // `pause`/`waiting`/`stalled` when it stops. The scope keys
      // its amplitude scale off this rather than `!audio.paused`,
      // which flips the moment `.play()` is called — well before
      // any audio is audible. Without this distinction the
      // visualizer leads the audio by 2-5 seconds while the stream
      // buffer fills.
      this._audioPlaying = false
      this._startAnimation()
      this._audio.addEventListener("playing", () => {
        this._audioPlaying = true
        this._setUI("playing", "Streaming")
        logToServer("audio:playing", { src: this._audio.src })
      })
      this._audio.addEventListener("pause", () => {
        this._audioPlaying = false
        this._setUI("paused", "Paused")
        logToServer("audio:pause", {})
      })
      // `waiting` fires when the player wants to play but has
      // outrun its buffer — that's the "loading" state the user
      // notices. `stalled` is similar (network slowed). Both
      // surface as "Loading" so the toggle label tells the truth
      // about why nothing's coming out of the speakers yet.
      this._audio.addEventListener("waiting", () => {
        this._audioPlaying = false
        this._setUI("loading", "Loading")
        logToServer("audio:waiting", {
          networkState: this._audio.networkState,
          readyState: this._audio.readyState
        })
      })
      this._audio.addEventListener("stalled", () => {
        this._audioPlaying = false
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

    // Flash the matching chime button: instant outward glow on
    // press, slowly fading back over ~1.2s. The actual chime
    // arrives in the audio bed a few seconds later (it's being
    // mixed into the stream server-side), so this visual is what
    // confirms the click registered. Uses currentColor so it
    // tracks the button's own text color in any host theme.
    _flashFire(kind) {
      const btn = this.el.querySelector(
        `button[phx-click="aural:fire"][phx-value-kind="${kind}"]`
      )
      if (!btn) return

      // Apply the press state synchronously, then on the next
      // animation frame switch on a transition and let it fade.
      btn.style.transition = "none"
      btn.style.boxShadow = "0 0 24px 4px currentColor"
      btn.style.filter = "brightness(1.35)"

      requestAnimationFrame(() => {
        btn.style.transition =
          "box-shadow 1200ms ease-out, filter 1200ms ease-out"
        btn.style.boxShadow = "0 0 0 0 transparent"
        btn.style.filter = "brightness(1)"
      })

      // Clear the inline styles after the transition finishes so
      // they don't pin permanently (and so subsequent flashes start
      // from a clean baseline).
      clearTimeout(this._fireTimers?.[kind])
      this._fireTimers = this._fireTimers || {}
      this._fireTimers[kind] = setTimeout(() => {
        btn.style.transition = ""
        btn.style.boxShadow = ""
        btn.style.filter = ""
      }, 1400)
    },

    _handleToggle() {
      if (this._audio.paused) {
        this._startPlayback()
      } else {
        this._audio.pause()
        // Don't stop the rAF loop — _playScale tweens back to its
        // "paused" target on the next ticks so the scope settles
        // into the channel-alive indicator instead of jumping flat.
      }
    },

    // Start (or restart) playback of the current <audio> source.
    // Called from the dedicated toggle and from track-row clicks.
    // Immediately flips the UI to "Loading" — the browser doesn't
    // emit `waiting` until it actively underflows, which means the
    // user sees no feedback during the initial buffer fill.
    _startPlayback() {
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

    // The scope renders an amplitude envelope of server-pushed peak
    // values — one peak per 100ms chunk, 80 historical slots = 8s
    // of channel history. Three things make it look continuous:
    //
    //   1. _audioPlaying drives _playScale (full vs subtle) based
    //      on the `playing` event so the envelope's height tracks
    //      what's actually audible, not "we called .play()".
    //   2. Sub-frame interpolation between 10 Hz peak arrivals: the
    //      whole wave slides LEFT by (elapsed_ms / 100) columns
    //      each frame, so the line glides at 60 fps instead of
    //      stepping at peak boundaries.
    //   3. Catmull-Rom smoothing converts the 80 vertices into a
    //      cubic Bezier path so adjacent peaks blend instead of
    //      cornering. Combined with the SVG edge-fade mask, new
    //      peaks emerge out of fade-in on the right rather than
    //      popping in at x=width.
    _startAnimation() {
      if (this._rafId) return
      const width = 800
      const mid = 60
      const maxAmp = mid - 5
      const peakIntervalMs = 100

      const tick = () => {
        const target = this._audioPlaying ? 1.0 : 0.15
        this._playScale += (target - this._playScale) * 0.06

        const N = 80
        const peakHead = this._peakIdx
        for (let i = 0; i < N; i++) {
          this._peakDisplay[i] += (this._peakBuf[i] - this._peakDisplay[i]) * 0.30
        }

        const bedAmp = maxAmp * this._playScale
        // Visual gain — ambient pads peak around 0.3–0.4, so a 2.5×
        // boost fills the available vertical without ever clipping.
        const gain = 2.5

        // Sub-frame scroll: how far into the current 100ms peak
        // interval are we? 0 right after a peak, 1 right before the
        // next one. We shift the rendered x positions LEFT by this
        // fraction of a column, so the wave moves continuously at
        // ~1 column per 100ms instead of jumping every chunk.
        const now = performance.now()
        const progress = this._lastPeakAt
          ? Math.min(1, (now - this._lastPeakAt) / peakIntervalMs)
          : 0

        const points = []
        for (let i = 0; i < N; i++) {
          // Without the shift, i=0 sits at x=0 and i=N-1 at x=width.
          // Subtracting progress slides everything left. The SVG
          // mask fades the leftmost/rightmost columns so points
          // entering or exiting the viewport do so smoothly.
          const x = ((i - progress) / (N - 1)) * width
          const slot = (peakHead + i) % N
          let dy = this._peakDisplay[slot] * bedAmp * gain
          if (dy > maxAmp) dy = maxAmp
          // Single-sided envelope above mid: higher peak = line
          // further from baseline. Reads as "loudness over time".
          const y = mid - dy
          points.push([x, y])
        }

        if (this._scopeLine) {
          this._scopeLine.setAttribute("d", catmullRomPath(points))
        }
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
        this._scopeLine?.setAttribute("d", "M 0,60 L 800,60")
      }, 400)
    }
  }
}
