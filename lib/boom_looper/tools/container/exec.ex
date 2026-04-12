defmodule BoomLooper.Tools.Container.Exec do
  use BoomLooper.Tool,
    name: "exec",
    description: "Run a shell command inside the container. Use timeout for long-running commands (dependency installs, builds, etc.).",
    params: [
      agent_id: {:string, required: true},
      command: {:string, required: true},
      workdir: :string,
      timeout: {:integer, description: "Max seconds to run (default: 120)"}
    ]

  alias BoomLooper.Docker
  alias BoomLooper.Tools.Container.Helpers

  def execute(%{agent_id: agent_id, command: command} = params, _assigns) do
    timeout = Map.get(params, :timeout, 120)

    with :ok <- Helpers.validate_string(command, "command", 10_000),
         :ok <- Helpers.validate_timeout(timeout),
         {:ok, container} <- Helpers.resolve_container(agent_id) do
      opts = []
      opts = if params[:workdir], do: Keyword.put(opts, :workdir, params.workdir), else: opts
      opts = Keyword.put(opts, :timeout, timeout * 1_000)

      Docker.exec_in(container, command, opts)
    end
  end
end
