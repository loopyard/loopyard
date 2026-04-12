defmodule BoomLooper.Tools.Container.Ports do
  @moduledoc false

  alias BoomLooper.Docker
  alias BoomLooper.Tools.Container.Helpers

  def __tool_name__, do: "ports"
  def __description__, do: "Show all listening ports in the container"

  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "agent_id" => %{"type" => "string"}
      },
      "required" => ["agent_id"]
    }
  end

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
