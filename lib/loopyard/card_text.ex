defmodule Loopyard.CardText do
  @moduledoc """
  Renders any chat message — including the interactive CARDS (question /
  approval / secret), which have no `:content` — as clean, paste-ready
  MARKDOWN. The sharing surfaces (raw permalink text, copy buttons) build on
  this so a shared link always yields copyable text, not an empty string.
  """

  @spec render(map()) :: String.t()
  def render(%{role: :question} = msg) do
    header = "### Question#{src(msg)}\n"

    body =
      Enum.map_join(msg[:questions] || [], "\n\n", fn q ->
        opts =
          Enum.map_join(q[:options] || [], "\n", fn o ->
            mark = if chosen?(msg, q, o.label), do: "[x]", else: "[ ]"
            desc = if o[:description] in [nil, ""], do: "", else: " — #{o.description}"
            "- #{mark} **#{o.label}**#{desc}"
          end)

        answer =
          case Map.get(msg[:selections] || %{}, q.id, []) do
            [] -> if q.id in (msg[:done] || []), do: "\n\n_Skipped._", else: ""
            picked -> "\n\n**Answer:** #{Enum.join(picked, ", ")}"
          end

        eyebrow = if q[:header] in [nil, ""], do: "", else: "**#{q.header}** — "
        "#{eyebrow}#{q.prompt}\n\n#{opts}#{answer}"
      end)

    header <> "\n" <> body <> status_line(msg)
  end

  def render(%{role: :approval, action: action} = msg) do
    "### Proposal#{src(msg)}\n\n" <>
      "**#{action_line(action)}**#{reason(action)}" <> status_line(msg)
  end

  def render(%{role: :secret_request} = msg) do
    "### Secret request\n\n`#{msg[:name]}`#{why(msg)}" <> status_line(msg)
  end

  def render(%{role: :embed} = msg) do
    "▸ Embedded workspace: **#{msg[:label] || "workspace"}** — " <>
      "/projects/#{msg[:project_id]}/workspaces/#{msg[:workspace_id]}/agents/#{msg[:agent_id]}"
  end

  def render(%{content: content}) when is_binary(content), do: content
  def render(_), do: ""

  defp src(%{source: s}) when is_binary(s) and s != "", do: " (#{s})"
  defp src(_), do: ""

  defp reason(%{reason: r}) when is_binary(r) and r != "", do: "\n\n#{r}"
  defp reason(_), do: ""

  defp why(%{why: w}) when is_binary(w) and w != "", do: " — #{w}"
  defp why(_), do: ""

  defp status_line(%{status: :pending}), do: "\n\n_Status: awaiting an answer._"
  defp status_line(%{status: s}) when is_atom(s) and not is_nil(s), do: "\n\n_Status: #{s}._"
  defp status_line(_), do: ""

  defp action_line(%{verb: :integrate, branch: b}), do: "Merge `#{b}` → `main`"
  defp action_line(%{verb: :delete_workspace, branch: b}), do: "Delete workspace `#{b}`"

  defp action_line(%{verb: :delete_project} = a),
    do: "Delete project `#{a[:name] || a[:project_id]}`"

  defp action_line(%{verb: :create_project, name: n}), do: "Create project `#{n}`"

  defp action_line(%{verb: :peer_workspaces} = a),
    do: "Peer `#{a[:workspace_name]}` ↔ `#{a[:peer_workspace_name]}` (direct agent messaging)"

  defp action_line(%{verb: v} = a) when v in [:rename_workspace, :rename_project],
    do: "Rename `#{a[:old_name]}` → `#{a[:name]}`"

  defp action_line(%{verb: :fork} = a), do: "Fork `#{a[:base]}` → new branch `#{a[:branch]}`"
  defp action_line(a), do: inspect(a[:verb] || :proposal)

  defp chosen?(%{selections: sel}, q, label) when is_map(sel),
    do: label in Map.get(sel, q.id, [])

  defp chosen?(_, _, _), do: false
end
