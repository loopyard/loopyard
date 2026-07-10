defmodule Loopyard.Events.ChatAgent do
  @moduledoc """
  Publisher module for the `"chat_agents"` PubSub topic.

  Move #2 of plans/coordination-hardening.md — every chat-agent lifecycle
  event that used to be broadcast as a tuple is now a struct defined below.
  Producers call `publish/1`; subscribers pattern-match on `%Struct{}` in
  `handle_info/2`. The module name itself is the universal identifier —
  grep for `Events.ChatAgent.Resumed` and you find every producer AND every
  consumer without having to know which tag atom they used to share.

  Every call to `Phoenix.PubSub.broadcast/3` on the `"chat_agents"` topic
  MUST go through this module. The `test/loopyard/pubsub_boundary_test.exs`
  CI check enforces it.
  """

  @topic "chat_agents"
  @telemetry [:loopyard, :events, :publish]

  alias Loopyard.Events.ChatAgent.{
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
  }

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
  def subscribe, do: Phoenix.PubSub.subscribe(Loopyard.PubSub, @topic)

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
  def publish(%StatusChanged{} = e) do
    # Mirror status onto the global/per-project activity stream (#54) so the
    # god-mode sidebar, Foreman, and sound layer get it without subscribing to
    # this topic directly. Both live in the events layer, so the pubsub
    # boundary holds.
    Loopyard.Events.Activity.record(e.id, :status, e.status)
    bcast(e)
  end
  def publish(%Quarantined{} = e), do: bcast(e)
  def publish(%Released{} = e), do: bcast(e)

  defp bcast(%mod{} = e) do
    :telemetry.execute(@telemetry, %{count: 1}, %{topic: @topic, event: mod})
    Phoenix.PubSub.broadcast(Loopyard.PubSub, @topic, e)
  end
end
