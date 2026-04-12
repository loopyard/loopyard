defmodule BoomLooper.Tools.Container.Ports do
  use BoomLooper.Tool,
    name: "ports",
    description: "Show all listening ports in the container",
    params: [
      agent_id: {:string, required: true}
    ]

  alias BoomLooper.Docker
  alias BoomLooper.Tools.Container.Helpers

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
