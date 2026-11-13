defmodule LoopyardWeb.Live.WorkspaceLive.Messages.SubAgent do
  @moduledoc """
  The sub-agent card: how a delegation to a harness-native sub-agent (Claude
  Code's `Task`/`Agent` tool — kind `:agent`) reads in the transcript.

  Two pieces, both dispatched from `Messages.chat_msg/1`:

    * `call/1` — the delegating call's row: the job (the model's own
      description), the sub-agent type, the model it ran on once the harness
      reports it (`:subagent_model`, from the Agent tool's own
      `resolvedModel` — never the configured setting, which the harness may
      not have honoured), and a live elapsed counter while it works. Under it, collapsed by default, the sub-agent's own calls —
      every `:tool` message whose `parent_tool_id` is this call (nested by
      `Transcript.item_contexts/2`, never rendered as rows of their own) —
      each paired with its result. While the sub-agent is still working the
      summary line names its latest call, so the card is never silently stuck.
    * `result/1` — the call's result: the sub-agent's final REPORT, rendered
      as prose (it's markdown the model wrote for the parent), or, for a
      background sub-agent that never reports on its call, the one quiet line
      the Translator closed it with.

  Template-only, no socket. Everything it knows about the children comes from
  the precomputed row context (`ctx.children` / `ctx.settled`); a caller
  without one (the message tear-off page) gets the row without the nest.
  """
  use Phoenix.Component

  alias Loopyard.Agent.ToolKind
  alias LoopyardWeb.Components.ToolSummary

  attr :msg, :map, required: true
  attr :ctx, :map, default: nil
  attr :detail_level, :atom, default: :trace

  def call(assigns) do
    input = assigns.msg[:input] || %{}
    children = (assigns[:ctx] || %{})[:children] || []
    settled? = (assigns[:ctx] || %{})[:settled] == true
    last = List.last(children)

    assigns =
      assign(assigns,
        summary: ToolSummary.summarize(assigns.msg[:tool] || "Agent", input),
        type: input["subagent_type"],
        model: model_label(assigns.msg[:subagent_model]),
        children: Enum.map(children, &child_row/1),
        count: length(children),
        settled?: settled?,
        working_on: if(not settled? and last, do: summarize(last.call)),
        since: unix_ms(assigns.msg[:timestamp]),
        dom_id: "subagent-#{assigns.msg[:id] || assigns.msg[:tool_id]}"
      )

    ~H"""
    <div class="py-1" id={@dom_id}>
      <%!-- The job wraps inside its own box next to the dot (a long description
      on a phone must not strand the dot on a line of its own). --%>
      <div class="flex items-start gap-2">
        <span class="w-1.5 h-1.5 mt-2.5 rounded-full flex-none bg-zinc-300 dark:bg-zinc-600"></span>
        <span class="text-lead text-zinc-600 dark:text-zinc-400 min-w-0">{@summary}</span>
        <span
          :if={@type}
          class="text-meta uppercase tracking-wide text-zinc-400 dark:text-zinc-500 flex-none mt-1"
        >
          {@type}
        </span>
        <span :if={@model} class="text-meta text-zinc-400 dark:text-zinc-500 flex-none mt-1">
          on {@model}
        </span>
        <%!-- Alive signal while the sub-agent works: a client-side counter from
        the call's own timestamp (server owns the time, the browser animates). --%>
        <span
          :if={!@settled? && @since}
          id={@dom_id <> "-elapsed"}
          phx-hook="Elapsed"
          phx-update="ignore"
          data-since={@since}
          class="text-meta tabular-nums text-violet-500 animate-pulse flex-none mt-1"
        ></span>
      </div>
      <%!-- The sub-agent's own calls, folded under the delegation. Collapsed by
      default: the summary line carries the count and, mid-work, what it is
      doing right now — the report below is the product. --%>
      <details :if={@count > 0} class="mt-1 group/nest">
        <summary class="text-lead text-zinc-500 dark:text-zinc-400 cursor-pointer hover:text-zinc-600 dark:hover:text-zinc-300 select-none list-none flex items-center gap-1.5">
          <span class="flex-none transition-transform group-open/nest:rotate-90">▸</span>
          <%!-- The count never wraps or shrinks; the live command is what truncates. --%>
          <span class="flex-none whitespace-nowrap">
            {@count} {if @count == 1, do: "call", else: "calls"}{if !@settled?, do: " so far"}
          </span>
          <span :if={@working_on} class="font-mono text-zinc-500 dark:text-zinc-400 min-w-0 truncate">
            · {@working_on}
          </span>
        </summary>
        <ul class="mt-1 ml-1 pl-3 border-l border-zinc-200 dark:border-zinc-800 space-y-1">
          <li :for={c <- @children} class="text-body leading-relaxed">
            <div class="flex items-start gap-2">
              <span class={["flex-none w-3.5 text-center", c.glyph_class]}>{c.glyph}</span>
              <span class="font-mono min-w-0 break-words text-zinc-600 dark:text-zinc-400">
                {c.summary}
              </span>
            </div>
            <p :if={c.preview} class="ml-5 text-meta text-zinc-500 dark:text-zinc-500 truncate">
              {c.preview}
            </p>
          </li>
        </ul>
      </details>
    </div>
    """
  end

  attr :msg, :map, required: true
  attr :ctx, :map, default: nil
  attr :detail_level, :atom, default: :trace

  def result(assigns) do
    content = to_string(assigns.msg[:content] || "")
    lines = content |> String.trim() |> String.split("\n")
    # Same lazy-body gate as the other result cards: the precomputed ctx says
    # :full / :preview / false; without a ctx (tear-off page) render it all.
    expanded =
      case assigns[:ctx] do
        %{expanded?: e} -> e
        _ -> :full
      end

    assigns =
      assign(assigns,
        content: content,
        line_count: length(lines),
        one_liner?: length(lines) == 1,
        is_error: assigns.msg[:is_error] == true,
        expanded?: expanded != false,
        lazy?: assigns[:ctx] != nil
      )

    # ONE root element: the chat renders rows through a stateful component,
    # which requires a single static tag at the root.
    ~H"""
    <div class="py-0.5">
      <div :if={@one_liner?} class="flex items-start gap-2 py-0.5">
        <span class={[
          "flex-none w-3.5 text-center",
          @is_error && "text-red-500",
          !@is_error && "text-emerald-500/70"
        ]}>
          {if @is_error, do: "!", else: "✓"}
        </span>
        <span class={[
          "text-lead",
          @is_error && "text-red-600 dark:text-red-400",
          !@is_error && "text-zinc-500 dark:text-zinc-400"
        ]}>
          {@content}
        </span>
      </div>
      <details :if={!@one_liner?} class="group/result" open={@expanded?}>
        <summary
          class="text-lead text-zinc-500 dark:text-zinc-400 cursor-pointer hover:text-zinc-600 dark:hover:text-zinc-300 select-none list-none flex items-center gap-1.5"
          phx-click={@lazy? && "toggle_result"}
          phx-value-msgid={@lazy? && @msg[:id]}
          onclick={@lazy? && "event.preventDefault()"}
        >
          <span class={["transition-transform", @expanded? && "rotate-90"]}>▸</span>
          <span>
            {if @is_error, do: "sub-agent failed", else: "sub-agent report"} · {@line_count} lines
          </span>
        </summary>
        <div
          :if={@expanded?}
          class={[
            "mt-1 p-3 rounded-sm markdown-body",
            @is_error && "bg-red-50 dark:bg-red-950/30 text-red-700 dark:text-red-300",
            !@is_error && "bg-brand-paper-shade dark:bg-brand-ink text-zinc-800 dark:text-zinc-100"
          ]}
        >
          {Loopyard.Markdown.to_html(@content)}
        </div>
      </details>
    </div>
    """
  end

  # One nested call as the list renders it: a status glyph (done / running /
  # failed), the same summary the live feed uses, and the first line of its
  # output as a quiet preview.
  defp child_row(%{call: call, result: result}) do
    {glyph, class} =
      cond do
        is_nil(result) -> {"▸", "text-violet-500 animate-pulse"}
        result[:is_error] -> {"!", "text-red-500"}
        true -> {"✓", "text-emerald-500/70"}
      end

    %{summary: summarize(call), glyph: glyph, glyph_class: class, preview: preview(result)}
  end

  defp summarize(call), do: ToolSummary.summarize(call[:tool] || "tool", call[:input] || %{})

  defp preview(%{content: content}) when is_binary(content) do
    lines = content |> String.trim() |> String.split("\n")

    case lines do
      [""] -> nil
      [one] -> one
      [first | rest] -> "#{first} … +#{length(rest)} lines"
    end
  end

  defp preview(_), do: nil

  # "claude-sonnet-5" → "Sonnet 5". The CLI may tag a context lane onto the id
  # ("claude-opus-5[1m]"); the card names the model, not the lane.
  defp model_label(model) when is_binary(model) and model != "" do
    model
    |> String.replace(~r/\[[^\]]*\]$/, "")
    |> LoopyardWeb.Live.WorkspaceLive.Components.ContextPanel.short_model()
  end

  defp model_label(_), do: nil

  defp unix_ms(%DateTime{} = ts), do: DateTime.to_unix(ts, :millisecond)
  defp unix_ms(_), do: nil

  # Exposed so a caller can ask "is this message a delegation?" without
  # re-deriving the kind rule.
  def delegation?(%{role: :tool} = m),
    do: (m[:tool_kind] || ToolKind.classify(m[:tool])) == :agent

  def delegation?(_), do: false
end
