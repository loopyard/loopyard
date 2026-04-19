defmodule BoomLooper.Events.ChatAgent do
  @moduledoc """
  Publisher module for the `"chat_agents"` PubSub topic.

  Move #2 of plans/coordination-hardening.md — every chat-agent lifecycle
  event that used to be broadcast as a tuple is now a struct defined below.
  Producers call `publish/1`; subscribers pattern-match on `%Struct{}` in
  `handle_info/2`. The module name itself is the universal identifier —
  grep for `Events.ChatAgent.Resumed` and you find every producer AND every
  consumer without having to know which tag atom they used to share.

  Every call to `Phoenix.PubSub.broadcast/3` on the `"chat_agents"` topic
  MUST go through this module. The `test/boom_looper/pubsub_boundary_test.exs`
  CI check enforces it.
  """

  @topic "chat_agents"
  @telemetry [:boom_looper, :events, :publish]

  # Agent started fresh. Payload is the summary map that ETS stores.
  defmodule Started, do: defstruct([:summary])

  # Agent stopped normally OR crashed (callers differentiate via summary.status).
  defmodule Stopped, do: defstruct([:summary])

  # Agent booting — the stub entry put in ETS before the GenServer is up.
  defmodule Booting, do: defstruct([:summary])

  # Boot progress tick. `status` is a short human-readable string.
  defmodule BootStatus, do: defstruct([:id, :status])

  # Boot definitively failed; the stub has been removed from ETS.
  defmodule BootFailed, do: defstruct([:id, :reason])

  # Agent removed from the workspace.
  defmodule Removed, do: defstruct([:id])

  # Agent renamed.
  defmodule Renamed, do: defstruct([:id, :name])

  # Agent GenServer restored from the log — same ID, fresh Claude session.
  defmodule Resumed, do: defstruct([:summary])

  # Agent status changed (:idle | :thinking | :crashed | :destroying | …).
  defmodule StatusChanged, do: defstruct([:id, :status])

  # Agent quarantined due to crash-loop.
  defmodule Quarantined, do: defstruct([:id, :summary])

  # Agent released from quarantine.
  defmodule Released, do: defstruct([:id])

  @events [
    Started,
    Stopped,
    Booting,
    BootStatus,
    BootFailed,
    Removed,
    Renamed,
    Resumed,
    StatusChanged,
    Quarantined,
    Released
  ]

  @doc "List of every event module published on this topic."
  def events, do: @events

  @doc "Topic name for this publisher."
  def topic, do: @topic

  @doc """
  Subscribe the current process to the `"chat_agents"` topic.
  """
  def subscribe, do: Phoenix.PubSub.subscribe(BoomLooper.PubSub, @topic)

  @doc """
  Broadcast an event to the `"chat_agents"` topic. The argument must be one
  of the structs defined in this module — any other shape raises a
  `FunctionClauseError` so typos are caught at the call site.
  """
  def publish(%Started{} = e), do: bcast(e)
  def publish(%Stopped{} = e), do: bcast(e)
  def publish(%Booting{} = e), do: bcast(e)
  def publish(%BootStatus{} = e), do: bcast(e)
  def publish(%BootFailed{} = e), do: bcast(e)
  def publish(%Removed{} = e), do: bcast(e)
  def publish(%Renamed{} = e), do: bcast(e)
  def publish(%Resumed{} = e), do: bcast(e)
  def publish(%StatusChanged{} = e), do: bcast(e)
  def publish(%Quarantined{} = e), do: bcast(e)
  def publish(%Released{} = e), do: bcast(e)

  defp bcast(%mod{} = e) do
    :telemetry.execute(@telemetry, %{count: 1}, %{topic: @topic, event: mod})
    Phoenix.PubSub.broadcast(BoomLooper.PubSub, @topic, e)
  end
end
