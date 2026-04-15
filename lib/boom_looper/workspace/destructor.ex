defmodule BoomLooper.Workspace.Destructor do
  @moduledoc """
  Tear down a workspace completely — no orphans.

  Before this module existed, `WorkspaceRegistry.remove_workspace/1`
  called the source adapter's teardown (Mutagen session, host worktree)
  and stopped there. Containers, compose networks, named volumes,
  running agents, agent log files, the compose directory on the host,
  and ETS entries for chat agents were all left behind. Users
  accumulated gigabytes of ghost volumes and stale `bl-*` containers
  after a few weeks of normal use.

  `destroy/1` runs every teardown step in the right order, continues
  through failures (logging them to `EventLog`) so a half-dead
  workspace still ends up fully gone, and is idempotent — re-running
  it on an already-destroyed workspace is a no-op.
  """

  require Logger

  alias BoomLooper.{Compose, Docker, EventLog, ProjectRegistry, Workspace, WorkspaceRegistry, WorkspaceSupervisor}
  alias BoomLooper.VolumeManager

  @doc """
  Destroy a workspace: stop agents, tear down containers/networks/volumes,
  run adapter-specific teardown, delete the compose dir, clear ETS.

  Returns `:ok` always (soft-fail per step — see module doc).
  """
  def destroy(workspace_id) when is_binary(workspace_id) do
    workspace = WorkspaceRegistry.get_workspace(workspace_id)

    if is_nil(workspace) do
      # Already gone — still sweep for orphan volumes/containers just in
      # case a previous destroy was interrupted mid-way.
      EventLog.info("workspace:#{workspace_id}", "destroy: no ETS entry, sweeping for orphans")
      sweep_orphans(workspace_id)
      :ok
    else
      EventLog.info("workspace:#{workspace_id}", "destroy: tearing down workspace")

      stop_agents(workspace_id, workspace)
      compose_down(workspace_id, workspace)
      stop_supervisor_subtree(workspace_id)
      adapter_teardown(workspace)
      remove_named_volumes(workspace_id, workspace)
      remove_compose_dir(workspace_id)
      release_ports(workspace_id)
      clear_ets(workspace_id)

      EventLog.info("workspace:#{workspace_id}", "destroy: complete")
      :ok
    end
  end

  # --- Steps ---

  # Stop every ChatAgent that was running inside this workspace. We stop
  # them explicitly (rather than relying on the supervisor teardown)
  # so the agent gets a clean `terminate` and the ETF log is closed
  # cleanly — the file is removed below but a mid-write crash leaves
  # a truncated record behind.
  defp stop_agents(workspace_id, workspace) do
    step(workspace_id, "stop agents", fn ->
      agents = BoomLooper.ChatAgent.list_agents()

      matches =
        Enum.filter(agents, fn a ->
          a[:workspace_id] == workspace_id or
            a[:bind_mount] == workspace[:path] or
            a[:working_dir] == workspace[:path]
        end)

      for agent <- matches do
        try_silently(fn -> BoomLooper.ChatAgent.stop_agent(agent.id) end)
        try_silently(fn -> BoomLooper.ChatAgent.remove_agent(agent.id) end)
      end

      :ok
    end)
  end

  # `docker compose down -v --remove-orphans` removes containers, the
  # project's default network, and any named volumes that were declared
  # anonymously in the compose file. Named volumes declared `external: true`
  # (including the code volume) survive — we remove those explicitly
  # in `remove_named_volumes/2` so the user can't lose data by
  # accident if they declared an external volume.
  defp compose_down(workspace_id, _workspace) do
    step(workspace_id, "compose down", fn ->
      project_dir = Workspace.compose_dir(workspace_id)

      # `down` is a no-op if there's no compose file or no containers;
      # that's the idempotency we want.
      case Compose.compose(project_dir, workspace_id, ["down", "-v", "--remove-orphans"],
             timeout: 60_000
           ) do
        {:ok, _} -> :ok
        # "no configuration file" is expected for workspaces that never booted.
        {:error, reason} -> {:soft_error, reason}
      end
    end)
  end

  defp stop_supervisor_subtree(workspace_id) do
    step(workspace_id, "stop supervisor", fn ->
      WorkspaceSupervisor.stop_workspace(workspace_id)
      :ok
    end)
  end

  # Source adapters own adapter-specific teardown: Mutagen sync session
  # + host worktree for Local, nothing for GitHub. Failures here don't
  # block the rest of the cleanup.
  defp adapter_teardown(workspace) do
    step(workspace.id, "adapter teardown", fn ->
      project = ProjectRegistry.get_project(workspace[:project_id])
      adapter = BoomLooper.Source.for_project(project || %{})
      adapter.remove_workspace(project || %{}, workspace)
    end)
  end

  # Remove every `bl-<workspace_id>*` volume Docker knows about. Covers
  # the code volume plus any auxiliary volumes the compose file declared
  # (cache, deps, etc.) that `down -v` might have missed because they
  # were `external: true`.
  defp remove_named_volumes(workspace_id, _workspace) do
    step(workspace_id, "remove volumes", fn ->
      volumes = VolumeManager.list_all_volumes()
      prefix = "bl-#{workspace_id}"

      for %{name: name} <- volumes, String.starts_with?(name, prefix) do
        try_silently(fn -> VolumeManager.delete_volume(name) end)
      end

      :ok
    end)
  end

  defp remove_compose_dir(workspace_id) do
    step(workspace_id, "remove compose dir", fn ->
      dir = Workspace.compose_dir(workspace_id)
      File.rm_rf(dir)
      :ok
    end)
  end

  # Return the workspace's assigned host ports to the PortRegistry
  # pool. Runs after compose_down so the containers are already
  # unbound and no ServiceManager is still holding a port.
  defp release_ports(workspace_id) do
    step(workspace_id, "release ports", fn ->
      BoomLooper.PortRegistry.release_workspace(workspace_id)
    end)
  end

  defp clear_ets(workspace_id) do
    step(workspace_id, "clear ETS", fn ->
      WorkspaceRegistry.delete(workspace_id)
      :ok
    end)
  end

  # Sweep path for an already-deleted workspace: try to find any
  # remaining bl-<workspace_id>* containers/volumes and remove them.
  # Runs when the ETS entry is already gone — typically after an
  # interrupted teardown.
  defp sweep_orphans(workspace_id) do
    step(workspace_id, "sweep orphan containers", fn ->
      case Docker.docker(["ps", "-a", "--filter", "name=bl-#{workspace_id}", "--format", "{{.ID}}"]) do
        {:ok, output} ->
          for id <- String.split(output, "\n", trim: true) do
            try_silently(fn -> Docker.docker(["rm", "-f", id]) end)
          end

          :ok

        other ->
          {:soft_error, other}
      end
    end)

    remove_named_volumes(workspace_id, %{})
    remove_compose_dir(workspace_id)
  end

  # --- Helpers ---

  # Run a teardown step. Never raises — a cleanup function that crashes
  # leaves a half-destroyed workspace behind, which is worse than any
  # single failed step. All outcomes log to EventLog.
  defp step(workspace_id, name, fun) do
    try do
      case fun.() do
        :ok ->
          :ok

        {:soft_error, reason} ->
          EventLog.warning(
            "workspace:#{workspace_id}",
            "destroy (#{name}): #{inspect(reason)} — continuing"
          )

        other ->
          EventLog.warning(
            "workspace:#{workspace_id}",
            "destroy (#{name}): unexpected return #{inspect(other)} — continuing"
          )
      end
    rescue
      e ->
        EventLog.error(
          "workspace:#{workspace_id}",
          "destroy (#{name}) crashed: #{Exception.message(e)} — continuing"
        )
    catch
      :exit, reason ->
        EventLog.error(
          "workspace:#{workspace_id}",
          "destroy (#{name}) exited: #{inspect(reason)} — continuing"
        )
    end
  end

  defp try_silently(fun) do
    try do
      fun.()
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end
end
