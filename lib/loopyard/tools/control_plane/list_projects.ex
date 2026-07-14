defmodule Loopyard.Tools.ControlPlane.ListProjects do
  use Loopyard.Tool,
    name: "list_projects",
    description:
      "List every project, its workspaces, and each workspace's agents + status. " <>
        "Read-only awareness — use it to know what already exists / what's running " <>
        "before you propose creating something. No approval needed (nothing changes).",
    busy_words: ["checking what's running"],
    params: [
      agent_id: {:string, required: true}
    ]

  def execute(_params, _assigns) do
    {:ok, format(Loopyard.WorkspaceTree.global())}
  rescue
    e -> {:error, "Couldn't read the project list: #{inspect(e)}"}
  end

  defp format([]), do: "No projects yet."

  defp format(tree) do
    Enum.map_join(tree, "\n\n", fn p ->
      rows =
        Enum.map_join(p.workspaces, "\n", fn ws ->
          agents =
            case ws.agents do
              [] -> "no agents"
              as -> Enum.map_join(as, ", ", &"#{&1.name} (#{&1.status})")
            end

          "  - #{ws.name}: #{agents}"
        end)

      "#{p.name} — #{length(p.workspaces)} workspace(s)\n#{rows}"
    end)
  end
end
