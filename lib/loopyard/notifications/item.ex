defmodule Loopyard.Notifications.Item do
  @moduledoc """
  One notification: something waiting on a human, or something that happened.

  * `kind` — `:question | :approval | :secret` (a DECISION: an agent is blocked
    on a person) or `:finished` (an agent wrapped a turn — "keep going?").
  * `status` — `:open` until settled; then `:settled` (acted on — answered,
    approved, submitted, kept going), `:dismissed` (a human waved it away), or
    `:retracted` (an agent withdrew it as moot). `outcome` keeps the detail
    (the card's final status, or who dismissed).
  * `id` — for a decision, the broker id the card carries (`question_id` /
    `approval_id` / `request_id`), so every existing caller that keyed on the
    attention line's `id` still matches; for a finished item, `"fin:" <> agent`.
  * The WHERE is denormalised at raise time (agent name, workspace and project
    names, the path to act) so a reader never scans registries or agent
    summaries — that scan on every render is what this store replaces.
  """

  alias Loopyard.{ProjectRegistry, WorkspaceRegistry}

  @type kind :: :question | :approval | :secret | :finished
  @type status :: :open | :settled | :dismissed | :retracted

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          status: status(),
          outcome: term(),
          agent_id: String.t(),
          agent_name: String.t(),
          workspace_id: String.t() | nil,
          workspace_name: String.t() | nil,
          project_id: String.t() | nil,
          project_name: String.t() | nil,
          path: String.t(),
          msg_id: String.t() | nil,
          label: String.t(),
          raised_at: DateTime.t(),
          settled_at: DateTime.t() | nil,
          priority: :pinned | :demoted | nil,
          meta: map()
        }

  defstruct [
    :id,
    :kind,
    :agent_id,
    :agent_name,
    :workspace_id,
    :workspace_name,
    :project_id,
    :project_name,
    :path,
    :msg_id,
    :label,
    :raised_at,
    :settled_at,
    :outcome,
    :priority,
    :scope,
    status: :open,
    meta: %{}
  ]

  @card_roles %{question: :question, approval: :approval, secret_request: :secret}

  @doc "The notification kind a card role maps to, or nil for a non-card role."
  @spec kind_for_role(term()) :: kind() | nil
  def kind_for_role(role), do: Map.get(@card_roles, role)

  @doc "Every decision kind — the subset that blocks an agent on a human."
  def decision_kinds, do: [:question, :approval, :secret]

  @doc """
  Build the item for a freshly appended card. Reads the agent's ETS summary for
  its name and workspace (never a GenServer call — this runs on the append
  path), and the registries for the names to show.
  """
  @spec from_card(String.t(), map()) :: t() | nil
  def from_card(agent_id, %{} = msg) when is_binary(agent_id) do
    case kind_for_role(msg[:role]) do
      nil ->
        nil

      kind ->
        summary = agent_summary(agent_id)
        ws_id = summary[:workspace_id]
        {ws_name, project_id, project_name} = where(ws_id)

        %__MODULE__{
          id: card_id(msg),
          kind: kind,
          agent_id: agent_id,
          agent_name: summary[:name] || "Agent",
          workspace_id: ws_id,
          workspace_name: ws_name,
          project_id: project_id,
          project_name: project_name,
          path: path(ws_id, project_id, agent_id),
          msg_id: msg[:id],
          label: label(kind, msg),
          raised_at: raised_at(msg),
          scope: Loopyard.Agents.scope(summary),
          status: :open
        }
    end
  end

  def from_card(_, _), do: nil

  @doc "The broker id a card carries, falling back to the message id."
  def card_id(msg),
    do: msg[:question_id] || msg[:approval_id] || msg[:request_id] || msg[:id]

  @doc "Where answering this item lives: the agent's chat, or the operator."
  def path(ws_id, project_id, agent_id) when is_binary(ws_id) and is_binary(project_id),
    do: "/projects/#{project_id}/workspaces/#{ws_id}/agents/#{agent_id}"

  # A workspace-less agent — a SYSTEM agent — has its own page. This used to
  # be "/operator": every system agent pointed at one page.
  def path(_ws_id, _project_id, agent_id) when is_binary(agent_id), do: "/agents/#{agent_id}"
  def path(_ws_id, _project_id, _agent_id), do: "/agents"

  defp label(:question, msg) do
    case msg[:questions] do
      [%{prompt: p} | rest] when is_binary(p) and p != "" ->
        if rest == [], do: p, else: "#{p} (+#{length(rest)} more)"

      _ ->
        "A question"
    end
  end

  defp label(:secret, msg), do: "Secret: #{msg[:name] || "value"}"

  defp label(:approval, %{action: %{verb: verb}}), do: "Approval: #{verb}"
  defp label(:approval, _msg), do: "Approval requested"

  defp raised_at(%{timestamp: %DateTime{} = t}), do: t
  defp raised_at(_), do: DateTime.utc_now()

  defp agent_summary(agent_id) do
    case :ets.lookup(:chat_agents, agent_id) do
      [{^agent_id, summary}] -> summary
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp where(nil), do: {nil, nil, nil}

  defp where(ws_id) do
    case WorkspaceRegistry.get_workspace(ws_id) do
      %{} = ws ->
        project = ws[:project_id] && ProjectRegistry.get_project(ws[:project_id])
        {ws[:name], ws[:project_id], project && project[:name]}

      _ ->
        {nil, nil, nil}
    end
  rescue
    _ -> {nil, nil, nil}
  catch
    _, _ -> {nil, nil, nil}
  end
end
