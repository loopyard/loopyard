defmodule BoomLooper.Events.Tap do
  @moduledoc """
  Ring-buffered record of every PubSub broadcast on the BoomLooper
  topics we care about, with timestamps and payload summaries. Drives
  `/system/events` — the "what fired when" timeline that turns
  ghost-in-the-machine bug reports into readable tape.

  Move #7 of plans/coordination-hardening.md.

  ## Scope

  Subscribes to the BoomLooper-global topics at init:

    * `"chat_agents"`
    * `"docker_observer"`
    * `"workspace_services"`

  Per-agent (`chat_agent:{id}`) and per-workspace (`source_sync:{id}`)
  topics are NOT captured here — they multiply with workload and are
  better consumed via each agent/workspace page directly. If you need
  to see per-agent broadcasts in the tap, the clean path is Move #2
  (publisher wrappers with telemetry) which lets the tap attach to
  `[:boom_looper, :events, :publish]` instead of subscribing to every
  topic by name.

  ## Storage

  Single `:events_tap` ETS table (ordered_set) keyed by a monotonic
  integer. Reading the newest N events is a single
  `:ets.select_reverse/3`. When the table exceeds `@max_records` we
  trim the oldest in a single batch — cheaper than per-insert trim.

  Payload size is capped (`@max_payload_bytes`) so large messages
  don't bloat the table. We store a truncated `inspect/2` of the
  payload, not the payload itself — the tap is for humans, not for
  dispatch.

  ## Not in prod?

  Shipping in all envs (dev, test, prod). Buffer size stays small so
  memory overhead is negligible. Per the design decision, full
  payloads in the buffer are acceptable for a single-user / trusted-
  team deployment; when multi-tenant lands, this module's
  `format_payload/1` is where we'd add redaction.
  """

  use GenServer

  @table :events_tap
  @topics ["chat_agents", "docker_observer", "workspace_services"]
  @max_records 500
  # 2KB truncation matches the system-prompt cap; keeps per-event
  # storage bounded without being so small that payloads become
  # meaningless.
  @max_payload_bytes 2_048

  # ── Public API (direct ETS reads) ──

  @doc """
  Return the most recent events across all tracked topics.

  Options:

    * `:topic` — filter to a single topic
    * `:since_ms` — only return events newer than the given
      monotonic millisecond timestamp (use `System.monotonic_time(:millisecond)`)
    * `:limit` — max number of events to return (default: all)

  Returns list of maps `%{seq, topic, tag, payload, inserted_at_ms,
  inserted_at_utc}` newest-first.
  """
  def recent(opts \\ []) do
    topic = Keyword.get(opts, :topic)
    since_ms = Keyword.get(opts, :since_ms)
    limit = Keyword.get(opts, :limit)

    all =
      :ets.tab2list(@table)
      # Newest first (ordered_set sorts ascending by key; key is a
      # monotonic seq, so reverse gives us newest).
      |> Enum.sort_by(fn {seq, _} -> seq end, :desc)
      |> Enum.map(fn {_seq, record} -> record end)

    filtered =
      all
      |> maybe_filter_topic(topic)
      |> maybe_filter_since(since_ms)

    case limit do
      nil -> filtered
      n when is_integer(n) -> Enum.take(filtered, n)
    end
  end

  @doc "Per-topic count of recent events. Cheap; iterates the table once."
  def topic_counts do
    :ets.tab2list(@table)
    |> Enum.reduce(%{}, fn {_seq, %{topic: t}}, acc -> Map.update(acc, t, 1, &(&1 + 1)) end)
  end

  @doc "Every topic we're subscribed to."
  def topics, do: @topics

  # ── GenServer ──

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    # Monotonic counter for insertion order. Monotonic time is the
    # right default here because we want insertion order preserved
    # across clock adjustments and NTP skew.
    for topic <- @topics do
      Phoenix.PubSub.subscribe(BoomLooper.PubSub, topic)
    end

    {:ok, %{seq: 0}}
  end

  # Every broadcast on a subscribed topic lands here. We don't know
  # which topic delivered it (PubSub doesn't include the topic in
  # the message), so we classify by payload shape. For tuple-typed
  # messages (the current pattern) the first element's atom prefix
  # tells us the topic:
  #
  #   :chat_agent_*        → "chat_agents"
  #   :docker_state_*      → "docker_observer"
  #   :services_updated /
  #   :compose_result      → "workspace_services"
  #
  # When Move #2 (publisher modules) lands and we start broadcasting
  # structs, this classification simplifies to reading the struct
  # module's topic attribute.
  @impl true
  def handle_info(msg, state) do
    seq = state.seq + 1
    now_ms = System.monotonic_time(:millisecond)
    now_utc = DateTime.utc_now()

    record = %{
      seq: seq,
      topic: classify_topic(msg),
      tag: classify_tag(msg),
      payload: format_payload(msg),
      inserted_at_ms: now_ms,
      inserted_at_utc: now_utc
    }

    :ets.insert(@table, {seq, record})
    maybe_trim(seq)

    {:noreply, %{state | seq: seq}}
  end

  # ── Private ──

  defp classify_topic(msg) when is_tuple(msg) and tuple_size(msg) > 0 do
    case elem(msg, 0) do
      tag when is_atom(tag) ->
        case Atom.to_string(tag) do
          "chat_agent_" <> _ -> "chat_agents"
          "chat_message" -> "chat_agents"
          "chat_text_delta" -> "chat_agents"
          "docker_state_" <> _ -> "docker_observer"
          "services_updated" -> "workspace_services"
          "compose_result" -> "workspace_services"
          _ -> "unknown"
        end

      _ ->
        "unknown"
    end
  end

  defp classify_topic(_), do: "unknown"

  defp classify_tag(msg) when is_tuple(msg) and tuple_size(msg) > 0 do
    case elem(msg, 0) do
      tag when is_atom(tag) -> tag
      _ -> :unknown
    end
  end

  defp classify_tag(%mod{}), do: mod
  defp classify_tag(_), do: :unknown

  defp format_payload(msg) do
    inspected = inspect(msg, limit: :infinity, pretty: false)

    if byte_size(inspected) > @max_payload_bytes do
      binary_part(inspected, 0, @max_payload_bytes) <> "…(truncated)"
    else
      inspected
    end
  end

  defp maybe_trim(seq) when rem(seq, 100) == 0 do
    # Every 100 inserts, trim to @max_records. Batched rather than
    # per-insert to keep the hot path fast.
    info = :ets.info(@table)
    size = Keyword.get(info, :size, 0)

    if size > @max_records do
      # Delete the oldest (size - @max_records) entries. Walk from
      # the smallest key upward.
      to_delete = size - @max_records

      :ets.select(@table, [{:"$1", [], [:"$1"]}])
      |> Enum.sort_by(fn {s, _} -> s end)
      |> Enum.take(to_delete)
      |> Enum.each(fn {s, _} -> :ets.delete(@table, s) end)
    end

    :ok
  end

  defp maybe_trim(_), do: :ok

  defp maybe_filter_topic(events, nil), do: events
  defp maybe_filter_topic(events, topic), do: Enum.filter(events, &(&1.topic == topic))

  defp maybe_filter_since(events, nil), do: events
  defp maybe_filter_since(events, since_ms), do: Enum.filter(events, &(&1.inserted_at_ms > since_ms))
end
