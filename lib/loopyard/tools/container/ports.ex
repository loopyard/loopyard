defmodule Loopyard.Tools.Container.Ports do
  use Loopyard.Tool,
    name: "ports",
    description: "Show all listening ports in the container",
    params: [
      agent_id: {:string, required: true}
    ]

  alias Loopyard.Docker
  alias Loopyard.Tools.Container.Helpers

  def execute(%{agent_id: agent_id}, _assigns) do
    case Helpers.resolve_container(agent_id) do
      {:ok, container} ->
        Docker.exec_in(container, """
        echo "=== Listening ports ==="
        ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo "[not available]"
        """)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
