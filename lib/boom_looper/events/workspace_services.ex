defmodule BoomLooper.Events.WorkspaceServices do
  @moduledoc """
  Publisher module for the `"workspace_services"` PubSub topic.

  Move #2 of plans/coordination-hardening.md. `Workspace.ServiceManager`
  broadcasts here when service statuses change or a compose up/down
  completes (the second one is what unsticks LVs from
  :starting / :stopping).
  """

  @topic "workspace_services"
  @telemetry [:boom_looper, :events, :publish]

  # Service statuses for a workspace have changed. Subscribers re-read
  # the ETS cache or ServiceStatus module to pick up the new state.
  # `path` is the workspace directory (canonical form).
  defmodule ServicesUpdated, do: defstruct([:path])

  # A compose up / down attempt completed. `result` is `:ok` or
  # `{:error, reason}`. LVs in :starting / :stopping watch for this
  # so they transition out even when no per-service status changes
  # (e.g. compose failed before any container started).
  defmodule ComposeResult, do: defstruct([:workspace_id, :result])

  @events [ServicesUpdated, ComposeResult]

  def events, do: @events
  def topic, do: @topic

  def subscribe, do: Phoenix.PubSub.subscribe(BoomLooper.PubSub, @topic)

  def publish(%ServicesUpdated{} = e), do: bcast(e)
  def publish(%ComposeResult{} = e), do: bcast(e)

  defp bcast(%mod{} = e) do
    :telemetry.execute(@telemetry, %{count: 1}, %{topic: @topic, event: mod})
    Phoenix.PubSub.broadcast(BoomLooper.PubSub, @topic, e)
  end
end

defmodule BoomLooper.Events.WorkspaceServices.Subscriber do
  @moduledoc """
  Behaviour for LiveViews that subscribe to `"workspace_services"`.
  """

  alias BoomLooper.Events.WorkspaceServices

  @type socket :: Phoenix.LiveView.Socket.t()
  @type result :: {:noreply, socket} | {:reply, map, socket}

  @callback on_services_updated(WorkspaceServices.ServicesUpdated.t(), socket) :: result
  @callback on_compose_result(WorkspaceServices.ComposeResult.t(), socket) :: result

  @optional_callbacks on_services_updated: 2, on_compose_result: 2
end
