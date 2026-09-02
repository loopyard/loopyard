defmodule LoopyardWeb.ReviewLive.Deck do
  @moduledoc """
  Building the decisions deck — the pure half of `LoopyardWeb.ReviewLive`.

  One slide per DECISION: each pending question of a multi-question ask is its
  own slide; an approval or secret is one slide. Slides carry everything the
  render needs except the live message (fetched fresh per render). Newest
  first. No sockets, no PubSub — reads registries and the attention line.
  """

  alias Loopyard.ChatAgent

  @typedoc "A slide: one decision's identity + provenance. Key is `{agent_id, msg_id, q_id}`."
  @type slide :: %{
          key: {String.t(), String.t(), term()},
          agent_id: String.t(),
          msg_id: String.t(),
          q_id: term(),
          kind: atom() | nil,
          workspace_id: String.t() | nil,
          project_name: String.t() | nil,
          workspace_name: String.t() | nil,
          agent_name: String.t() | nil,
          path: String.t() | nil,
          asked_at: DateTime.t() | nil
        }

  @doc """
  Every pending decision, newest first — recency is the right bias for a
  decision queue: the one asked a minute ago is almost always the one to answer
  next, and a three-week-old ask is almost never it. `scope` limits to one
  workspace.
  """
  @spec pending(String.t() | nil) :: [slide()]
  def pending(scope) do
    Loopyard.Attention.line()
    |> Enum.filter(&(is_nil(scope) or &1.workspace_id == scope))
    |> Enum.flat_map(&item_slides/1)
    |> Enum.sort_by(&(&1.asked_at || DateTime.from_unix!(0)), {:desc, DateTime})
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc """
  PAST decisions: every question/approval/secret ever asked (recent tail per
  agent), any status, newest first — one slide per CARD.
  """
  @spec history() :: [slide()]
  def history do
    ws_names =
      for p <- Loopyard.ProjectRegistry.list_projects(),
          ws <- Loopyard.WorkspaceRegistry.list_workspaces(p.id),
          into: %{} do
        {ws.id, %{project_name: p.name, workspace_name: ws.name, project_id: p.id}}
      end

    for %{id: aid} = st <- ChatAgent.list_agent_summaries(),
        not String.contains?(to_string(st[:name] || ""), "test"),
        msg <- st |> Map.get(:messages, []) |> Enum.take(-200),
        msg[:role] in [:question, :approval, :secret_request] do
      ws = Map.get(ws_names, st[:workspace_id], %{})

      item = %{
        kind: history_kind(msg.role),
        agent_id: aid,
        msg: msg,
        workspace_id: st[:workspace_id],
        project_name: ws[:project_name],
        workspace_name: ws[:workspace_name],
        agent_name: st[:name] || "Agent",
        path: history_path(ws, st),
        asked_at: msg[:timestamp] || DateTime.from_unix!(0)
      }

      slide(item, nil)
    end
    |> Enum.sort_by(& &1.asked_at, {:desc, DateTime})
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc """
  Everything already on screen, in the order it was already in, plus whatever
  is new — new ones go FIRST (newest first), which is the start of the deck,
  never the middle of it. The deck is STICKY: a decision that settles STAYS,
  rendered as its own receipt; dropping a slide the instant it resolved would
  shift every slide after it under the reader's thumb.
  """
  @spec merge([slide()], [slide()]) :: [slide()]
  def merge(shown, fresh) do
    seen = MapSet.new(shown, & &1.key)
    Enum.reject(fresh, &MapSet.member?(seen, &1.key)) ++ shown
  end

  @doc "The DOM id stem for a slide: agent · message · question."
  @spec dom_id(slide()) :: String.t()
  def dom_id(%{agent_id: aid, msg_id: mid, q_id: q_id}),
    do: Enum.join([aid, mid, q_id || "all"], "-")

  @doc """
  The title: who's asking. The operator by name; a workspace agent with its
  project · workspace, since that's what tells the decisions apart.
  """
  @spec who_asked(slide()) :: String.t()
  def who_asked(%{agent_name: name, project_name: project, workspace_name: ws})
      when is_binary(project) and project != "" and project != name do
    Enum.join(Enum.reject([name || "Agent", project, ws], &(&1 in [nil, ""])), " · ")
  end

  def who_asked(%{agent_name: name}) when is_binary(name) and name != "", do: name
  def who_asked(_), do: "Operator"

  @doc "Relative age for the bar: \"moments ago\", \"3h ago\", \"21d ago\"."
  @spec ago(DateTime.t() | term()) :: String.t() | nil
  def ago(%DateTime{} = at) do
    secs = DateTime.diff(DateTime.utc_now(), at)

    cond do
      secs < 60 -> "moments ago"
      secs < 3600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3600)}h ago"
      true -> "#{div(secs, 86_400)}d ago"
    end
  end

  def ago(_), do: nil

  defp history_kind(:question), do: :question
  defp history_kind(:secret_request), do: :secret
  defp history_kind(:approval), do: :approval

  defp history_path(%{project_id: pid}, st) when is_binary(pid),
    do: "/projects/#{pid}/workspaces/#{st[:workspace_id]}/agents/#{st[:id]}"

  defp history_path(_ws, _st), do: "/operator"

  defp item_slides(%{kind: :question, msg: %{} = msg} = item) do
    for q <- msg[:questions] || [], q.id not in (msg[:done] || []) do
      slide(item, q.id)
    end
  end

  defp item_slides(%{msg: %{}} = item), do: [slide(item, nil)]
  defp item_slides(_), do: []

  defp slide(item, q_id) do
    %{
      key: {item.agent_id, item.msg.id, q_id},
      agent_id: item.agent_id,
      msg_id: item.msg.id,
      q_id: q_id,
      kind: item.kind,
      workspace_id: item.workspace_id,
      project_name: item.project_name,
      workspace_name: item.workspace_name,
      agent_name: item.agent_name,
      path: item.path,
      asked_at: item.asked_at
    }
  end
end
