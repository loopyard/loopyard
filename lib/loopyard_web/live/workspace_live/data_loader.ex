defmodule LoopyardWeb.Live.WorkspaceLive.DataLoader do
  @moduledoc """
  Async data-loading helpers for `LoopyardWeb.WorkspaceLive`: kicking off
  the container-tab Docker fetch, loading git log/status, and priming the
  agent roster from the persisted log.

  Split out of the LiveView to keep it under its size cap. `fetch_container_data/1`
  takes and returns a socket (it schedules a `start_async`); `load_git_data/1`
  and `prime_agents_from_log/1` are plain data helpers.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [start_async: 3]

  require Logger

  def load_git_data(assigns) do
    project = assigns.project
    workspace_entry = assigns.workspace_entry

    if project && workspace_entry do
      adapter = Loopyard.Source.for_project(project)

      if Loopyard.Source.supports_git?(adapter) do
        log_result = adapter.git_log(project, workspace_entry, limit: 20)
        status_result = adapter.git_status(project, workspace_entry)
        {log_result, status_result}
      else
        {{:ok, []}, {:ok, []}}
      end
    else
      {{:ok, []}, {:ok, []}}
    end
  end

  # Populate :chat_agents ETS from the workspace's persisted agent log.
  # Idempotent — safe to call multiple times or when ServiceManager has
  # already run replay. Does NOT start ChatAgent GenServers; the log
  # contents are just made visible to `list_agents/0` so the sidebar can
  # render agents as stopped (their status in the log is preserved,
  # typically :idle, which matches "available but not actively thinking").
  def prime_agents_from_log(workspace_id) do
    log_path = Loopyard.ChatAgent.Persistence.log_path(workspace_id)

    cond do
      is_nil(log_path) or not File.exists?(log_path) ->
        :ok

      workspace_already_in_ets?(workspace_id) ->
        # ServiceManager already replayed for this workspace. Don't
        # overwrite live agents' runtime status with stale log status.
        :ok

      true ->
        Loopyard.AgentLog.replay(
          log_path: log_path,
          version: 1,
          ets_table: :chat_agents
        )
    end
  rescue
    e ->
      Logger.warning("[workspace_live] prime_agents_from_log failed: #{Exception.message(e)}")
  end

  defp workspace_already_in_ets?(workspace_id) do
    Enum.any?(Loopyard.ChatAgent.list_agents(), &(&1[:workspace_id] == workspace_id))
  end

  # Kicks off three Docker calls (container_running?, do_logs, do_inspect)
  # in a single Task. Mounted callers (handle_params for the container tab)
  # call this and return immediately; the assigns get filled in once the
  # Task lands via handle_async(:container_data, ...).
  #
  # While loading, we render placeholder assigns so the page paints.
  def fetch_container_data(socket) do
    case socket.assigns.selected_id do
      nil ->
        socket

      id ->
        agent_state = Loopyard.ChatAgent.get_state(id)
        workspace_id = agent_state && agent_state[:workspace_id]
        log_service = socket.assigns.container_log_service

        socket
        |> assign(:container_logs, socket.assigns.container_logs || "")
        |> assign(:container_env, socket.assigns.container_env)
        |> assign(:has_container, socket.assigns.has_container || false)
        |> start_async({:container_data, id}, fn ->
          ws_container =
            if workspace_id,
              do:
                Loopyard.Workspace.ServiceManager.service_container_name(
                  workspace_id,
                  "workspace"
                )

          has_container =
            ws_container != nil && Loopyard.Docker.container_running?(ws_container)

          if has_container do
            log_opts = %{lines: 100}

            log_opts =
              if log_service, do: Map.put(log_opts, :service, log_service), else: log_opts

            logs =
              case Loopyard.Tools.Container.Logs.execute(
                     %{agent_id: id, lines: log_opts[:lines], service: log_opts[:service]},
                     %{}
                   ) do
                {:ok, output} -> output
                {:error, err} -> "Error: #{err}"
              end

            env =
              case Loopyard.Tools.Container.InspectEnv.execute(%{agent_id: id}, %{}) do
                {:ok, output} -> output
                _ -> nil
              end

            %{has_container: true, logs: logs, env: env}
          else
            %{has_container: false, logs: "", env: nil}
          end
        end)
    end
  end
end
