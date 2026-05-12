defmodule Loopyard.Events.WorkspaceServices do
  @moduledoc """
  Publisher module for the `"workspace_services"` PubSub topic.

  Move #2 of plans/coordination-hardening.md. `Workspace.ServiceManager`
  broadcasts here when service statuses change or a compose up/down
  completes (the second one is what unsticks LVs from
  :starting / :stopping).
  """

  @topic "workspace_services"
  @telemetry [:loopyard, :events, :publish]

  alias Loopyard.Events.WorkspaceServices.{ServicesUpdated, ComposeResult}

  @events [ServicesUpdated, ComposeResult]

  def events, do: @events
  def topic, do: @topic

  def subscribe, do: Phoenix.PubSub.subscribe(Loopyard.PubSub, @topic)

  def publish(%ServicesUpdated{} = e), do: bcast(e)
  def publish(%ComposeResult{} = e), do: bcast(e)

  defp bcast(%mod{} = e) do
    :telemetry.execute(@telemetry, %{count: 1}, %{topic: @topic, event: mod})
    Phoenix.PubSub.broadcast(Loopyard.PubSub, @topic, e)
  end
end

defmodule Loopyard.Events.WorkspaceServices.Subscriber do
  @moduledoc """
  Behaviour for LiveViews that subscribe to `"workspace_services"`.
  """

  alias Loopyard.Events.WorkspaceServices

  @type socket :: Phoenix.LiveView.Socket.t()
  @type result :: {:noreply, socket} | {:reply, map, socket}

  @callback on_services_updated(WorkspaceServices.ServicesUpdated.t(), socket) :: result
  @callback on_compose_result(WorkspaceServices.ComposeResult.t(), socket) :: result

  # See plans/post-migration-audit.md MEDIUM #5 — no @optional_callbacks.
end
