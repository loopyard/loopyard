defmodule Hive.Tools.Workspace do
  @moduledoc """
  MCP tools for workspace configuration management.
  Allows agents to save/load workspace config, start/stop services,
  and rebuild their own container with a new Dockerfile.
  """
  use ClaudeCode.MCP.Server, name: "hive-workspace"

  alias Hive.Workspace
  alias Hive.Workspace.ServiceManager

  # --- Public API ---

  def do_save_workspace(agent_id, config) when is_map(config) do
    config = decode_string_fields(config)

    with_bind_mount(agent_id, fn project_dir ->
      workspace = Workspace.from_map(config)

      case Workspace.save(project_dir, workspace) do
        :ok -> {:ok, "Workspace config saved to #{Workspace.config_path(project_dir)}"}
        {:error, reason} -> {:error, "Failed to save: #{inspect(reason)}"}
      end
    end)
  end

  def do_load_workspace(agent_id) do
    with_bind_mount(agent_id, fn project_dir ->
      case Workspace.load(project_dir) do
        {:ok, ws} -> {:ok, Workspace.to_map(ws)}
        :none -> {:ok, nil}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def do_start_services(agent_id) do
    with_bind_mount(agent_id, fn project_dir ->
      case ServiceManager.start_services(project_dir) do
        {:ok, results} ->
          summary = Enum.map(results, fn
            {:ok, :started} -> "started"
            {:ok, :already_running} -> "already running"
            {:error, reason} -> "error: #{reason}"
          end)

          {:ok, %{results: summary}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  def do_stop_services(agent_id) do
    with_bind_mount(agent_id, fn project_dir ->
      ServiceManager.stop_services(project_dir)
      {:ok, "Services stopped"}
    end)
  end

  def do_rebuild(agent_id, dockerfile) do
    with_bind_mount(agent_id, fn project_dir ->
      env_vars =
        case Workspace.load(project_dir) do
          {:ok, ws} -> ws.env_vars || %{}
          _ -> %{}
        end

      case Hive.Docker.rebuild(agent_id, dockerfile, bind_mount: project_dir, env_vars: env_vars) do
        {:ok, _} -> {:ok, "Container rebuilt successfully with new Dockerfile"}
        {:error, reason} -> {:error, "Rebuild failed: #{reason}"}
      end
    end)
  end

  def do_service_status(agent_id) do
    with_bind_mount(agent_id, fn project_dir ->
      ServiceManager.service_status(project_dir)
    end)
  end

  # --- Tool definitions ---

  tool :save_workspace, "Save workspace configuration to .hive/workspace.json. Provide the workspace name, a Dockerfile string, services as a JSON array, processes as a JSON array, env_vars as a JSON object, and an optional system_prompt." do
    field :agent_id, :string, required: true
    field :name, :string, required: true, description: "Project name"
    field :dockerfile, :string, required: true, description: "Full Dockerfile content for the dev container"
    field :services, :string, required: false, description: "JSON array of services, e.g. [{\"name\":\"postgres\",\"image\":\"postgres:16\",\"env\":{},\"volumes\":[],\"ports\":{}}]"
    field :processes, :string, required: false, description: "JSON array of dev processes, e.g. [{\"name\":\"web\",\"command\":\"bin/rails server\"}]"
    field :env_vars, :string, required: false, description: "JSON object of environment variables, e.g. {\"DATABASE_URL\":\"postgres://...\"}"
    field :system_prompt, :string, required: false, description: "System prompt fragment for future agents working on this project"

    def execute(%{agent_id: agent_id} = params) do
      config = %{
        "name" => params.name,
        "dockerfile" => params.dockerfile,
        "services" => Hive.Tools.Workspace.parse_json_field(params[:services], []),
        "processes" => Hive.Tools.Workspace.parse_json_field(params[:processes], []),
        "env_vars" => Hive.Tools.Workspace.parse_json_field(params[:env_vars], %{}),
        "system_prompt" => params[:system_prompt]
      }

      Hive.Tools.Workspace.do_save_workspace(agent_id, config)
    end
  end

  tool :load_workspace, "Load the current workspace configuration from .hive/workspace.json. Returns null if no config exists yet." do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      Hive.Tools.Workspace.do_load_workspace(agent_id)
    end
  end

  tool :start_services, "Start all service containers defined in the workspace config (databases, caches, etc.)" do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      Hive.Tools.Workspace.do_start_services(agent_id)
    end
  end

  tool :stop_services, "Stop all workspace service containers" do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      Hive.Tools.Workspace.do_stop_services(agent_id)
    end
  end

  tool :rebuild, "Rebuild the agent's container with a new Dockerfile. The container is replaced but the Claude session stays alive. Use this after saving workspace config to get the right language/tools installed." do
    field :agent_id, :string, required: true
    field :dockerfile, :string, required: true

    def execute(%{agent_id: agent_id, dockerfile: dockerfile}) do
      Hive.Tools.Workspace.do_rebuild(agent_id, dockerfile)
    end
  end

  tool :service_status, "Check which workspace services are running" do
    field :agent_id, :string, required: true

    def execute(%{agent_id: agent_id}) do
      Hive.Tools.Workspace.do_service_status(agent_id)
    end
  end

  @doc false
  def parse_json_field(nil, default), do: default

  def parse_json_field(value, default) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, parsed} -> parsed
      {:error, _} -> default
    end
  end

  def parse_json_field(value, _default), do: value

  # --- Private ---

  defp with_bind_mount(agent_id, callback) do
    case find_bind_mount(agent_id) do
      {:ok, project_dir} -> callback.(project_dir)
      :error -> {:error, "Agent #{agent_id} has no bind mount"}
    end
  end

  defp decode_string_fields(config) do
    config
    |> Map.update("services", [], &parse_json_field(&1, []))
    |> Map.update("processes", [], &parse_json_field(&1, []))
    |> Map.update("env_vars", %{}, &parse_json_field(&1, %{}))
  end

  defp find_bind_mount(agent_id) do
    case Hive.ChatAgent.get_state(agent_id) do
      %{bind_mount: dir} when is_binary(dir) -> {:ok, dir}
      %{working_dir: dir} when is_binary(dir) -> {:ok, dir}
      _ -> :error
    end
  end
end
