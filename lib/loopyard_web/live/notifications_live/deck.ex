defmodule LoopyardWeb.NotificationsLive.Deck do
  @moduledoc """
  Building the deck — the pure half of `LoopyardWeb.NotificationsLive`.

  One slide per ITEM of the inbox (`Loopyard.Notifications`), in inbox order:
  each pending question of a multi-question ask is its own slide; an
  approval, a secret, or a finished turn is one slide. Slides carry
  everything the render needs except the live message (fetched fresh per
  render). No sockets, no PubSub.
  """

  alias Loopyard.ChatAgent
  alias Loopyard.Notifications
  alias Loopyard.Notifications.Item

  @typedoc "A slide: one item's identity + provenance. Key is `{agent_id, msg_id, q_id}`."
  @type slide :: %{
          key: {String.t(), String.t(), term()},
          item_id: String.t() | nil,
          kind: atom() | nil,
          scope: :workspace | :system,
          agent_id: String.t(),
          msg_id: String.t(),
          q_id: term(),
          workspace_id: String.t() | nil,
          project_name: String.t() | nil,
          workspace_name: String.t() | nil,
          agent_name: String.t() | nil,
          path: String.t() | nil,
          asked_at: DateTime.t() | nil
        }

  # A finished item has no card; its slide's msg_id is this marker so the
  # permalink shape (`/notifications/:agent/:msg`) still names it.
  @finished_msg_id "fin"

  @doc "The msg_id a finished-turn slide carries."
  def finished_msg_id, do: @finished_msg_id

  @doc """
  Every open item, in inbox order (`Notifications.Priority`): the store's
  order IS the deck order. `scope` limits to one workspace.
  """
  @spec pending(String.t() | nil) :: [slide()]
  def pending(scope) do
    Notifications.open()
    |> Enum.filter(&(is_nil(scope) or &1.workspace_id == scope))
    |> Enum.flat_map(&item_slides/1)
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

      %{
        key: {aid, msg.id, nil},
        item_id: Item.card_id(msg),
        kind: Item.kind_for_role(msg.role),
        scope: Loopyard.Agents.scope(st),
        agent_id: aid,
        msg_id: msg.id,
        q_id: nil,
        workspace_id: st[:workspace_id],
        project_name: ws[:project_name],
        workspace_name: ws[:workspace_name],
        agent_name: st[:name] || "Agent",
        path: history_path(ws, st),
        asked_at: msg[:timestamp] || DateTime.from_unix!(0)
      }
    end
    |> Enum.sort_by(& &1.asked_at, {:desc, DateTime})
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc """
  Everything already on screen, in the order it was already in, plus whatever
  is new — new ones go FIRST, which is the start of the deck, never the
  middle of it. The deck is STICKY: an item that settles STAYS, rendered as
  its own receipt; dropping a slide the instant it resolved would shift every
  slide after it under the reader's thumb.
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
  def who_asked(_), do: "System"

  @doc "Is this a SYSTEM agent's item (a workspace-less agent — the operator, its peers)?"
  @spec system?(slide()) :: boolean()
  def system?(%{scope: scope}) when scope in [:workspace, :system], do: scope == :system
  def system?(%{project_name: project}) when is_binary(project) and project != "", do: false
  def system?(_), do: true

  @doc "Relative age in words for a byline: \"moments ago\", \"3 hours ago\", \"21 days ago\"."
  @spec ago_words(DateTime.t() | term()) :: String.t() | nil
  def ago_words(%DateTime{} = at) do
    secs = DateTime.diff(DateTime.utc_now(), at)

    cond do
      secs < 60 -> "moments ago"
      secs < 3600 -> plural(div(secs, 60), "minute") <> " ago"
      secs < 86_400 -> plural(div(secs, 3600), "hour") <> " ago"
      true -> plural(div(secs, 86_400), "day") <> " ago"
    end
  end

  def ago_words(_), do: nil

  defp plural(1, noun), do: "1 " <> noun
  defp plural(n, noun), do: "#{n} #{noun}s"

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

  defp history_path(%{project_id: pid}, st) when is_binary(pid),
    do: "/projects/#{pid}/workspaces/#{st[:workspace_id]}/agents/#{st[:id]}"

  defp history_path(_ws, st), do: "/agents/#{st[:id]}"

  # A multi-question ask fans out one slide per still-open question.
  defp item_slides(%Item{kind: :question, agent_id: aid, msg_id: mid} = item)
       when is_binary(mid) do
    case live_msg(aid, mid) do
      %{questions: qs} = msg when is_list(qs) and qs != [] ->
        for q <- qs, q.id not in (msg[:done] || []), do: slide(item, q.id)

      _ ->
        [slide(item, nil)]
    end
  end

  defp item_slides(%Item{} = item), do: [slide(item, nil)]

  defp slide(%Item{} = item, q_id) do
    msg_id = item.msg_id || @finished_msg_id

    %{
      key: {item.agent_id, msg_id, q_id},
      item_id: item.id,
      kind: item.kind,
      scope: item.scope || if(is_binary(item.workspace_id), do: :workspace, else: :system),
      agent_id: item.agent_id,
      msg_id: msg_id,
      q_id: q_id,
      workspace_id: item.workspace_id,
      project_name: item.project_name,
      workspace_name: item.workspace_name,
      agent_name: item.agent_name,
      path: item.path,
      asked_at: item.raised_at
    }
  end

  defp live_msg(aid, mid) do
    ChatAgent.get_message(aid, mid)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
