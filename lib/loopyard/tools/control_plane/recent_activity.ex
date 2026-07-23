defmodule Loopyard.Tools.ControlPlane.RecentActivity do
  @moduledoc """
  The operator's "what happened while I wasn't looking" feed — reads the compact
  completion digest (`Loopyard.Operator.Digest`) newest-first. This is the pull
  half of the operator's notification model: completions accumulate out of
  context, the operator reads headlines here, and pulls the actual work with
  `peek_workspace` only when it decides to dig in.
  """
  use Loopyard.Tool,
    name: "recent_activity",
    description:
      "What just finished across your workspaces — a compact, newest-first list " <>
        "of recently completed turns. Your 'what happened while I wasn't looking' " <>
        "feed. Read-only. To see WHAT a workspace actually did, follow up with " <>
        "peek_workspace.",
    busy_words: ["catching up"],
    params: [
      agent_id: {:string, required: true},
      limit: {:integer, description: "How many recent completions (default 20, max 50)."}
    ]

  @default 20
  @max 50

  def execute(params, _assigns) do
    limit = params |> Map.get(:limit) |> clamp(@default, 1, @max)

    case Loopyard.Operator.Digest.recent(limit) do
      [] -> {:ok, "Nothing has finished recently."}
      entries -> {:ok, "Recently finished (newest first):\n" <> Enum.map_join(entries, "\n", &line/1)}
    end
  rescue
    e -> {:error, "Couldn't read recent activity: #{inspect(e)}"}
  end

  defp line(e) do
    who = e[:agent_name] || e[:agent_id]
    ws = e[:workspace_id] || "—"
    "  - #{who} (#{ws}) #{e[:summary]}#{ago(e[:at])}"
  end

  defp ago(%DateTime{} = at) do
    secs = DateTime.diff(DateTime.utc_now(), at)

    cond do
      secs < 60 -> " · #{secs}s ago"
      secs < 3600 -> " · #{div(secs, 60)}m ago"
      true -> " · #{div(secs, 3600)}h ago"
    end
  rescue
    _ -> ""
  end

  defp ago(_), do: ""

  defp clamp(n, _default, lo, hi) when is_integer(n), do: n |> max(lo) |> min(hi)
  defp clamp(_, default, _lo, _hi), do: default
end
