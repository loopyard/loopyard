defmodule BoomLooper.Tools.Container do
  @moduledoc """
  MCP toolkit for Docker container tools.

  Each tool is a separate module under `BoomLooper.Tools.Container.*`.
  This module is the entry point — `__tool_server__/0` returns the server
  name and the list of all tool modules.
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
    Container.Volumes,
    Container.FileUrl,
    Container.AppUrl
  ]

  def __tool_server__ do
    %{name: "boom-looper-container", tools: @tools}
  end

  defdelegate validate_workspace_path(path), to: Container.Helpers
end
