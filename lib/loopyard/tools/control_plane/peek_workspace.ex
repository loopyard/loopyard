defmodule Loopyard.Tools.ControlPlane.PeekWorkspace do
  @moduledoc """
  Look INTO one workspace on demand: its agent's live status + its most recent
  chat. This is the "pull the detail" half of the operator's lean-context model —
  `overview` gives headlines, `peek_workspace` fetches specifics only when the
  operator decides to dig in. Read-only; reads the durable `:chat_agents` ETS
  summary via `MessageWindow` (no GenServer call, works mid-turn or stopped).
  """
  use Loopyard.Tool,
    name: "peek_workspace",
    description:
      "Look into ONE workspace: its agent's current status + its most recent " <>
        "chat messages. Read-only, on demand — dig into a workspace after " <>
        "`overview`, or before you `dispatch` a task. `target` is a workspace " <>
        "id/name or an agent id.",
    busy_words: ["peeking in"],
    params: [
      agent_id: {:string, required: true},
      target:
        {:string,
         required: true,
         description: "Workspace id/name, or an agent id, to look into."},
      limit: {:integer, description: "How many recent messages to show (default 15, max 60)."}
    ]

  alias Loopyard.ChatAgent.MessageWindow

  @default 15
  @max 60
  @body_cap 500

  def execute(%{target: target} = params, _assigns) do
    limit = params |> Map.get(:limit) |> clamp(@default, 1, @max)

    case Loopyard.Tools.ControlPlane.resolve_agent(target) do
      {:ok, agent} ->
        {all, total} = MessageWindow.get_messages(agent.id, limit: 1_000_000)
        shown = Enum.take(all, -limit)
        {:ok, header(agent, total, length(shown)) <> body(shown)}

      {:error, msg} ->
        {:error, msg}
    end
  rescue
    e -> {:error, "Couldn't peek into '#{target}': #{inspect(e)}"}
  end

  defp header(agent, total, showing) do
    ws = agent[:workspace_id] || "—"

    "#{agent.name} [#{agent.id}] · status: #{agent[:status]} · workspace: #{ws}\n" <>
      "#{total} message(s) total; most recent #{showing}, oldest first:\n\n"
  end

  defp body([]), do: "(no messages yet)"
  defp body(msgs), do: Enum.map_join(msgs, "\n\n", &render_one/1)

  defp render_one(m) do
    who =
      case m[:role] do
        :user -> "User"
        :assistant -> "Agent"
        :tool -> "Tool" <> if(m[:tool], do: "(#{m[:tool]})", else: "")
        :error -> "Error"
        _ -> "System"
      end

    "#{who}: #{cap(m[:content])}"
  end

  defp cap(content) do
    text = to_string(content)

    if byte_size(text) > @body_cap,
      do: String.slice(text, 0, @body_cap) <> "… [truncated]",
      else: text
  end

  defp clamp(n, _default, lo, hi) when is_integer(n), do: n |> max(lo) |> min(hi)
  defp clamp(_, default, _lo, _hi), do: default
end
