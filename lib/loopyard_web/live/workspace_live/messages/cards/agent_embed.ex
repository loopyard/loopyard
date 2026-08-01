defmodule LoopyardWeb.Live.WorkspaceLive.Messages.Cards.AgentEmbed do
  @moduledoc """
  The embedded live agent "quote" card — the chat-in-chat mini-app. Split out
  of `LoopyardWeb.Live.WorkspaceLive.Messages.Cards` — see that module for
  the card family overview. Template-only; no socket/PubSub.
  """
  use Phoenix.Component

  import LoopyardWeb.Live.WorkspaceLive.Messages.Cards.Shared, only: [embed_project: 1]

  @doc """
  An embedded LIVE "quote" of ANOTHER agent's chat — the chat-in-chat mini-app.
  Reads the referenced agent's current status (ETS-backed `get_state`) and renders
  a compact card: name + status dot + what it's doing + open link. It's a curated
  slice, one level deep — never a recursive transcript — so it can't spiral.
  Reusable in any chat stream (the operator embeds the workspace agents it spawns).
  Liveness comes from the host LiveView subscribing to the referenced agent's
  status topic and re-rendering (see WorkspaceLive).
  """
  def agent_embed(assigns) do
    st = embed_state(assigns.msg[:agent_id])

    # Show the canonical project · workspace identity, not a bare "main". The msg
    # carries project_id + label(=workspace name); resolve the project name. If it
    # can't be resolved, fall back to the workspace name alone (no fake project).
    {proj, ws} =
      case embed_project(assigns.msg) do
        nil -> {assigns.msg[:label] || "workspace", nil}
        name -> {name, assigns.msg[:label]}
      end

    assigns = assign(assigns, st: st, recent: embed_recent(st), proj: proj, ws: ws)

    ~H"""
    <div class="py-3">
      <div class=" border border-zinc-200 dark:border-zinc-700/70 bg-zinc-50/70 dark:bg-zinc-800/40 shadow-sm shadow-black/5 overflow-hidden">
        <%!-- Header: who + live status + drill-in --%>
        <.link
          navigate={embed_link(@msg)}
          class="group flex items-center gap-2 px-3.5 py-2.5 min-h-11 md:min-h-0 hover:bg-zinc-100/60 dark:hover:bg-zinc-800/50 transition-colors"
        >
          <LoopyardWeb.Components.Common.workspace_identity
            project={@proj}
            workspace={@ws}
            state={embed_identity_state(@st)}
            class="min-w-0"
          />
          <span class="text-meta text-zinc-500 dark:text-zinc-400 flex-none">· {embed_word(@st)}</span>
          <span class="text-meta ml-auto flex-none inline-flex items-center gap-1 rounded-sm px-2 py-0.5 font-medium text-violet-600 dark:text-violet-400 group-hover:bg-violet-500/10 transition-colors">
            open →
          </span>
        </.link>

        <%!-- Live window: the sub-agent's recent turns, ONE level deep (never a
    recursive transcript). Updates as the host LV re-renders on the
    agent's events — so you watch it work, incl. work you drove directly. --%>
        <div
          :if={@recent != []}
          class="border-t border-zinc-100 dark:border-zinc-800 px-3 py-2 space-y-1.5 max-h-72 overflow-y-auto"
        >
          <div :for={line <- @recent}>
            <div
              :if={line.kind == :text}
              class="markdown-body text-body text-zinc-700 dark:text-zinc-200 line-clamp-4"
            >
              {Loopyard.Markdown.to_html(line.text)}
            </div>
            <div
              :if={line.kind == :tool}
              class="font-mono text-meta text-zinc-500 dark:text-zinc-400 truncate"
            >
              ⚙ {line.tool}
            </div>
          </div>
          <%!-- What it's doing right NOW (mid-turn), when known --%>
          <div
            :if={embed_detail(@st) && @st[:status] == :thinking}
            class="font-mono text-meta text-violet-500 dark:text-violet-400 truncate"
          >
            {embed_detail(@st)}
          </div>
        </div>
        <div
          :if={@recent == [] && embed_detail(@st)}
          class="border-t border-zinc-100 dark:border-zinc-800 px-3 py-2 text-meta text-zinc-500 dark:text-zinc-400 truncate"
        >
          {embed_detail(@st)}
        </div>
      </div>
    </div>
    """
  end

  defp embed_state(id) when is_binary(id) do
    Loopyard.ChatAgent.get_state(id)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp embed_state(_), do: nil

  # The sub-agent's last few OUTPUT messages (its work) — assistant text + tool
  # calls, oldest→newest. Skips user/system so the embed shows what the agent is
  # DOING, one level deep. Capped so it never becomes a recursive transcript.
  defp embed_recent(%{messages: msgs}) when is_list(msgs) do
    msgs
    |> Enum.reverse()
    |> Enum.reduce_while([], fn m, acc ->
      cond do
        length(acc) >= 4 ->
          {:halt, acc}

        m[:role] == :assistant and String.trim(to_string(m[:content])) != "" ->
          {:cont, [%{kind: :text, text: to_string(m[:content])} | acc]}

        m[:role] == :tool and is_binary(m[:tool]) ->
          {:cont, [%{kind: :tool, tool: m[:tool]} | acc]}

        true ->
          {:cont, acc}
      end
    end)
  end

  defp embed_recent(_), do: []

  # Map the sub-agent's status onto the canonical workspace_identity light.
  defp embed_identity_state(%{status: :thinking}), do: :working
  defp embed_identity_state(%{status: :idle}), do: :done
  defp embed_identity_state(%{status: :crashed}), do: :broken
  defp embed_identity_state(_), do: :asleep

  defp embed_word(%{status: :thinking}), do: "working"
  defp embed_word(%{status: :idle}), do: "ready"
  defp embed_word(%{status: s}) when is_atom(s) and not is_nil(s), do: to_string(s)
  defp embed_word(_), do: "starting…"

  defp embed_detail(%{active_tool: t}) when is_binary(t) and t != "", do: "running #{t}"
  defp embed_detail(%{status: :idle}), do: "set up — open to see what it built"
  defp embed_detail(_), do: nil

  defp embed_link(msg) do
    base = "/projects/#{msg[:project_id]}/workspaces/#{msg[:workspace_id]}"
    if msg[:agent_id], do: "#{base}/agents/#{msg[:agent_id]}", else: base
  end
end
