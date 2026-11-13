defmodule Loopyard.Tools.ControlPlane.Overview do
  @moduledoc """
  The operator's one-call status read: every project → its workspaces → each
  workspace's agents + status + open ports, in a compact tree. This is the
  operator's FIRST move for "what's here / what's running / what ports are open"
  — one cheap ETS read, terse output, no approval. For a single workspace's
  detail or its chat, follow up with `peek_workspace`.
  """
  use Loopyard.Tool,
    name: "overview",
    description:
      "The whole Loopyard picture in ONE compact read: every project, its " <>
        "workspaces, each workspace's agents (id, live status, harness · model, " <>
        "and the ACCOUNT each one bills), its open ports, and which accounts can " <>
        "run which harness. " <>
        "Read-only, no approval — your first call to answer 'what projects/" <>
        "workspaces exist, what's running, what ports are open'. For one " <>
        "workspace's details or chat, use peek_workspace.",
    busy_words: ["taking stock"],
    params: [
      agent_id: {:string, required: true}
    ]

  alias Loopyard.Harness.Catalog

  def execute(_params, _assigns) do
    {:ok, format(Loopyard.WorkspaceTree.global()) <> accounts()}
  rescue
    e -> {:error, "Couldn't build the overview: #{inspect(e)}"}
  end

  defp format([]), do: "No projects yet. Use manage_project to create one."
  defp format(tree), do: Enum.map_join(tree, "\n\n", &project/1)

  defp project(p) do
    body =
      case p.workspaces do
        [] -> "  (no workspaces)"
        wss -> Enum.map_join(wss, "\n", &workspace/1)
      end

    "▸ #{p.name}#{location(p)}\n#{body}"
  end

  defp workspace(ws) do
    agents =
      case ws.agents do
        [] -> "no agents"
        as -> Enum.map_join(as, ", ", &agent/1)
      end

    "  - #{ws.name} [#{ws.id}]: #{agents}#{ports(ws.id)}#{flags(ws)}"
  end

  # Each agent by the handle every other tool takes (its id), with what the
  # chief of staff needs to keep it moving: state, what it runs on, who pays.
  defp agent(node) do
    a = summary(node.id) || %{}
    status = a[:status] || node[:status]

    facts =
      [
        status,
        a[:auth_error] && "sign-in expired",
        # Restored mid-turn and not woken since (AgentLog.at_rest/1).
        a[:interrupted?] == true && "interrupted: its last turn never finished",
        "#{Catalog.label(a[:harness])} #{a[:model] || "default"}",
        a[:subagent_model] && "sub-agents #{a[:subagent_model]}",
        a[:workstation_identity] && "account #{a[:workstation_identity]}"
      ]
      |> Enum.filter(& &1)
      |> Enum.join(" · ")

    "#{node.name} [#{node.id}] (#{facts})"
  end

  defp summary(id) do
    case :ets.lookup(:chat_agents, id) do
      [{_, %{} = s}] -> s
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Which accounts exist and what each can sign in to — the options for
  # `agent action=switch account=…`.
  defp accounts do
    case Loopyard.Workstation.accounts() do
      [] ->
        ""

      list ->
        default = Loopyard.Workstation.current()

        "\n\nAccounts: " <>
          Enum.map_join(list, "; ", fn %{id: id, harnesses: hs} ->
            can =
              case hs do
                [] -> "no harness credential"
                _ -> Enum.map_join(hs, ", ", &Catalog.label/1)
              end

            "#{id}#{if id == default, do: " (default)"} — #{can}"
          end)
    end
  rescue
    _ -> ""
  end

  # Ports come straight from the registry (WorkspaceTree only fills port URLs when
  # given a host, which we don't have here) — show the exposed host ports.
  defp ports(ws_id) do
    case exposed_ports(ws_id) do
      [] -> ""
      ps -> " · ports " <> Enum.map_join(ps, ", ", &":#{&1}")
    end
  end

  defp exposed_ports(ws_id) do
    Loopyard.PortRegistry.list_for_workspace(ws_id)
    |> Enum.filter(& &1.exposed)
    |> Enum.map(& &1.host_port)
    |> Enum.sort()
  rescue
    _ -> []
  end

  defp flags(ws) do
    [ws[:needs_you] && "needs you", ws[:broken] && "broken"]
    |> Enum.filter(& &1)
    |> case do
      [] -> ""
      fs -> " · " <> Enum.join(fs, ", ")
    end
  end

  defp location(%{path: p}) when is_binary(p) and p != "", do: " (#{p})"
  defp location(%{git_url: u}) when is_binary(u) and u != "", do: " (#{u})"
  defp location(_), do: ""
end
