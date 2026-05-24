defmodule Aural.Channel do
  @moduledoc """
  Single shared audio channel: one always-running synth + ffmpeg
  pipeline that broadcasts encoded MP3 bytes via PubSub. HTTP
  listeners subscribe and forward the bytes to their response —
  N listeners pay the cost of 1 encoder, all hear the same
  timeline, signals fire once and reach everyone at the same
  moment in the audio.

  Why MP3 instead of Opus: MP3 frames are self-contained, so a
  late-joining listener can start decoding from any frame
  boundary. Ogg/Opus requires headers + page-level sync that
  complicates fan-out.

  Future iteration: this is a singleton today, but the GenServer
  shape is ready to become a Registry-keyed multi-channel
  arrangement (e.g. one channel per workspace) when we want
  per-context signal routing.
  """

  use GenServer
  require Logger

  alias Aural.{ChimeAssets, Synth}

  defp pubsub, do: Aural.pubsub()

  # 100ms of audio per chunk; absolute-deadline scheduling.
  @chunk_samples 4_800
  @chunk_ms 100

  # Per-tick exponential-ease coefficient for the activity smoother.
  # `new = old + (target - old) * @activity_alpha` per chunk gives an
  # e-folding time of ~1/alpha chunks. At 0.10 that's ~1 second to
  # reach 63% of target, ~2.3s to reach 90% — slow enough to sound
  # like a fade, fast enough to feel responsive. Without this, every
  # set_activity call would snap bed gain at the next chunk boundary,
  # producing an audible step in the pad's amplitude.
  @activity_alpha 0.10

  # Number of chunks to crossfade between two tracks when pick_track
  # is called mid-playback. 30 chunks × 100 ms = 3 seconds — long
  # enough that the harmonic transition reads as deliberate, short
  # enough that the new track arrives before the listener loses
  # interest. Without this the old/new tracks would jump-cut at the
  # next chunk boundary, producing an audible click and a jarring
  # harmonic shift.
  @crossfade_chunks 30
  @topic "aural_channel:default"
  # Separate topic for chime alerts. These bypass the bed entirely —
  # subscribers (LiveViews) push the event to their client, which plays
  # a preloaded local audio element with near-zero latency. The 2-5s
  # streaming buffer on the MP3 bed makes mixing alerts into the bed
  # useless for actual signaling.
  @alert_topic "aural_alerts:default"
  # Peak amplitude of each rendered chunk, broadcast at chunk rate
  # (10/sec). Used by the client to draw the scope — Safari's
  # createMediaElementSource silently fails on chunked-streaming
  # audio, so we can't rely on the browser's WebAudio analyser for
  # the bed. Server-side peaks are cross-browser.
  @peak_topic "aural_channel:peaks"

  # --- Public API ---

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Subscribe the calling process to receive {:mp3, bytes} messages from the streaming bed."
  def subscribe, do: Phoenix.PubSub.subscribe(pubsub(), @topic)

  @doc "Unsubscribe from the streaming bed."
  def unsubscribe, do: Phoenix.PubSub.unsubscribe(pubsub(), @topic)

  @doc "Subscribe to chime alerts. Subscribers receive `{:alert, kind}` messages."
  def subscribe_alerts, do: Phoenix.PubSub.subscribe(pubsub(), @alert_topic)

  @doc "Unsubscribe from chime alerts."
  def unsubscribe_alerts, do: Phoenix.PubSub.unsubscribe(pubsub(), @alert_topic)

  @doc "Subscribe to peak-amplitude broadcasts. Subscribers receive `{:peak, float}` (0.0..1.0) at chunk rate."
  def subscribe_peaks, do: Phoenix.PubSub.subscribe(pubsub(), @peak_topic)

  @doc "Unsubscribe from peak broadcasts."
  def unsubscribe_peaks, do: Phoenix.PubSub.unsubscribe(pubsub(), @peak_topic)

  @doc """
  Fire a chime alert. `kind` is `"done" | "attention" | "alert"`.
  Broadcasts to every alert subscriber (every connected LiveView),
  which pushes a client event so the browser plays its preloaded
  local audio. ~WS RTT latency, not buffer-delayed.
  """
  def fire(kind), do: GenServer.cast(__MODULE__, {:fire, kind})

  @doc "Set the activity level (0.0..1.0) — boosts the bed's pad gain."
  def set_activity(level), do: GenServer.cast(__MODULE__, {:set_activity, level})

  @doc "Switch the bed track (atom)."
  def pick_track(track), do: GenServer.cast(__MODULE__, {:pick_track, track})

  @doc """
  Read a snapshot of the channel state for new HTTP subscribers and
  for the UI. Returns `{track, activity}` so subscribers can sync
  their initial UI.
  """
  def state, do: GenServer.call(__MODULE__, :state)

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    # Render chime WAVs to priv/static on boot if missing — they're
    # what the browser plays locally for instant alerts. Idempotent.
    ChimeAssets.ensure_rendered!()
    port = open_ffmpeg(Synth.sample_rate())
    start_ms = System.monotonic_time(:millisecond)
    send(self(), :tick)

    {:ok,
     %{
       port: port,
       track: :serene,
       # `prev_track` and `crossfade_remaining` drive the track
       # crossfade. When pick_track switches the bed, prev_track
       # holds the outgoing track for @crossfade_chunks ticks while
       # the new one fades in. nil = not currently crossfading.
       prev_track: nil,
       crossfade_remaining: 0,
       t: 0,
       chunk_n: 0,
       start_ms: start_ms,
       # `activity` is the currently-rendered value; `activity_target`
       # is the most-recent operator intent. Each tick eases the
       # current toward the target. Both start at 0.0.
       activity: 0.0,
       activity_target: 0.0
     }}
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, %{track: state.track, activity: state.activity_target}, state}
  end

  @impl true
  def handle_cast({:fire, kind}, state) when kind in ["done", "attention", "alert"] do
    Phoenix.PubSub.broadcast(pubsub(), @alert_topic, {:alert, kind})
    {:noreply, state}
  end

  def handle_cast({:fire, _}, state), do: {:noreply, state}

  def handle_cast({:set_activity, level}, state) when is_number(level) do
    # Sets the TARGET only — the per-tick easer in handle_info(:tick)
    # walks `state.activity` toward it. A direct write would step the
    # bed gain at the next chunk boundary; tweening keeps it musical.
    clamped = level |> max(0.0) |> min(1.0) |> :erlang.float()
    {:noreply, %{state | activity_target: clamped}}
  end

  def handle_cast({:set_activity, _}, state), do: {:noreply, state}

  def handle_cast({:pick_track, track}, state) when is_atom(track) do
    valid? = track in Synth.track_names()

    cond do
      not valid? ->
        {:noreply, state}

      # Already on this track and not mid-fade — nothing to do.
      track == state.track and state.prev_track == nil ->
        {:noreply, state}

      # Mid-crossfade and the operator picked the OLD track back —
      # swap directions in place. The elapsed fraction becomes the
      # remaining fraction for the reversed transition so we keep
      # the harmonic blend continuous instead of restarting from 0.
      track == state.prev_track ->
        elapsed = @crossfade_chunks - state.crossfade_remaining

        {:noreply,
         %{state | track: track, prev_track: state.track, crossfade_remaining: elapsed}}

      true ->
        # Standard case: start a crossfade from the current track
        # to the new one over @crossfade_chunks ticks.
        {:noreply,
         %{state | prev_track: state.track, track: track, crossfade_remaining: @crossfade_chunks}}
    end
  end

  def handle_cast({:pick_track, _}, state), do: {:noreply, state}

  @impl true
  def handle_info(:tick, state) do
    # Two-level smoothing: per-tick exponential ease toward the
    # target, plus per-sample linear ramp within the chunk (handled
    # in Synth.render_chunk). Per-tick alone leaves a tiny step at
    # chunk boundaries when the activity is changing fast; the
    # intra-chunk ramp erases that step entirely.
    activity_start = state.activity
    activity_end = activity_start + (state.activity_target - activity_start) * @activity_alpha

    sig = %{chimes: [], activity_start: activity_start, activity_end: activity_end}
    {pcm, state} = render_bed(state, sig)
    Port.command(state.port, pcm)

    # Broadcast a downsampled snapshot of the chunk: peak amplitude
    # (0.0..1.0, useful for level indicators) AND 16 real PCM samples
    # (-1.0..1.0) so the client can draw an actual waveform. Safari
    # can't analyse the streaming MP3 directly, so the server does the
    # downsampling and the browser just plots what arrives.
    Phoenix.PubSub.broadcast(
      pubsub(),
      @peak_topic,
      {:peak, %{p: peak_of(pcm), s: samples_of(pcm)}}
    )

    new_t = state.t + @chunk_samples
    new_n = state.chunk_n + 1
    # Persist the eased activity so the next chunk picks up from
    # where this one ended — no discontinuity sample-to-sample
    # across the boundary.
    state = %{state | activity: activity_end}

    # Absolute-deadline scheduling so producer never drifts relative
    # to wall clock — important because the encoded byte stream is
    # consumed by browsers expecting steady real-time delivery.
    next_deadline = state.start_ms + (new_n + 1) * @chunk_ms
    sleep_ms = max(0, next_deadline - System.monotonic_time(:millisecond))
    Process.send_after(self(), :tick, sleep_ms)

    {:noreply, %{state | t: new_t, chunk_n: new_n}}
  end

  # ffmpeg emits encoded MP3 bytes on its stdout via the port.
  def handle_info({port, {:data, mp3}}, %{port: port} = state) do
    Phoenix.PubSub.broadcast(pubsub(), @topic, {:mp3, mp3})
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[aural channel] ffmpeg exited with status #{status}, restarting")
    new_port = open_ffmpeg(Synth.sample_rate())
    {:noreply, %{state | port: new_port}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Render one chunk, applying a per-sample crossfade between
  # prev_track → track if a track switch is in flight. Returns the
  # rendered PCM and the (possibly updated) state — once the
  # crossfade counter reaches zero we drop prev_track so subsequent
  # ticks fall back to the single-track fast path.
  defp render_bed(%{prev_track: nil} = state, sig) do
    pcm = Synth.render_chunk(state.track, state.t, @chunk_samples, sig)
    {pcm, state}
  end

  defp render_bed(%{prev_track: prev, crossfade_remaining: remaining} = state, sig) do
    total = @crossfade_chunks
    elapsed = total - remaining
    alpha_start = elapsed / total
    alpha_end = (elapsed + 1) / total

    pcm =
      Synth.render_crossfade(
        prev,
        state.track,
        state.t,
        @chunk_samples,
        alpha_start,
        alpha_end,
        sig
      )

    new_remaining = remaining - 1

    state =
      if new_remaining <= 0 do
        %{state | prev_track: nil, crossfade_remaining: 0}
      else
        %{state | crossfade_remaining: new_remaining}
      end

    {pcm, state}
  end

  @impl true
  def terminate(_reason, %{port: port}) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    :ok
  end

  # --- Internals ---

  # Sampled peak amplitude — looks at ~32 evenly-spaced samples
  # across the chunk (instead of all 4800) so the per-tick cost
  # stays under a millisecond. The scope only needs amplitude
  # envelope, not sample-accurate waveform.
  defp peak_of(<<>>), do: 0.0

  defp peak_of(pcm) do
    n_samples = div(byte_size(pcm), 2)
    step = max(1, div(n_samples, 32))

    max_abs =
      Enum.reduce(0..(n_samples - 1)//step, 0, fn i, acc ->
        offset = i * 2
        <<_::binary-size(offset), s::16-little-signed, _::binary>> = pcm
        max(acc, abs(s))
      end)

    max_abs / 32_768.0
  end

  # 16 evenly-spaced samples across the chunk, as signed floats in
  # [-1, 1]. Effective rate: ~160 Hz (16 samples × 10 chunks/sec).
  # Enough to render sub-bass content; higher frequencies alias but
  # that's fine for visualization.
  @samples_per_chunk 16

  defp samples_of(<<>>), do: List.duplicate(0.0, @samples_per_chunk)

  defp samples_of(pcm) do
    n_total = div(byte_size(pcm), 2)
    step = max(1, div(n_total, @samples_per_chunk))

    for i <- 0..(@samples_per_chunk - 1) do
      offset = min(i * step, n_total - 1) * 2
      <<_::binary-size(offset), s::16-little-signed, _::binary>> = pcm
      Float.round(s / 32_768.0, 3)
    end
  end

  defp open_ffmpeg(sample_rate) do
    ffmpeg = System.find_executable("ffmpeg") || raise "ffmpeg not on PATH"

    Port.open(
      {:spawn_executable, ffmpeg},
      [
        :binary,
        :exit_status,
        :use_stdio,
        args: [
          "-hide_banner",
          "-loglevel",
          "error",
          # Input: raw signed 16-bit little-endian mono PCM from stdin
          "-f",
          "s16le",
          "-ar",
          to_string(sample_rate),
          "-ac",
          "1",
          "-i",
          "pipe:0",
          # Output: MP3, 128kbps. Frame-independent format → late
          # joiners can start decoding mid-stream from any frame.
          "-c:a",
          "libmp3lame",
          "-b:a",
          "128k",
          "-f",
          "mp3",
          "-flush_packets",
          "1",
          "pipe:1"
        ]
      ]
    )
  end
end
