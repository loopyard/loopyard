defmodule BoomLooper.Tools.Container do
  @moduledoc """
  MCP tools for interacting with Docker containers.

  Workspace agents exec into the workspace container (always alive, sleep infinity).
  Service agents exec into their service's container (dev, postgres, etc.).

  Each tool is a separate module under `BoomLooper.Tools.Container.*`.
  This module is the toolkit entry point — `__tool_server__/0` returns
  the server name and the list of all 20 tool modules.
  """

  alias BoomLooper.Tools.Container

  @tools [
    Container.Exec,
    Container.ExecStream,
    Container.Logs,
    Container.InspectEnv,
    Container.ServiceContainers,
    Container.Ports,
    Container.WriteFile,
    Container.ReadFile,
    Container.Edit,
    Container.MultiEdit,
    Container.Grep,
    Container.Glob,
    Container.ProbeHttp,
    Container.Tree,
    Container.InspectService,
    Container.ReadFiles,
    Container.Docker,
    Container.DockerCompose,
    Container.WorkspaceInfo,
    Container.Volumes
  ]

  def __tool_server__ do
    %{name: "boom-looper-container", tools: @tools}
  end

  # --- Delegate functions for external callers ---

  defdelegate validate_workspace_path(path), to: Container.Helpers

  @doc "Run a shell command. Delegates to Exec tool."
  def do_exec(agent_id, command, opts \\ %{}) do
    params = Map.merge(opts, %{agent_id: agent_id, command: command})
    Container.Exec.execute(params, %{})
  end

  @doc "View container logs. Delegates to Logs tool."
  def do_logs(agent_id, opts \\ %{}) do
    params = Map.merge(opts, %{agent_id: agent_id})
    Container.Logs.execute(params, %{})
  end

  @doc "Inspect container environment. Delegates to InspectEnv tool."
  def do_inspect(agent_id) do
    Container.InspectEnv.execute(%{agent_id: agent_id}, %{})
  end

  @doc "Show listening ports. Delegates to Ports tool."
  def do_ports(agent_id) do
    Container.Ports.execute(%{agent_id: agent_id}, %{})
  end

  @doc "Write a file. Delegates to WriteFile tool."
  def do_write_file(agent_id, path, content) do
    Container.WriteFile.execute(%{agent_id: agent_id, path: path, content: content}, %{})
  end

  @doc "Read a file. Delegates to ReadFile tool."
  def do_read_file(agent_id, path) do
    Container.ReadFile.execute(%{agent_id: agent_id, path: path}, %{})
  end

  @doc "Atomic find/replace. Delegates to Edit tool."
  def do_edit(agent_id, path, old_string, new_string, opts \\ %{}) do
    params = Map.merge(opts, %{agent_id: agent_id, path: path, old_string: old_string, new_string: new_string})
    Container.Edit.execute(params, %{})
  end

  @doc "Multi-edit. Delegates to MultiEdit tool."
  def do_multi_edit(agent_id, path, edits) do
    Container.MultiEdit.execute(%{agent_id: agent_id, path: path, edits: Jason.encode!(edits)}, %{})
  end

  @doc "Grep. Delegates to Grep tool."
  def do_grep(agent_id, pattern, opts \\ %{}) do
    params = Map.merge(opts, %{agent_id: agent_id, pattern: pattern})
    Container.Grep.execute(params, %{})
  end

  @doc "Glob. Delegates to Glob tool."
  def do_glob(agent_id, pattern, opts \\ %{}) do
    params = Map.merge(opts, %{agent_id: agent_id, pattern: pattern})
    Container.Glob.execute(params, %{})
  end

  @doc "Run docker command. Delegates to Docker tool."
  def do_docker(command, timeout_seconds) do
    Container.Docker.execute(%{agent_id: "_", command: command, timeout: timeout_seconds}, %{})
  end

  @doc "Run docker compose command. Delegates to DockerCompose tool."
  def do_docker_compose(agent_id, command, timeout_seconds) do
    Container.DockerCompose.execute(%{agent_id: agent_id, command: command, timeout: timeout_seconds}, %{})
  end

  @doc "Get workspace info. Delegates to WorkspaceInfo tool."
  def do_workspace_info(agent_id) do
    Container.WorkspaceInfo.execute(%{agent_id: agent_id}, %{})
  end

  @doc "List/inspect volumes. Delegates to Volumes tool."
  def do_volumes(agent_id, action) do
    Container.Volumes.execute(%{agent_id: agent_id, action: action}, %{})
  end

  @doc "List service containers. Delegates to ServiceContainers tool."
  def do_service_containers(agent_id) do
    Container.ServiceContainers.execute(%{agent_id: agent_id}, %{})
  end

  @doc "Exec stream. Delegates to ExecStream tool."
  def do_exec_stream(agent_id, command, timeout_seconds) do
    Container.ExecStream.execute(%{agent_id: agent_id, command: command, timeout: timeout_seconds}, %{})
  end

  @doc "Probe HTTP. Delegates to ProbeHttp tool."
  def do_probe_http(agent_id, opts \\ %{}) do
    params = Map.merge(opts, %{agent_id: agent_id})
    Container.ProbeHttp.execute(params, %{})
  end

  @doc "Tree. Delegates to Tree tool."
  def do_tree(agent_id, opts \\ %{}) do
    params = Map.merge(opts, %{agent_id: agent_id})
    Container.Tree.execute(params, %{})
  end

  @doc "Inspect service. Delegates to InspectService tool."
  def do_inspect_service(agent_id, name) do
    Container.InspectService.execute(%{agent_id: agent_id, name: name}, %{})
  end

  @doc "Read multiple files. Delegates to ReadFiles tool."
  def do_read_files(agent_id, paths) do
    Container.ReadFiles.execute(%{agent_id: agent_id, paths: Jason.encode!(paths)}, %{})
  end
end
