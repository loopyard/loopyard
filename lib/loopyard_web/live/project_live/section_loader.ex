defmodule LoopyardWeb.ProjectLive.SectionLoader do
  @moduledoc """
  Workspace section loaders for `ProjectLive`.

  Mount asks only for `:agents`; `:fetch_service_counts` fills the rest
  via `start_async`. Sections not listed are returned as empty maps so
  callers can merge over existing assigns without wiping counts.

  Extracted from `ProjectLive` to keep the LiveView under its line cap
  and to make the load logic testable in isolation.
  """

  alias Loopyard.ChatAgent
  alias Loopyard.ProjectRegistry

  def load_workspaces(project, sections, existing \\ []) do
    ctx = %{agents: if(:agents in sections, do: ChatAgent.list_agents(), else: [])}

    ProjectRegistry.list_workspaces(project.id)
    |> Enum.map(fn workspace ->
      prior = Enum.find(existing, &(&1.id == workspace.id)) || %{}
      base = Map.merge(prior, workspace)

      Enum.reduce([:agents, :services, :volumes], base, fn section, ws ->
        Map.merge(ws, load_section(section, sections, workspace, ctx))
      end)
    end)
  end

  @doc """
  Merge fresh data for the requested sections into the existing assigns
  without re-fetching the rest. Used by `handle_info` callbacks that only
  need to refresh what they know changed.
  """
  def merge_sections(socket, sections) do
    load_workspaces(socket.assigns.project, sections, socket.assigns.workspaces)
  end

  @doc """
  Starting point for every workspace's count fields. Ensures the template
  always has these keys, even before the async sections fill arrives.
  """
  def seed_defaults(project) do
    ProjectRegistry.list_workspaces(project.id)
    |> Enum.map(fn ws ->
      Map.merge(ws, %{agent_count: 0, service_count: 0, services_running: 0, volume_count: 0})
    end)
  end

  defp load_section(:agents, sections, workspace, ctx) do
    if :agents in sections do
      count =
        Enum.count(ctx.agents, fn a ->
          a[:bind_mount] == workspace.path || a[:working_dir] == workspace.path ||
            a[:workspace_id] == workspace.id
        end)

      %{agent_count: count}
    else
      %{}
    end
  end

  defp load_section(:services, sections, workspace, _ctx) do
    if :services in sections do
      try do
        # ServiceStatus reads from docker-compose.yml — gives us all defined
        # services plus their current running state. Show total (so empty
        # workspaces don't look configurationless) and running side by side.
        statuses = Loopyard.Docker.Observer.services_for(workspace.id)

        %{
          service_count: length(statuses),
          services_running: Enum.count(statuses, &(&1.status == :running))
        }
      catch
        :exit, _ -> %{service_count: 0, services_running: 0}
      end
    else
      %{}
    end
  end

  defp load_section(:volumes, sections, workspace, _ctx) do
    if :volumes in sections do
      # Read from Docker.Observer's ETS cache — O(1), no shell-out. The
      # old path called VolumeManager.list_workspace_volumes which ran
      # `docker volume ls` + `docker volume inspect` + `docker run alpine du`
      # per volume. On machines with many volumes that blocked the LV.
      count = length(Loopyard.Docker.Observer.volumes_for(workspace.id))
      %{volume_count: count}
    else
      %{}
    end
  end
end
