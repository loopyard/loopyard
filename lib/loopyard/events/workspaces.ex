defmodule Loopyard.Events.Workspaces do
  @moduledoc """
  Publisher for the per-project `"project_workspaces:{project_id}"` PubSub topic
  — a workspace was created or removed, or its status changed, within a project.
  The workspace switcher (`WorkspaceLive`) and the project page grid
  (`ProjectLive`) subscribe so a fork someone makes shows up — and status dots
  move — in real time, no refresh. Multiplayer by default.

  Per the PubSub boundary rule this is the ONLY place these broadcasts happen;
  every subscriber implements the `Subscriber` behaviour with an explicit
  callback (no `@optional_callbacks`).
  """
  @telemetry [:loopyard, :events, :publish]

  alias Loopyard.Events.Workspaces.Changed

  @events [Changed]

  def events, do: @events

  def topic(project_id), do: "project_workspaces:#{project_id}"

  def subscribe(project_id) when is_binary(project_id),
    do: Phoenix.PubSub.subscribe(Loopyard.PubSub, topic(project_id))

  def publish(%Changed{project_id: pid} = e) when is_binary(pid), do: bcast(pid, e)
  def publish(%Changed{}), do: :ok

  defp bcast(project_id, %mod{} = e) do
    t = topic(project_id)
    :telemetry.execute(@telemetry, %{count: 1}, %{topic: t, event: mod})
    Phoenix.PubSub.broadcast(Loopyard.PubSub, t, e)
  end
end

defmodule Loopyard.Events.Workspaces.Subscriber do
  @moduledoc """
  Behaviour for LiveViews that subscribe to a project's workspace-list topic.
  Implement `on_workspaces_changed/2` explicitly (no `@optional_callbacks`).
  """

  alias Loopyard.Events.Workspaces

  @type socket :: Phoenix.LiveView.Socket.t()
  @type result :: {:noreply, socket} | {:reply, map, socket}

  @callback on_workspaces_changed(Workspaces.Changed.t(), socket) :: result
end
