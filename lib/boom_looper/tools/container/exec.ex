defmodule BoomLooper.Tools.Container.Exec do
  @moduledoc false

  alias BoomLooper.Docker
  alias BoomLooper.Tools.Container.Helpers

  def __tool_name__, do: "exec"

  def __description__,
    do:
      "Run a shell command inside the container. Use timeout for long-running commands (dependency installs, builds, etc.)."

  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "agent_id" => %{"type" => "string"},
        "command" => %{"type" => "string"},
        "workdir" => %{"type" => "string"},
        "timeout" => %{"type" => "integer", "description" => "Max seconds to run (default: 120)"}
      },
      "required" => ["agent_id", "command"]
    }
  end

  def execute(%{agent_id: agent_id, command: command} = params, _assigns) do
    timeout = Map.get(params, :timeout, 120)

    with :ok <- Helpers.validate_string(command, "command", 10_000),
         :ok <- Helpers.validate_timeout(timeout),
         {:ok, container} <- Helpers.resolve_container(agent_id) do
      exec_opts = []
      exec_opts = if Map.has_key?(params, :workdir), do: Keyword.put(exec_opts, :workdir, params.workdir), else: exec_opts
      exec_opts = if Map.has_key?(params, :timeout), do: Keyword.put(exec_opts, :timeout, params.timeout * 1_000), else: exec_opts

      Docker.exec_in(container, command, exec_opts)
    end
  end
end
