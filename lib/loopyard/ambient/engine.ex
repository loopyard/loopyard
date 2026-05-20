defmodule Loopyard.Ambient.Engine do
  @moduledoc """
  Generative ambient audio engine. Singleton GenServer that ticks at
  ~46ms intervals, renders a chunk of 16-bit PCM samples, and
  broadcasts them via `Loopyard.Events.Ambient`.

  Browsers subscribe via `LoopyardWeb.AmbientChannel` and play the
  chunks through WebAudio.

  ## Why this exists in pure Elixir

  Keeps the server-side surface minimal — generate raw PCM, broadcast
  binary, done. No codec, no transcoder, no HTTP audio streaming.
  Browsers do the playback scheduling. See
  `plans/ambient-soundtrack.md` for the full design.

  ## Music

  v1 ships a single track ("serene"): a 4-chord progression
  (Cmaj7 → Am7 → Fmaj9 → G6) with smooth crossfades between chords
  and a slow gain LFO. The math is intentionally simple — additive
  synthesis of a few sines with envelopes.
  """

  use GenServer
  require Logger

  alias Loopyard.Events.Ambient, as: Events

  @sample_rate 44_100
  # ~46ms of audio per tick
  @chunk_size 2048
  @tick_ms 46

  # 12 seconds per chord, 4 chords, 48-second cycle
  @chord_samples 12 * @sample_rate
  @cycle_samples 4 * @chord_samples

  # Each chord: {note frequencies, bass frequency}.
  @chords [
    {[261.63, 329.63, 392.00, 493.88], 65.41},
    {[220.00, 261.63, 329.63, 392.00], 55.00},
    {[174.61, 220.00, 261.63, 329.63], 87.31},
    {[196.00, 246.94, 293.66, 369.99], 49.00}
  ]

  # --- Public API ---

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Start ticking + broadcasting. Idempotent."
  def play, do: GenServer.cast(__MODULE__, :play)

  @doc "Stop ticking. Engine retains its sample counter so resuming continues from the same point."
  def stop, do: GenServer.cast(__MODULE__, :stop)

  @doc "Is the engine currently broadcasting?"
  def playing?, do: GenServer.call(__MODULE__, :playing?)

  # --- GenServer callbacks ---

  @impl true
  def init(_opts), do: {:ok, %{t: 0, playing?: false}}

  @impl true
  def handle_cast(:play, %{playing?: true} = state), do: {:noreply, state}

  def handle_cast(:play, %{playing?: false} = state) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, %{state | playing?: true}}
  end

  def handle_cast(:stop, state), do: {:noreply, %{state | playing?: false}}

  @impl true
  def handle_call(:playing?, _from, state), do: {:reply, state.playing?, state}

  @impl true
  def handle_info(:tick, %{playing?: false} = state), do: {:noreply, state}

  def handle_info(:tick, %{playing?: true, t: t} = state) do
    chunk = render_chunk(t)
    Events.publish_chunk(chunk)
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, %{state | t: t + @chunk_size}}
  end

  # --- Rendering ---

  defp render_chunk(start_t) do
    for i <- 0..(@chunk_size - 1), into: <<>> do
      sample = sample_at(start_t + i) |> clamp()
      <<round(sample * 32_767)::little-signed-16>>
    end
  end

  # Sample value at integer sample index `n`. Wraps the cycle so it loops forever.
  defp sample_at(n) do
    n_mod = rem(n, @cycle_samples)
    t = n_mod / @sample_rate

    # Which chord we're on (0-3) and how far through it (0-1).
    chord_index = div(n_mod, @chord_samples)
    chord_progress = rem(n_mod, @chord_samples) / @chord_samples

    {notes_a, bass_a} = Enum.at(@chords, chord_index)
    {notes_b, bass_b} = Enum.at(@chords, rem(chord_index + 1, length(@chords)))

    # Smooth crossfade between current and next chord using the second
    # half of the chord's duration. Stay on current chord for first half,
    # transition over the second half.
    alpha = smoothstep(max(0.0, (chord_progress - 0.5) * 2.0))

    pad = (1.0 - alpha) * chord_sum(notes_a, t) + alpha * chord_sum(notes_b, t)
    bass = (1.0 - alpha) * sine(bass_a, t) + alpha * sine(bass_b, t)

    pad_gain = 0.30 * lfo(t, 0.07, 0.85, 1.0)
    bass_gain = 0.18

    pad_gain * pad + bass_gain * bass
  end

  defp chord_sum(notes, t) do
    Enum.reduce(notes, 0.0, fn f, acc -> acc + sine(f, t) end) / length(notes)
  end

  defp sine(freq, t), do: :math.sin(2 * :math.pi * freq * t)

  # Slow LFO returning a value in [low, high] sinusoidally.
  defp lfo(t, freq_hz, low, high) do
    mid = (low + high) / 2
    amp = (high - low) / 2
    mid + amp * :math.sin(2 * :math.pi * freq_hz * t)
  end

  # Smoothstep: 3x² - 2x³. Gentler than linear for crossfading.
  defp smoothstep(x) when x <= 0.0, do: 0.0
  defp smoothstep(x) when x >= 1.0, do: 1.0
  defp smoothstep(x), do: x * x * (3.0 - 2.0 * x)

  defp clamp(v) when v > 1.0, do: 1.0
  defp clamp(v) when v < -1.0, do: -1.0
  defp clamp(v), do: v
end
