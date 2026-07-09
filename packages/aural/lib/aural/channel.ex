defmodule Aural.Channel do
  @moduledoc """
  An audio channel — one synth + ffmpeg pipeline that broadcasts
  encoded MP3 bytes via `Phoenix.PubSub` to every HTTP listener
  subscribed to its topic. N listeners pay the cost of 1 encoder
  and all hear the same byte at the same moment.

  Channels are keyed by an opaque `channel_id` string and live under
  `Aural.Channel.Supervisor` (a `DynamicSupervisor`); look-up goes
  through `Aural.Channel.Registry`. Hosts never spawn channels by
  hand — every public function below auto-starts the channel on
  first call.

      iex> id = Aural.Channel.new_id()
      "k3J9_aB2xY8"
      iex> Aural.Channel.subscribe(id)
      :ok
      iex> Aural.Channel.pick_track(id, :nocturne)
      :ok

  Channels self-terminate after `:idle_timeout_seconds` (default 300)
  with zero subscribers across all three topics. The URL stays
  shareable: a request to a stale ID just respawns a fresh channel
  under the same name.

  Why MP3 instead of Opus: MP3 frames are self-contained, so a
  late-joining listener can start decoding from any frame boundary.
  Ogg/Opus requires headers + page-level sync that complicates
  fan-out.
  """

  use GenServer, restart: :transient
  require Logger

  alias Aural.{Signals, Synth}

  # 100ms of audio per chunk; absolute-deadline scheduling.
  @chunk_samples 4_800
  @chunk_ms 100

  # Per-tick exponential-ease coefficient for the activity smoother.
  # See moduledoc in v0.1; ~1s to 63%, ~2.3s to 90%.
  @activity_alpha 0.10

  # 30 chunks × 100 ms = 3 second crossfade between tracks.
  @crossfade_chunks 30

  # Subscriber-count poll cadence for the idle reaper.
  @idle_check_ms 30_000

  # Max concurrent chimes per channel. Each active chime contributes
  # a per-sample cost to the bed render; 16 is well under 1ms/tick
  # total even on a small Fly machine. Newest-wins: when at cap, the
  # oldest queued chime gets clipped so the latest UI click is the
  # one the listener hears.
  @max_concurrent_chimes 16

  # channel_id format: 1-64 url-safe chars. Bare minimum sanity check
  # to keep an attacker from spawning a channel keyed by a multi-MB
  # path-traversal string. Anything that doesn't pass returns
  # {:error, :invalid_channel_id} instead of starting a channel.
  @channel_id_regex ~r/^[A-Za-z0-9_-]{1,64}$/

  # --- Public API ---

  @typedoc "Opaque channel identifier — anything URL-safe."
  @type channel_id :: String.t()

  @doc """
  Generate a URL-safe channel ID. 11 characters, ~64 bits of entropy.
  Hosts can also pass any string they like (e.g. a workspace ID) —
  the engine treats `channel_id` as opaque.
  """
  @spec new_id() :: channel_id
  def new_id, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

  @doc """
  Ensure a channel is running. Idempotent — if a channel with this
  ID already exists, returns its pid; otherwise spawns one under
  `Aural.Channel.Supervisor`. Every other public function calls this
  first, so hosts rarely need to call it directly.

  Rejects malformed IDs with `{:error, :invalid_channel_id}`. IDs
  must match `[A-Za-z0-9_-]{1,64}` — same alphabet
  `Aural.Channel.new_id/0` produces.
  """
  @spec ensure_started(channel_id) :: {:ok, pid()} | {:error, term()}
  def ensure_started(channel_id) when is_binary(channel_id) do
    if valid_channel_id?(channel_id) do
      case DynamicSupervisor.start_child(
             Aural.Channel.Supervisor,
             {__MODULE__, channel_id: channel_id}
           ) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        other -> other
      end
    else
      {:error, :invalid_channel_id}
    end
  end

  @doc """
  Whether `id` is a syntactically valid channel ID. Exposed so
  hosts can fail fast before calling `ensure_started/1` (e.g.
  return a 404 instead of waking the supervisor for garbage input).
  """
  @spec valid_channel_id?(term()) :: boolean()
  def valid_channel_id?(id) when is_binary(id), do: Regex.match?(@channel_id_regex, id)
  def valid_channel_id?(_), do: false

  @doc """
  List every channel currently running under
  `Aural.Channel.Supervisor`. Returns `[{channel_id, pid}, ...]`.
  Used for `/system/aural`-style observability and tests; not on
  any hot path.
  """
  @spec list() :: [{channel_id, pid()}]
  def list do
    Registry.select(Aural.Channel.Registry, [
      {{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
  end

  @doc "Subscribe the calling process to MP3 bytes for `channel_id`."
  @spec subscribe(channel_id) :: :ok | {:error, term()}
  def subscribe(channel_id) do
    ensure_started(channel_id)
    Phoenix.PubSub.subscribe(pubsub(), stream_topic(channel_id))
  end

  @doc "Unsubscribe from MP3 bytes."
  @spec unsubscribe(channel_id) :: :ok
  def unsubscribe(channel_id),
    do: Phoenix.PubSub.unsubscribe(pubsub(), stream_topic(channel_id))

  @doc """
  Subscribe to peak-amplitude broadcasts. Receives
  `{:peak, %{p: float}}` at chunk rate (10 Hz).
  """
  @spec subscribe_peaks(channel_id) :: :ok | {:error, term()}
  def subscribe_peaks(channel_id) do
    ensure_started(channel_id)
    Phoenix.PubSub.subscribe(pubsub(), peak_topic(channel_id))
  end

  @doc "Unsubscribe from peak broadcasts."
  @spec unsubscribe_peaks(channel_id) :: :ok
  def unsubscribe_peaks(channel_id),
    do: Phoenix.PubSub.unsubscribe(pubsub(), peak_topic(channel_id))

  @doc """
  Fire a chime alert on `channel_id`. `kind` is `"done"`,
  `"attention"`, or `"alert"`. Broadcasts to every alert subscriber
  on this channel.
  """
  @spec fire(channel_id, String.t()) :: :ok
  def fire(channel_id, kind) do
    ensure_started(channel_id)
    GenServer.cast(via(channel_id), {:fire, kind})
  end

  @doc "Set the activity level (0.0..1.0) for `channel_id`."
  @spec set_activity(channel_id, number()) :: :ok
  def set_activity(channel_id, level) do
    ensure_started(channel_id)
    GenServer.cast(via(channel_id), {:set_activity, level})
  end

  @doc "Switch the bed track for `channel_id`. Crossfades over ~3s."
  @spec pick_track(channel_id, atom()) :: :ok
  def pick_track(channel_id, track) do
    ensure_started(channel_id)
    GenServer.cast(via(channel_id), {:pick_track, track})
  end

  @doc """
  Snapshot of channel state: `%{track: atom, activity: float}`.
  Used by LVs for initial UI sync.
  """
  @spec state(channel_id) :: %{track: atom(), activity: float()}
  def state(channel_id) do
    ensure_started(channel_id)
    GenServer.call(via(channel_id), :state)
  end

  # --- Plumbing exposed for the Supervisor / Registry ---

  @doc false
  def child_spec(opts) do
    channel_id = Keyword.fetch!(opts, :channel_id)

    %{
      id: {__MODULE__, channel_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @doc false
  def start_link(opts) do
    channel_id = Keyword.fetch!(opts, :channel_id)
    GenServer.start_link(__MODULE__, opts, name: via(channel_id))
  end

  defp via(channel_id), do: {:via, Registry, {Aural.Channel.Registry, channel_id}}

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    channel_id = Keyword.fetch!(opts, :channel_id)
    Process.flag(:trap_exit, true)
    port = open_ffmpeg(Synth.sample_rate())
    start_ms = System.monotonic_time(:millisecond)
    send(self(), :tick)
    Process.send_after(self(), :idle_check, @idle_check_ms)

    :telemetry.execute(
      [:aural, :channel, :start],
      %{system_time: System.system_time()},
      %{channel_id: channel_id}
    )

    {:ok,
     %{
       channel_id: channel_id,
       port: port,
       track: :serene,
       prev_track: nil,
       crossfade_remaining: 0,
       t: 0,
       chunk_n: 0,
       start_ms: start_ms,
       activity: 0.0,
       activity_target: 0.0,
       # Active chimes: list of %{kind, start_n}. fire/2 prepends a
       # fresh chime; each tick prunes any whose age has passed
       # Signals.chime_lifetime_samples/1 and passes the rest to the
       # synth, which mixes them into the bed per-sample.
       chimes: [],
       idle_check_count: 0
     }}
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, %{track: state.track, activity: state.activity_target}, state}
  end

  @impl true
  def handle_cast({:fire, kind}, state) when kind in ["done", "attention", "alert"] do
    # Schedule the chime at the current sample boundary. Synth picks
    # it up on the next tick, mixes it into the bed PCM per-sample
    # until its envelope expires, then the prune step in :tick
    # drops it.
    #
    # Cap at @max_concurrent_chimes: drop the OLDEST if we'd exceed.
    # Newest-wins means a rapid UI mash still plays the most recent
    # click; the alternative (drop newest) would silently swallow
    # user input.
    chime = %{kind: kind, start_n: state.t}

    new_chimes =
      [chime | state.chimes]
      |> Enum.take(@max_concurrent_chimes)

    :telemetry.execute(
      [:aural, :channel, :fire],
      %{active_chimes: length(new_chimes)},
      %{channel_id: state.channel_id, kind: kind}
    )

    {:noreply, %{state | chimes: new_chimes}}
  end

  def handle_cast({:fire, _}, state), do: {:noreply, state}

  def handle_cast({:set_activity, level}, state) when is_number(level) do
    clamped = level |> max(0.0) |> min(1.0) |> :erlang.float()

    :telemetry.execute(
      [:aural, :channel, :set_activity],
      %{level: clamped},
      %{channel_id: state.channel_id}
    )

    {:noreply, %{state | activity_target: clamped}}
  end

  def handle_cast({:set_activity, _}, state), do: {:noreply, state}

  def handle_cast({:pick_track, track}, state) when is_atom(track) do
    valid? = track in Synth.track_names()

    cond do
      not valid? ->
        {:noreply, state}

      track == state.track and state.prev_track == nil ->
        {:noreply, state}

      track == state.prev_track ->
        elapsed = @crossfade_chunks - state.crossfade_remaining

        :telemetry.execute(
          [:aural, :channel, :pick_track],
          %{elapsed_chunks: elapsed},
          %{channel_id: state.channel_id, from: state.track, to: track, reversed: true}
        )

        {:noreply,
         %{state | track: track, prev_track: state.track, crossfade_remaining: elapsed}}

      true ->
        :telemetry.execute(
          [:aural, :channel, :pick_track],
          %{elapsed_chunks: 0},
          %{channel_id: state.channel_id, from: state.track, to: track, reversed: false}
        )

        {:noreply,
         %{state | prev_track: state.track, track: track, crossfade_remaining: @crossfade_chunks}}
    end
  end

  def handle_cast({:pick_track, _}, state), do: {:noreply, state}

  @impl true
  def handle_info(:tick, state) do
    activity_start = state.activity
    activity_end = activity_start + (state.activity_target - activity_start) * @activity_alpha

    sig = %{
      chimes: state.chimes,
      activity_start: activity_start,
      activity_end: activity_end
    }

    {pcm, state} = render_bed(state, sig)
    Port.command(state.port, pcm)

    Phoenix.PubSub.broadcast(
      pubsub(),
      peak_topic(state.channel_id),
      {:peak, %{p: peak_of(pcm)}}
    )

    new_t = state.t + @chunk_samples
    new_n = state.chunk_n + 1

    alive_chimes =
      Enum.filter(state.chimes, fn %{kind: kind, start_n: start_n} ->
        new_t - start_n < Signals.chime_lifetime_samples(kind)
      end)

    state = %{state | activity: activity_end, chimes: alive_chimes}

    next_deadline = state.start_ms + (new_n + 1) * @chunk_ms
    sleep_ms = max(0, next_deadline - System.monotonic_time(:millisecond))
    Process.send_after(self(), :tick, sleep_ms)

    {:noreply, %{state | t: new_t, chunk_n: new_n}}
  end

  # Idle reaper: every @idle_check_ms, poll subscriber counts across
  # all three topics. After two consecutive empty checks (≥1 full
  # idle_timeout window), shut down. Two checks instead of one
  # absorbs the gap between an HTTP listener disconnecting and a
  # new one connecting on the same URL.
  def handle_info(:idle_check, state) do
    n = subscriber_count(state.channel_id)
    timeout_chunks = max(1, div(idle_timeout_ms(), @idle_check_ms))

    new_count = if n == 0, do: state.idle_check_count + 1, else: 0

    if new_count >= timeout_chunks do
      Logger.info(
        "[aural channel #{state.channel_id}] idle for #{div(idle_timeout_ms(), 1000)}s, shutting down"
      )

      :telemetry.execute(
        [:aural, :channel, :stop],
        %{idle_ms: idle_timeout_ms()},
        %{channel_id: state.channel_id, reason: :idle}
      )

      {:stop, :normal, state}
    else
      Process.send_after(self(), :idle_check, @idle_check_ms)
      {:noreply, %{state | idle_check_count: new_count}}
    end
  end

  def handle_info({port, {:data, mp3}}, %{port: port} = state) do
    Phoenix.PubSub.broadcast(pubsub(), stream_topic(state.channel_id), {:mp3, mp3})
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning(
      "[aural channel #{state.channel_id}] ffmpeg exited with status #{status}, restarting"
    )

    new_port = open_ffmpeg(Synth.sample_rate())
    {:noreply, %{state | port: new_port}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

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

  # --- Topic + config helpers ---

  defp pubsub, do: Aural.pubsub()

  defp stream_topic(channel_id), do: "aural:stream:" <> channel_id
  defp peak_topic(channel_id), do: "aural:peak:" <> channel_id

  defp idle_timeout_ms do
    seconds = Application.get_env(:aural, :idle_timeout_seconds, 300)
    seconds * 1_000
  end

  # Phoenix.PubSub doesn't expose subscriber counts directly. Its
  # PG2 adapter (the default) keeps a process group per topic, and
  # `:pg.get_members/2` reads it cheaply. The fallback for any other
  # adapter is 0, which keeps the channel alive forever — safer
  # than reaping prematurely if we can't measure.
  defp subscriber_count(channel_id) do
    [stream_topic(channel_id), peak_topic(channel_id)]
    |> Enum.map(&topic_subscriber_count(pubsub(), &1))
    |> Enum.sum()
  end

  defp topic_subscriber_count(pubsub, topic) do
    :pg.get_members(pubsub, topic) |> length()
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end

  # --- PCM helpers ---

  defp peak_of(<<>>), do: 0.0

  defp peak_of(pcm) do
    n_samples = div(byte_size(pcm), 2)
    step = max(1, div(n_samples, 32))

    max_abs =
      Enum.reduce(0..(n_samples - 1)//step, 0, fn i, acc ->
        offset = i * 2
        <<_::binary-size(^offset), s::16-little-signed, _::binary>> = pcm
        max(acc, abs(s))
      end)

    max_abs / 32_768.0
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
          # Input: raw 16-bit little-endian mono PCM from stdin.
          "-f",
          "s16le",
          "-ar",
          to_string(sample_rate),
          "-ac",
          "1",
          "-i",
          "pipe:0",
          # Output: MP3, 128 kbps CBR. Frame-independent so a late-
          # joining HTTP listener can start decoding from any byte.
          "-c:a",
          "libmp3lame",
          "-b:a",
          "128k",
          # Low-latency tuning: disable LAME's bit reservoir (look-
          # ahead window). The reservoir lets the encoder borrow
          # bits between frames for better quality on transients,
          # but it also delays the first usable MP3 frame by ~6
          # frames (~150 ms). For a streaming ambient bed there are
          # no transients to spend extra bits on — drop the
          # reservoir, ship frames sooner.
          "-reservoir",
          "0",
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
