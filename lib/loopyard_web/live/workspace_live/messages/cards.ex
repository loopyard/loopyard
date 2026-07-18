defmodule LoopyardWeb.Live.WorkspaceLive.Messages.Cards do
  @moduledoc """
  The two interactive mini-app cards rendered inline in the chat — the
  `ask_user` **question** card and the boundary-crossing **approval** card
  (fork / integrate / delete-workspace). Extracted from
  `LoopyardWeb.Live.WorkspaceLive.Messages` to keep that file under its line
  cap; `chat_msg/1` delegates the `:question` and `:approval` roles here.

  Both are persisted + broadcast (multiplayer): the card — and its resolved
  outcome — shows for the whole room. Template-only; no socket/PubSub.
  """
  use Phoenix.Component

  @doc """
  The agent asked the user a question (via the `ask_user` tool / harness
  question machinery). An interactive decision card — options as buttons.
  Answering flips status to `:answered` for everyone.
  """
  def question_card(assigns) do
    ~H"""
    <div class="py-2">
      <div class="rounded-xl border border-violet-200 dark:border-violet-800/60 bg-violet-50/50 dark:bg-violet-900/10 p-4">
        <div class="flex items-center gap-1.5 text-sm font-medium text-violet-600 dark:text-violet-400 mb-3">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 16 16"
            fill="currentColor"
            class="w-3.5 h-3.5"
          >
            <path
              fill-rule="evenodd"
              d="M8 15A7 7 0 1 0 8 1a7 7 0 0 0 0 14Zm.93-9.412c-.44-.305-1.054-.305-1.494 0-.146.101-.27.245-.354.435a.75.75 0 0 1-1.372-.606c.18-.405.45-.74.819-.995 1.041-.722 2.486-.722 3.527 0 .54.375.94.94.94 1.626 0 .609-.314 1.07-.658 1.39-.124.115-.26.222-.387.32l-.10.078c-.179.139-.31.255-.404.385-.087.12-.12.222-.12.334a.75.75 0 0 1-1.5 0c0-.49.218-.884.47-1.226.21-.286.482-.502.679-.654l.078-.06c.139-.108.224-.18.286-.237.087-.08.108-.13.108-.27a.484.484 0 0 0-.298-.473ZM8 12a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z"
              clip-rule="evenodd"
            />
          </svg>
          The agent needs your input
        </div>

        <div :for={q <- @msg.questions} class="mb-3 last:mb-0">
          <div
            :if={q.header != ""}
            class="text-sm uppercase tracking-wide text-zinc-500 dark:text-zinc-400 mb-1"
          >
            {q.header}
          </div>
          <div class="text-[15px] font-medium leading-snug text-zinc-800 dark:text-zinc-200 mb-3">
            {q.prompt}
          </div>

          <%!-- Each option is a full-width row: the label is the primary
               affordance, the description hugs it directly below (tight
               mt-0.5) so it reads as subordinate, and a larger gap-2.5
               separates one option from the next. The whole row is the
               click target — a real tap area on phones. --%>
          <div :if={@msg.status == :pending} class="flex flex-col gap-2.5">
            <button
              :for={o <- q.options}
              type="button"
              phx-click="answer_question"
              phx-value-question_id={@msg.question_id}
              phx-value-q={q.id}
              phx-value-option={o.label}
              class="focus-ring group/opt block w-full text-left rounded-lg border border-violet-200/70 dark:border-violet-800/50 bg-white/70 dark:bg-zinc-900/40 px-3.5 py-2.5 hover:border-violet-400 hover:bg-violet-50 dark:hover:border-violet-600/80 dark:hover:bg-violet-900/20 transition-colors"
            >
              <div class="text-sm font-medium text-violet-700 dark:text-violet-300">{o.label}</div>
              <div
                :if={o.description not in [nil, ""]}
                class="mt-0.5 text-sm leading-relaxed text-zinc-500 dark:text-zinc-400"
              >
                {o.description}
              </div>
            </button>
          </div>

          <%!-- ANSWERED: keep the SAME option list (same height → no layout
               jump on click), chosen one lit emerald with a check, the rest
               dimmed. Durable visual receipt of what was picked — survives
               refresh/restart via the persisted :selections. --%>
          <div :if={@msg.status == :answered} class="flex flex-col gap-2.5">
            <div
              :for={o <- q.options}
              class={[
                "block w-full text-left rounded-lg border px-3.5 py-2.5",
                if(chosen?(@msg, q, o.label),
                  do:
                    "border-emerald-400/70 dark:border-emerald-600/60 bg-emerald-50/70 dark:bg-emerald-900/15",
                  else:
                    "border-zinc-200/60 dark:border-zinc-800/60 bg-white/40 dark:bg-zinc-900/20 opacity-50"
                )
              ]}
            >
              <div class={[
                "flex items-center gap-1.5 text-sm font-medium",
                if(chosen?(@msg, q, o.label),
                  do: "text-emerald-700 dark:text-emerald-300",
                  else: "text-zinc-500 dark:text-zinc-400"
                )
              ]}>
                <span :if={chosen?(@msg, q, o.label)} aria-hidden="true">✓</span>
                {o.label}
              </div>
              <div
                :if={o.description not in [nil, ""]}
                class="mt-0.5 text-sm leading-relaxed text-zinc-500 dark:text-zinc-400"
              >
                {o.description}
              </div>
            </div>
          </div>

          <%!-- Free-text answer (typed in chat instead of clicking) — no option
               row matches, so show the text itself as the receipt. --%>
          <div
            :if={@msg.status == :answered && !any_option_chosen?(@msg, q)}
            class="mt-2 flex flex-wrap items-center gap-2 text-sm"
          >
            <span class="inline-flex items-center gap-1.5 rounded-lg bg-emerald-500/15 px-3 py-1.5 font-medium text-emerald-600 dark:text-emerald-400">
              {answer_for(@msg, q)}
            </span>
          </div>
        </div>

        <div :if={@msg.status == :timeout} class="text-sm text-zinc-500 dark:text-zinc-400">
          No answer — the agent moved on.
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The agent asked for a SECRET (api key / token) via `request_secret`. A masked
  input card: the value goes straight to the on-disk secret store and NEVER into
  the chat — every viewer sees the request and that it was submitted, never the
  value. Submitting flips the card to "Submitted" for the whole room.
  """
  def secret_card(assigns) do
    ~H"""
    <div class="py-2">
      <div class="rounded-xl border border-amber-200 dark:border-amber-800/60 bg-amber-50/50 dark:bg-amber-900/10 p-4">
        <div class="flex items-center gap-1.5 text-sm font-medium text-amber-700 dark:text-amber-400 mb-2">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 16 16"
            fill="currentColor"
            class="w-3.5 h-3.5"
          >
            <path
              fill-rule="evenodd"
              d="M8 1a3 3 0 0 0-3 3v2H4.5A1.5 1.5 0 0 0 3 7.5v5A1.5 1.5 0 0 0 4.5 14h7a1.5 1.5 0 0 0 1.5-1.5v-5A1.5 1.5 0 0 0 11.5 6H11V4a3 3 0 0 0-3-3Zm1.5 5V4a1.5 1.5 0 1 0-3 0v2h3Z"
              clip-rule="evenodd"
            />
          </svg>
          The agent needs a secret
        </div>

        <div class="text-[15px] font-medium leading-snug text-zinc-800 dark:text-zinc-200">
          <span class="font-mono">{@msg.name}</span>
        </div>
        <div :if={@msg[:why] not in [nil, ""]} class="mt-0.5 text-sm text-zinc-500 dark:text-zinc-400">
          {@msg.why}
        </div>

        <%!-- The whole room sees this field, but only the submitter's browser sends
             the value, and it goes straight to disk — never into the transcript. The
             field is named "secret", which is in `filter_parameters` so it's redacted
             from server logs too. --%>
        <div :if={@msg.status == :pending}>
          <form phx-submit="submit_secret" autocomplete="off" class="mt-3 flex items-center gap-2">
            <input type="hidden" name="request_id" value={@msg.request_id} />
            <input
              type="password"
              name="secret"
              autocomplete="off"
              spellcheck="false"
              placeholder={"Paste #{@msg.name}…"}
              aria-label={"Secret value for #{@msg.name}"}
              class="flex-1 min-w-0 rounded-lg border border-amber-300 dark:border-amber-700/60 bg-white dark:bg-zinc-900 px-3 py-2 text-sm font-mono text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 focus:outline-none focus:ring-2 focus:ring-amber-500/30"
            />
            <button
              type="submit"
              class="focus-ring flex-none rounded-lg bg-amber-600 hover:bg-amber-700 px-3.5 py-2 text-sm font-medium text-white transition-colors"
            >
              Submit
            </button>
          </form>
          <%!-- Escape hatch: you don't have it / won't provide it. Resumes the
               agent's turn so it stops waiting and moves on. --%>
          <button
            type="button"
            phx-click="cancel_secret"
            phx-value-request_id={@msg.request_id}
            class="focus-ring mt-2 text-sm text-zinc-500 dark:text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200"
          >
            I don't have it — skip
          </button>
        </div>

        <div
          :if={@msg.status == :declined}
          class="mt-3 text-sm text-zinc-500 dark:text-zinc-400"
        >
          Declined — the agent will proceed without it.
        </div>

        <div
          :if={@msg.status == :submitted}
          class="mt-3 inline-flex items-center gap-1.5 rounded-lg bg-emerald-500/15 px-3 py-1.5 text-sm font-medium text-emerald-600 dark:text-emerald-400"
        >
          <span>✓</span>
          {if @msg[:submitted_by] in [nil, ""],
            do: "Submitted — stored securely, not shown in chat.",
            else: "Submitted by #{@msg.submitted_by} — kept out of chat."}
        </div>

        <div :if={@msg.status == :timeout} class="mt-3 text-sm text-zinc-500 dark:text-zinc-400">
          No secret submitted — the agent moved on.
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The agent proposed a boundary-crossing action (fork / integrate /
  delete-workspace). An Approve/Deny card — the guardrail against an agent
  spawning or destroying workspaces unattended. Shows the resolved outcome
  (creating…, created + link, merged, denied, failed) for the whole room.
  """
  def approval_card(assigns) do
    assigns = assign(assigns, :action, assigns.msg.action)

    ~H"""
    <div class="py-2">
      <div class="rounded-xl border border-amber-200 dark:border-amber-800/60 bg-amber-50/50 dark:bg-amber-900/10 p-4">
        <div class="flex items-center gap-1.5 text-sm font-medium text-amber-700 dark:text-amber-400 mb-2">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 16 16"
            fill="currentColor"
            class="w-3.5 h-3.5"
          >
            <path d="M8 1.5a2 2 0 0 0-2 2v.5H4.5A1.5 1.5 0 0 0 3 5.5v.879a2.5 2.5 0 0 0 0 4.242V13.5A1.5 1.5 0 0 0 4.5 15h7a1.5 1.5 0 0 0 1.5-1.5v-2.879a2.5 2.5 0 0 0 0-4.242V5.5A1.5 1.5 0 0 0 11.5 4H10v-.5a2 2 0 0 0-2-2Z" />
          </svg>
          {case @action.verb do
            :integrate -> "Merge proposal — needs your OK"
            :delete_workspace -> "Delete workspace — needs your OK"
            :create_project -> "New project — needs your OK"
            _ -> "Branch proposal — needs your OK"
          end}
        </div>

        <div
          :if={@action.verb == :create_project}
          class="text-sm text-zinc-800 dark:text-zinc-200 mb-1"
        >
          Create project
          <code class="text-sm bg-violet-200/70 dark:bg-violet-800/50 rounded px-1 py-0.5">
            {@action.name}
          </code>
          <span class="text-zinc-400">— {@action.detail}</span>
        </div>
        <div :if={@action.verb == :integrate} class="text-sm text-zinc-800 dark:text-zinc-200 mb-1">
          Merge
          <code class="text-sm bg-violet-200/70 dark:bg-violet-800/50 rounded px-1 py-0.5">
            {@action.branch}
          </code>
          → <code class="text-sm bg-zinc-200/70 dark:bg-zinc-700/70 rounded px-1 py-0.5">main</code>
          <span class="text-zinc-400">(rebase + merge into the green main)</span>
        </div>
        <div
          :if={@action.verb == :delete_workspace}
          class="text-sm text-zinc-800 dark:text-zinc-200 mb-1"
        >
          Delete workspace
          <code class="text-sm bg-zinc-200/70 dark:bg-zinc-700/70 rounded px-1 py-0.5">
            {@action.branch}
          </code>
          <span class="text-zinc-400">— removes its env + containers (the code stays in main)</span>
        </div>
        <div :if={@action.verb == :fork} class="text-sm text-zinc-800 dark:text-zinc-200 mb-1">
          Fork
          <code class="text-sm bg-zinc-200/70 dark:bg-zinc-700/70 rounded px-1 py-0.5">
            {@action.base}
          </code>
          → new branch
          <code class="text-sm bg-violet-200/70 dark:bg-violet-800/50 rounded px-1 py-0.5">
            {@action.branch}
          </code>
          <span class="text-zinc-400">(its own isolated workspace)</span>
        </div>
        <div :if={@action[:reason]} class="text-sm text-zinc-500 dark:text-zinc-400 mb-3">
          {@action.reason}
        </div>
        <div :if={!@action[:reason]} class="mb-3"></div>

        <%= case @msg.status do %>
          <% :pending -> %>
            <div class="flex items-center gap-2">
              <button
                type="button"
                phx-click="decide_approval"
                phx-value-approval_id={@msg.approval_id}
                phx-value-decision="approve"
                class={[
                  "focus-ring inline-flex items-center gap-1.5 rounded-lg px-4 py-1.5 text-sm font-medium text-white transition-colors",
                  if(@action.verb == :delete_workspace,
                    do: "bg-red-600 hover:bg-red-700",
                    else: "bg-emerald-600 hover:bg-emerald-700"
                  )
                ]}
              >
                {if @action.verb == :delete_workspace, do: "Delete", else: "Approve"}
              </button>
              <button
                type="button"
                phx-click="decide_approval"
                phx-value-approval_id={@msg.approval_id}
                phx-value-decision="deny"
                class="focus-ring inline-flex items-center rounded-lg border border-zinc-300 dark:border-zinc-600 px-4 py-1.5 text-sm font-medium text-zinc-600 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors"
              >
                Deny
              </button>
            </div>
          <% s when s in [:creating, :integrating] -> %>
            <div class="flex items-center gap-2 text-sm text-zinc-500">
              <svg
                class="w-4 h-4 animate-spin flex-none"
                xmlns="http://www.w3.org/2000/svg"
                fill="none"
                viewBox="0 0 24 24"
              >
                <circle
                  class="opacity-25"
                  cx="12"
                  cy="12"
                  r="10"
                  stroke="currentColor"
                  stroke-width="4"
                >
                </circle>
                <path
                  class="opacity-75"
                  fill="currentColor"
                  d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                >
                </path>
              </svg>
              <span class="font-medium">
                {cond do
                  @msg.status == :integrating -> "Merging into main"
                  @action.verb == :create_project -> "Creating the project"
                  true -> "Creating the branch workspace"
                end}
              </span>
              <span :if={@msg[:detail]} class="text-zinc-400 animate-pulse truncate">
                · {@msg.detail}
              </span>
            </div>
          <% :approved -> %>
            <.link
              navigate={approved_link(@msg)}
              class="focus-ring inline-flex items-center gap-1.5 rounded-lg bg-emerald-500/15 px-3 py-1.5 text-sm font-medium text-emerald-600 dark:text-emerald-400 hover:bg-emerald-500/25 transition-colors"
            >
              Ready — open <code class="text-sm">{@action[:name] || @action[:branch]}</code> →
            </.link>
          <% :integrated -> %>
            <span class="inline-flex items-center gap-1.5 rounded-lg bg-emerald-500/15 px-3 py-1.5 text-sm font-medium text-emerald-600 dark:text-emerald-400">
              Merged <code class="text-sm">{@action.branch}</code> → main ✓
            </span>
          <% :denied -> %>
            <span class="text-sm text-zinc-500 dark:text-zinc-400">Declined.</span>
          <% :failed -> %>
            <span class="text-sm text-red-500">
              {case @action.verb do
                :integrate -> "Merge failed"
                :create_project -> "Couldn't create the project"
                _ -> "Couldn't create the branch"
              end}: {@msg[:error]}
            </span>
          <% _ -> %>
            <span></span>
        <% end %>
      </div>
    </div>
    """
  end

  # Where "Open" lands after a fork is approved: straight on the branch's agent
  # when it was provisioned (it always is now), else the workspace.
  defp approved_link(msg) do
    base = "/projects/#{msg[:project_id]}/workspaces/#{msg[:workspace_id]}"
    if msg[:agent_id], do: "#{base}/agents/#{msg[:agent_id]}", else: base
  end

  # The human's chosen answer for a question, once answered.
  defp answer_for(%{selections: sel}, q) when is_map(sel) do
    case Map.get(sel, q.id, []) do
      [] -> "✓ answered"
      chosen -> Enum.join(chosen, ", ")
    end
  end

  defp answer_for(_msg, _q), do: "✓ answered"

  # Was this option's label among the persisted selections for question q?
  defp chosen?(%{selections: sel}, q, label) when is_map(sel),
    do: label in Map.get(sel, q.id, [])

  defp chosen?(_msg, _q, _label), do: false

  # Did ANY listed option match the selections? False for free-text answers
  # (typed in chat), which need the text chip fallback instead.
  defp any_option_chosen?(msg, q),
    do: Enum.any?(q.options, &chosen?(msg, q, &1.label))

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
    assigns = assign(assigns, :st, embed_state(assigns.msg[:agent_id]))

    ~H"""
    <div class="py-2">
      <.link
        navigate={embed_link(@msg)}
        class="group block rounded-xl border border-zinc-200 dark:border-zinc-700 bg-zinc-50/60 dark:bg-zinc-800/30 p-3 hover:border-violet-300 dark:hover:border-violet-500/40 transition-colors"
      >
        <div class="flex items-center gap-2">
          <span class={["w-2 h-2 rounded-full flex-none", embed_dot(@st)]}></span>
          <span class="text-sm font-semibold text-zinc-800 dark:text-zinc-100 truncate">
            {@msg[:label] || "workspace"}
          </span>
          <span class="text-xs text-zinc-500 dark:text-zinc-400 flex-none">· {embed_word(@st)}</span>
          <span class="ml-auto text-xs text-violet-500 group-hover:text-violet-600 flex-none">
            open →
          </span>
        </div>
        <div :if={embed_detail(@st)} class="mt-1 text-xs text-zinc-500 dark:text-zinc-400 truncate">
          {embed_detail(@st)}
        </div>
      </.link>
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

  defp embed_dot(%{status: :thinking}), do: "bg-violet-500 animate-pulse"
  defp embed_dot(%{status: :idle}), do: "bg-emerald-500"
  defp embed_dot(%{status: s}) when s in [:crashed, :stopped], do: "bg-zinc-400"
  defp embed_dot(_), do: "bg-zinc-300 dark:bg-zinc-600"

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
