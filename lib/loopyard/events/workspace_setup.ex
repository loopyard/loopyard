defmodule Loopyard.Events.WorkspaceSetup do
  @moduledoc """
  Publisher module for the per-workspace `"workspace_setup:{workspace_id}"`
  PubSub topic plus a global `"workspace_setup:*"` topic for dashboard
  cards. `Loopyard.Workspace.Setup` publishes here as the setup saga
  progresses.

  Per `CLAUDE.md` "Coordination hardening" rules: this is the SOLE
  broadcaster of WorkspaceSetup events. Every subscriber implements the
  `Subscriber` behaviour with explicit callbacks (no `@optional_callbacks`).
  """

  @telemetry [:loopyard, :events, :publish]

  alias Loopyard.Events.WorkspaceSetup.{
    Started,
    PhaseStarted,
    PhaseCompleted,
    PhaseProgress,
    Completed,
    Failed,
    RetryScheduled
  }

  @events [
    Started,
    PhaseStarted,
    PhaseCompleted,
    PhaseProgress,
    Completed,
    Failed,
    RetryScheduled
  ]

  def events, do: @events

  def topic(workspace_id), do: "workspace_setup:#{workspace_id}"
  def topic_global, do: "workspace_setup:*"

  def subscribe(workspace_id),
    do: Phoenix.PubSub.subscribe(Loopyard.PubSub, topic(workspace_id))

  def subscribe_global,
    do: Phoenix.PubSub.subscribe(Loopyard.PubSub, topic_global())

  # One publish/1 clause per event struct, per the Coordination Hardening
  # rule: only this module's exhaustive clauses may broadcast.
  def publish(%Started{workspace_id: id} = e) when is_binary(id), do: bcast(id, e)
  def publish(%PhaseStarted{workspace_id: id} = e) when is_binary(id), do: bcast(id, e)
  def publish(%PhaseCompleted{workspace_id: id} = e) when is_binary(id), do: bcast(id, e)
  def publish(%PhaseProgress{workspace_id: id} = e) when is_binary(id), do: bcast(id, e)
  def publish(%Completed{workspace_id: id} = e) when is_binary(id), do: bcast(id, e)
  def publish(%Failed{workspace_id: id} = e) when is_binary(id), do: bcast(id, e)
  def publish(%RetryScheduled{workspace_id: id} = e) when is_binary(id), do: bcast(id, e)

  defp bcast(workspace_id, %mod{} = e) do
    t = topic(workspace_id)
    g = topic_global()
    :telemetry.execute(@telemetry, %{count: 1}, %{topic: t, event: mod})
    Phoenix.PubSub.broadcast(Loopyard.PubSub, t, e)
    Phoenix.PubSub.broadcast(Loopyard.PubSub, g, e)
  end
end

defmodule Loopyard.Events.WorkspaceSetup.Subscriber do
  @moduledoc """
  Behaviour for LiveViews and other processes that subscribe to a
  workspace's setup topic. Every callback is required — explicit opt-out
  is `def on_<event>(_, s), do: {:noreply, s}`.
  """

  alias Loopyard.Events.WorkspaceSetup

  @type socket :: Phoenix.LiveView.Socket.t()
  @type result :: {:noreply, socket} | {:reply, map, socket}

  # Callbacks are prefixed with `on_setup_` to avoid colliding with
  # generic-named callbacks from sibling subscriber behaviours
  # (e.g. `Events.ChatAgent.Subscriber` already defines `on_started/2`).
  @callback on_setup_started(WorkspaceSetup.Started.t(), socket) :: result
  @callback on_setup_phase_started(WorkspaceSetup.PhaseStarted.t(), socket) :: result
  @callback on_setup_phase_completed(WorkspaceSetup.PhaseCompleted.t(), socket) :: result
  @callback on_setup_phase_progress(WorkspaceSetup.PhaseProgress.t(), socket) :: result
  @callback on_setup_completed(WorkspaceSetup.Completed.t(), socket) :: result
  @callback on_setup_failed(WorkspaceSetup.Failed.t(), socket) :: result
  @callback on_setup_retry_scheduled(WorkspaceSetup.RetryScheduled.t(), socket) :: result
end
