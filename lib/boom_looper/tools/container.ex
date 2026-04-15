defmodule BoomLooper.Tools.Container do
  @moduledoc """
  MCP toolkit for Docker container tools.

  Each tool is a separate module under `BoomLooper.Tools.Container.*`.
  This module is the entry point — `__tool_server__/0` returns the
  server name and the list of all tool modules.

  ## Adding a tool (security checklist — see docs/SECURITY.md)

  1. `use BoomLooper.Tool, ...` — this injects the session-bound
     `agent_id` check automatically via `@before_compile`.
  2. Derive the container/volume/compose project from the agent's own
     state via `Helpers.resolve_container/1`,
     `resolve_service_container/2`, or `agent_workspace_id/1`.
     Do NOT accept a `container_name`, `volume_name`, `workspace_id`,
     or `project_dir` parameter from the agent.
  3. If your tool accepts a filesystem path, run it through
     `Helpers.validate_workspace_path/1` before use.
  4. If your tool accepts a volume/container name as a param (e.g.
     the `Volumes` tool's action string), reject any value that isn't
     prefixed with the agent's own `bl-<workspace_id>`.
  5. Add a test that proves your tool rejects a foreign `agent_id` —
     `test/boom_looper/tool_authorization_test.exs` has a matrix test
     that will catch a missing check automatically, but a targeted
     test is clearer.
  """

  alias BoomLooper.Tools.Container

  # NOTE: Container.Docker (arbitrary `docker` CLI) is intentionally NOT
  # included. That tool was a workspace-boundary escape hatch — an agent
  # could `docker exec` into another workspace's containers or `docker
  # volume inspect` other volumes. All legitimate needs are covered by
  # the scoped tools below (DockerCompose, ServiceContainers, Logs,
  # Exec, Volumes, InspectService).
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
