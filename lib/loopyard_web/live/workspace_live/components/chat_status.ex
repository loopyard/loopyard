defmodule LoopyardWeb.Live.WorkspaceLive.Components.ChatStatus do
  @moduledoc """
  The agent's live-status presentation: the in-progress tool feed
  (`thinking_indicator`), the un-boxed live tail (`live_status`), the
  docked Reasoning Bar (`reasoning_bar`), and the helpers that compute
  the current turn's activity.

  Split out of `LoopyardWeb.Live.WorkspaceLive.Components.Chat` to keep
  that module under its size cap. `Chat` re-exposes the public component
  functions via `defdelegate`, so its templates and the tests that call
  `Chat.thinking_indicator/1` etc. are unchanged.
  """
  use Phoenix.Component

  def thinking_indicator(assigns) do
    # Live activity feed: every tool action since the last human turn, in
    # order, the most recent one still running (⟳) and the rest done (✓).
    # These are the SAME tool messages the chat would render inline — while
    # the agent is working we surface them here as a pinned, rolling feed
    # instead (chat_panel suppresses the inline rows for the active turn),
    # so you can watch it work without the list scrolling away.
    activity = current_turn_activity(assigns.messages)

    assigns =
      assigns
      |> assign(:activity, activity)
      |> assign(:turn_since, turn_started_unix_ms(assigns.messages))
      |> assign(:stall_hint, retry_hint(assigns.messages))

    # No bubble, no avatar — the live work flows on the transcript spine like
    # everything else the agent does, just bigger: this IS "the computer
    # thinking", so give it room. The chat_panel wraps it in the run-spine.
    ~H"""
    <%!-- Live tool feed only. The status header (word + elapsed + Stop) is
         docked at the bottom in the Reasoning Bar so it never scrolls off the
         top, no matter how long the work runs. --%>
    <div :if={@activity != [] || @stall_hint} class="py-1.5">
      <ul :if={@activity != []} class="space-y-1.5">
        <li :for={a <- @activity} class="flex items-start gap-2 text-sm leading-relaxed">
          <span class={[
            "flex-none w-3.5 text-center mt-0.5",
            a.active && "text-violet-500 animate-pulse",
            !a.active && "text-emerald-500/70"
          ]}>
            {if a.active, do: "▸", else: "✓"}
          </span>
          <span class={[
            "min-w-0 break-words font-mono",
            a.active && "text-zinc-700 dark:text-zinc-200",
            !a.active && "text-zinc-500 dark:text-zinc-400"
          ]}>
            {a.summary}
          </span>
        </li>
      </ul>
      <%!-- A retry is NOT an error — it's a calm status subtext under the live
           spinner ("busy, not wedged"). Muted, no ⚠, no "press Stop" burden: the
           system is handling it, and a real failure surfaces its own error. --%>
      <p
        :if={@stall_hint}
        class="mt-2.5 flex items-start gap-2 text-sm leading-relaxed text-zinc-500 dark:text-zinc-400"
      >
        <span class="flex-none text-zinc-400 dark:text-zinc-500" aria-hidden="true">↻</span>
        <span class="min-w-0">{@stall_hint}</span>
      </p>
    </div>
    """
  end

  @doc """
  The live status line — animated dots + status word + elapsed + a compact Stop,
  rendered UN-BOXED at the foot of the transcript spine (below everything the turn
  has produced so far, above the composer). No card, no background: it reads as the
  conversation's live tail, not a docked widget.
  """
  attr :messages, :list, required: true
  attr :word, :string, required: true
  attr :agent_id, :string, required: true
  attr :mode, :atom, default: :thinking
  # Lifetime cumulative tokens this agent has used (real usage, updated when
  # each turn settles). Kept for callers/tooltips, but NO LONGER shown in the
  # live footer — it's a cost odometer, not a context gauge (see below).
  attr :tokens, :integer, default: 0
  # Fraction (0.0–1.0) of the CONTEXT WINDOW filled this turn — the fuel gauge.
  attr :context_utilization, :float, default: 0.0

  def live_status(assigns) do
    # The bar shows the WORK BEING DONE — not all of it is thinking. Harness
    # maintenance (compacting the context, restarting a crashed CLI) gets its own
    # word + a color shift away from thinking-violet, so you can tell at a glance
    # that the pause is the harness, not the model.
    assigns =
      assigns
      |> assign(:turn_since, turn_started_unix_ms(assigns.messages))
      |> assign_new(:streaming_text, fn -> "" end)
      |> assign_new(:active_tool, fn -> nil end)
      |> assign_status_styles()

    # Fuel gauge, NOT odometer. The live footer shows how full the CONTEXT
    # WINDOW is (the thing that forces a compaction), not the lifetime
    # cumulative cost — a 7-figure cumulative number sitting next to a live
    # spinner reads as a runaway when the context is actually near-empty
    # (that exact misread nearly got a working harness thrown out). The
    # lifetime cost still lives in the sidebar context panel where it reads
    # as cost, not alarm. Liveness ("it's working") is carried by the bouncing
    # dots + the elapsed timer, so the ticking estimate is retired here.
    ctx_pct = round((assigns[:context_utilization] || 0.0) * 100)

    assigns =
      assigns
      |> assign(:ctx_pct, ctx_pct)
      |> assign(:ctx_class, ctx_class(assigns[:context_utilization] || 0.0))

    ~H"""
    <%!-- The live tip of the turn: dots + word + elapsed on the left, Stop docked
         right. Flush-left (no rail/indent) so it lines up with the streaming prose
         and completed messages above it. --%>
    <div class="flex items-center gap-2.5 pr-1 py-1.5">
      <div class="flex gap-1.5 flex-none" aria-hidden="true">
        <div class={["w-2 h-2 rounded-full animate-bounce", @dot_class]} style="animation-delay: 0ms">
        </div>
        <div
          class={["w-2 h-2 rounded-full animate-bounce", @dot_class]}
          style="animation-delay: 150ms"
        >
        </div>
        <div
          class={["w-2 h-2 rounded-full animate-bounce", @dot_class]}
          style="animation-delay: 300ms"
        >
        </div>
      </div>
      <span class={["text-sm font-semibold flex-none", @text_class]}>{@word}…</span>
      <span
        :if={@turn_since}
        id="turn-elapsed"
        phx-hook="Elapsed"
        phx-update="ignore"
        data-since={@turn_since}
        class={["text-sm flex-none tabular-nums", @elapsed_class]}
      ></span>
      <%!-- Context fuel gauge: how full the window is THIS turn. Quiet zinc
           when there's headroom, amber/red as it approaches a compaction. NOT
           the lifetime cumulative cost (that's in the sidebar) — so a busy
           agent with an empty context never looks like a runaway. --%>
      <span
        :if={@ctx_pct > 0}
        class={["text-sm flex-none tabular-nums", @ctx_class]}
        title="context window filled this turn — compaction kicks in near full; lifetime token cost is in the sidebar"
      >
        · {@ctx_pct}% ctx
      </span>
      <span
        :if={@active_tool && @streaming_text == ""}
        class="text-sm flex-none truncate font-mono text-zinc-400"
      >
        · {short_tool(@active_tool)}
      </span>
      <div class="flex-1 min-w-0"></div>
      <button
        type="button"
        phx-click="interrupt_agent"
        phx-value-id={@agent_id}
        class="focus-ring inline-flex items-center gap-2 rounded-lg px-3 py-1.5 text-sm font-medium text-zinc-600 dark:text-zinc-300 hover:text-red-600 dark:hover:text-red-400 hover:bg-red-500/10 active:bg-red-500/20 transition-colors flex-none"
      >
        <span class="w-2.5 h-2.5 rounded-[3px] bg-red-500"></span> Stop
      </button>
    </div>
    """
  end

  # Fuel-gauge color: quiet while there's headroom, amber approaching a
  # compaction, red when the window is about to force one.
  defp ctx_class(u) when is_number(u) and u >= 0.92, do: "text-red-500"
  defp ctx_class(u) when is_number(u) and u >= 0.75, do: "text-amber-500"
  defp ctx_class(_), do: "text-zinc-400"

  @doc """
  Rough output-token estimate from streamed text (~4 chars/token), as an
  integer so it SUMS with the cumulative total into one ticking counter.
  Public: the sidebar Usage panel adds the SAME estimate to its Total so the
  status line and sidebar always show the same number.
  """
  def token_estimate(text) when is_binary(text), do: div(byte_size(text), 4)
  def token_estimate(_), do: 0

  defp short_tool(tool) when is_binary(tool), do: tool |> String.split("__") |> List.last()
  defp short_tool(tool), do: to_string(tool)

  # Word + colour scheme for the live bar, by what the harness is actually doing.
  # Thinking stays violet; harness maintenance (compacting, restarting a crashed
  # CLI) shifts to amber/rose so a pause clearly reads as "the harness", not "the
  # model is slow". Full class strings (no interpolation) so Tailwind keeps them.
  defp assign_status_styles(assigns) do
    {word, dot, container, text, elapsed} =
      case assigns[:mode] || :thinking do
        :compacting ->
          {"Compacting", "bg-amber-400",
           "border-amber-200/70 dark:border-amber-500/20 bg-amber-50 dark:bg-amber-500/10",
           "text-amber-700 dark:text-amber-200", "text-amber-500/70 dark:text-amber-300/50"}

        :restarting ->
          {"Restarting harness", "bg-rose-400",
           "border-rose-200/70 dark:border-rose-500/20 bg-rose-50 dark:bg-rose-500/10",
           "text-rose-700 dark:text-rose-200", "text-rose-500/70 dark:text-rose-300/50"}

        _ ->
          {if(assigns.word in [nil, ""], do: "Thinking", else: assigns.word), "bg-violet-400",
           "border-violet-200/70 dark:border-violet-500/20 bg-violet-50 dark:bg-violet-500/10",
           "text-violet-700 dark:text-violet-200", "text-violet-500/70 dark:text-violet-300/50"}
      end

    assign(assigns,
      word: word,
      dot_class: dot,
      container_class: container,
      text_class: text,
      elapsed_class: elapsed
    )
  end

  @doc """
  The Reasoning Bar — the live status, docked just above the input so it's ALWAYS
  visible (the transcript feed scrolls off; this never does). Animated dots +
  status word + elapsed + the current action + a compact Stop. Reasoning "comes
  out of" the composer: it sits fused above the message box, and you can keep
  queuing while it runs (the queue renders right above it).
  """
  attr :messages, :list, required: true
  attr :word, :string, required: true
  attr :agent_id, :string, required: true

  def reasoning_bar(assigns) do
    activity = current_turn_activity(assigns.messages)
    current = Enum.find(activity, & &1.active) || List.last(activity)

    assigns =
      assigns
      |> assign(:turn_since, turn_started_unix_ms(assigns.messages))
      |> assign(:current_action, current && current.summary)

    ~H"""
    <div class="flex items-center gap-2.5 rounded-xl bg-violet-50 dark:bg-violet-500/10 border border-violet-200/70 dark:border-violet-500/20 px-3.5 py-2">
      <div class="flex gap-1 flex-none" aria-hidden="true">
        <div
          class="w-1.5 h-1.5 rounded-full bg-violet-400 animate-bounce"
          style="animation-delay: 0ms"
        >
        </div>
        <div
          class="w-1.5 h-1.5 rounded-full bg-violet-400 animate-bounce"
          style="animation-delay: 150ms"
        >
        </div>
        <div
          class="w-1.5 h-1.5 rounded-full bg-violet-400 animate-bounce"
          style="animation-delay: 300ms"
        >
        </div>
      </div>
      <span class="text-sm font-medium text-violet-600 dark:text-violet-300 flex-none">{@word}…</span>
      <span
        :if={@turn_since}
        id="turn-elapsed"
        phx-hook="Elapsed"
        phx-update="ignore"
        data-since={@turn_since}
        class="text-sm text-zinc-500 dark:text-zinc-400 flex-none tabular-nums"
      ></span>
      <span
        :if={@current_action}
        class="hidden sm:block text-sm text-zinc-500 dark:text-zinc-400 truncate min-w-0"
      >
        · {@current_action}
      </span>
      <div class="flex-1"></div>
      <button
        type="button"
        phx-click="interrupt_agent"
        phx-value-id={@agent_id}
        class="focus-ring inline-flex items-center gap-1.5 rounded-lg px-2.5 py-1 text-sm font-medium text-zinc-600 dark:text-zinc-300 hover:text-red-600 dark:hover:text-red-400 hover:bg-red-500/10 transition-colors flex-none"
      >
        <span class="w-2 h-2 rounded-[2px] bg-red-500"></span> Stop
      </button>
    </div>
    """
  end

  # If the agent's last actual response was an upstream API failure (overload,
  # 5xx, timeout), it's almost certainly retrying it right now — say so, so a
  # long-running "thinking…" reads as "Anthropic is busy" not "wedged".
  @api_error_re ~r/\b(529|503|502|500|overloaded|api error|internal server error|service unavailable|upstream)\b/i

  defp retry_hint(messages) do
    last_response =
      messages
      |> Enum.reverse()
      |> Enum.find(fn m ->
        m.role in [:assistant, :error] and is_binary(m[:content]) and m.content != ""
      end)

    case last_response do
      %{content: c} ->
        cond do
          c =~ ~r/\b(529|overloaded)\b/i ->
            "Claude's servers are busy right now — I'm retrying automatically. This one can take a minute."

          c =~ @api_error_re ->
            "The model had a brief hiccup — retrying automatically. Nothing you need to do."

          true ->
            nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Tool actions for the in-progress turn (since the last human message),
  oldest→newest, each tagged `active: true` (the latest — still running) or
  `false` (done). The same set chat_panel suppresses inline, so the feed and
  the scrollback never double-list.
  """
  def current_turn_activity(messages) do
    tools = current_turn_tools(messages)
    last = length(tools) - 1

    tools
    |> Enum.with_index()
    |> Enum.map(fn {m, i} ->
      %{
        summary: LoopyardWeb.Components.ToolSummary.summarize(m.tool, m.input || %{}),
        active: i == last
      }
    end)
  end

  # Unix-ms of the last human message — the live elapsed timer counts up from
  # here, so even a long silent prefill (huge context, no tokens yet) shows a
  # ticking "it's alive" signal. nil (no timer) if the turn start isn't on the
  # current page or carries no timestamp.
  defp turn_started_unix_ms(messages) do
    case Enum.reverse(messages) |> Enum.find(&(&1.role == :user)) do
      %{timestamp: %DateTime{} = ts} -> DateTime.to_unix(ts, :millisecond)
      _ -> nil
    end
  end

  defp current_turn_tools(messages) do
    turn =
      messages
      |> Enum.reverse()
      |> Enum.take_while(&(&1.role != :user))
      |> Enum.reverse()

    # tool_ids whose result already landed — a COMPLETED command has left the
    # feed: its console box (command + output + exit) renders inline in the
    # transcript mid-turn (chat_panel's in_live_feed? exception). The chip here
    # covers only the window while it RUNS.
    done_ids =
      for %{role: :tool_result} = r <- turn,
          is_binary(r[:tool_id]),
          into: MapSet.new(),
          do: r.tool_id

    turn
    |> Enum.filter(&(&1.role == :tool and not own_surface_tool?(&1[:tool])))
    |> Enum.reject(&(command_kind?(&1) and completed_tool?(&1, done_ids)))
  end

  defp command_kind?(m) do
    (m[:tool_kind] || Loopyard.Agent.ToolKind.classify(m[:tool] || "")) == :command
  end

  defp completed_tool?(m, done_ids),
    do: is_binary(m[:tool_id]) and MapSet.member?(done_ids, m[:tool_id])

  # Tools that render their OWN prominent surface — exec/docker_compose as a
  # console box, and ask_user/request_secret/propose_* as an interactive card — so
  # they don't ALSO belong in the compact activity feed, which would double-show
  # them (the command/card a second time).
  @own_surface_tools ~w(
    exec docker_compose ask_user request_secret
    propose_fork propose_integrate propose_delete_workspace
  )
  defp own_surface_tool?(tool) when is_binary(tool),
    do: Enum.any?(@own_surface_tools, &String.ends_with?(tool, &1))

  defp own_surface_tool?(_), do: false
end
