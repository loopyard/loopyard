defmodule Hive.Tools.Container do
  @moduledoc """
  Tools for managing Docker containers. Agents use these to set up
  dev environments, run commands, and manage web servers.

  The agent handles Docker automatically — creates containers when needed,
  edits Dockerfiles to add dependencies, rebuilds when the env changes.
  """
  use ClaudeCode.MCP.Server, name: "hive-container"

  alias Hive.Docker

  # --- Public API ---

  def do_create(agent_id, opts \\ %{}) do
    dockerfile = Map.get(opts, :dockerfile)
    create_opts = if dockerfile, do: [dockerfile: dockerfile], else: []

    case Docker.create(agent_id, create_opts) do
      {:ok, _} ->
        {:ok, %{
          container: Docker.container_name(agent_id),
          port: Docker.host_port(agent_id),
          workspace: "/workspace"
        }}
      {:error, reason} ->
        {:error, reason}
    end
  end

  def do_exec(agent_id, command) do
    Docker.exec(agent_id, command)
  end

  def do_rebuild(agent_id) do
    case Docker.rebuild(agent_id) do
      {:ok, _} ->
        {:ok, "Container rebuilt from Dockerfile. Port: #{Docker.host_port(agent_id)}"}
      {:error, reason} ->
        {:error, reason}
    end
  end

  def do_stop(agent_id) do
    Docker.stop(agent_id)
    {:ok, "Container stopped"}
  end

  def do_destroy(agent_id) do
    Docker.destroy(agent_id)
    {:ok, "Container and volumes destroyed"}
  end

  def do_list do
    case System.cmd("docker", ["ps", "--filter", "name=hive-dev", "--format", "{{.Names}}\t{{.Status}}\t{{.Ports}}"],
           stderr_to_stdout: true) do
      {output, 0} ->
        containers =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            case String.split(line, "\t", parts: 3) do
              [name, status, ports] -> %{name: name, status: status, ports: ports}
              [name, status] -> %{name: name, status: status, ports: ""}
              _ -> %{name: line, status: "unknown", ports: ""}
            end
          end)
        {:ok, containers}
      {output, _} ->
        {:error, "Failed to list: #{String.slice(output, 0, 200)}"}
    end
  end

  # --- Tool definitions ---

  tool :create, "Create a Docker dev environment for this agent. Returns the container name, mapped port, and workspace path." do
    field :agent_id, :string, required: true
    field :dockerfile, :string, required: false

    def execute(%{agent_id: agent_id} = params) do
      Hive.Tools.Container.do_create(agent_id, params)
    end
  end

  tool :exec, "Run a shell command inside the agent's container" do
    field :agent_id, :string, required: true
    field :command, :string, required: true

    def execute(%{agent_id: agent_id, command: command}) do
      Hive.Tools.Container.do_exec(agent_id, command)
    end
  end

  tool :rebuild, "Rebuild the container after editing the Dockerfile in /workspace/Dockerfile. Preserves all files in /workspace." do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      Hive.Tools.Container.do_rebuild(agent_id)
    end
  end

  tool :stop, "Stop the container (volumes preserved for later)" do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      Hive.Tools.Container.do_stop(agent_id)
    end
  end

  tool :destroy, "Destroy container and all volumes permanently" do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      Hive.Tools.Container.do_destroy(agent_id)
    end
  end

  tool :list, "List all running Hive containers with their status and ports" do
    def execute(_params) do
      Hive.Tools.Container.do_list()
    end
  end
end
