defmodule LoopyardWeb.Live.WorkspaceLive.Components.ContextPanel do
  @moduledoc """
  Agent Context sidebar panel — shows agent info, Docker context,
  Claude usage stats, and available MCP tools. Uses the shared
  LoopyardWeb.Components.SideNav building blocks for consistent
  section rhythm with the workspace sidebar.
  """
  use Phoenix.Component

  import LoopyardWeb.Components.SideNav,
    only: [section: 1, info_row: 1, detail_hero: 1, action_bar: 1]

  import LoopyardWeb.Components.Common, only: [control_btn: 1]
  import LoopyardWeb.Live.WorkspaceLive.Components.Formatters, only: [time_ago: 1]

  attr :agent, :map, required: true
  attr :has_container, :boolean, default: false
  attr :container_env, :string, default: nil
  attr :container_logs, :string, default: ""
  attr :editing_name, :boolean, default: false
  attr :mobile, :boolean, default: false

  def context_panel(assigns) do
    ~H"""
    <aside class={[
      "flex-col h-full bg-brand-paper-shade dark:bg-brand-ink/50 overflow-y-auto border-l border-zinc-200 dark:border-zinc-700/80",
      if(@mobile, do: "flex flex-1", else: "hidden lg:flex w-80 flex-none")
    ]}>
      <.context_sections agent={@agent} editing_name={@editing_name} />
    </aside>
    """
  end

  @doc """
  The context panel's body sections (agent name, context files, Info,
  Docker, Claude, Tools) WITHOUT the `<aside>` wrapper — so they can be
  embedded directly in the combined workspace rail (right side) below the
  Agents/Services/Volumes nav.
  """
  attr :agent, :map, required: true
  attr :changes, :map, default: %{staged: [], unstaged: []}
  attr :editing_name, :boolean, default: false
  attr :base_path, :string, default: nil
  # In the mobile bottom-sheet the sheet already shows the agent name as its
  # title, so we suppress this in-panel header there to avoid a duplicate. On
  # desktop (embedded in the right rail) it's the ONLY title, so it shows.
  attr :in_sheet, :boolean, default: false
  # This turn's streamed-output token estimate (integer) — added to the Usage
  # Total so the sidebar matches the live status line mid-turn.
  attr :live_token_est, :integer, default: 0

  def context_sections(assigns) do
    hs = harness_state(assigns.agent)
    est = assigns[:live_token_est] || 0

    total_tokens =
      (assigns.agent[:total_input_tokens] || 0) + (assigns.agent[:total_output_tokens] || 0) + est

    assigns = assign(assigns, hs: hs, total_tokens: total_tokens, estimating?: est > 0)

    ~H"""
    <%!-- STICKY HERO: the selected agent's identity + LIVE state, pinned to the
    top of the detail zone so scrolling the sections below never loses which
    agent you're on. Status word flush-right; model · tokens · cost inline. --%>
    <.detail_hero
      eyebrow="Agent"
      name={@agent.name}
      dot={@hs.dot}
      status={@hs.label}
      status_class={"#{@hs.bg} #{@hs.text}"}
    >
      <:facts>
        {short_model(@agent[:model]) || "default"} · {if @estimating?, do: "~"}{compact_number(
          @total_tokens
        )} tok
        · ${Float.round((@agent[:total_cost_usd] || 0.0) * 1.0, 2)}
      </:facts>
    </.detail_hero>

    <%!-- Loud consequence card ONLY for problem states (rate-limit / auth /
    reconnecting) — the calm "Ready/Asleep" status now lives in the hero. --%>
    <.harness_status agent={@agent} />

    <.claude_usage agent={@agent} live_token_est={@live_token_est} />

    <%!-- Only the numbers not shown anywhere else: errors (a real signal) + how
    long it's been running / idle. The chat is the record of turns / tool
    calls / messages — no vanity counts. --%>
    <.section label="Activity">
      <.info_row
        label="Errors"
        value={@agent.errors}
        class={if @agent.errors > 0, do: "text-red-500 font-medium"}
      />
      <.info_row :if={@agent[:started_at]} label="Started" value={time_ago(@agent.started_at)} />
      <.info_row
        :if={@agent[:last_activity_at]}
        label="Last active"
        value={time_ago(@agent.last_activity_at)}
      />
    </.section>

    <.docker_context agent={@agent} />

    <%!-- STICKY FOOTER: a full "Restart agent" (escape hatch for a wedged harness
    or a dropped/changed MCP tool — reloads tools, keeps the conversation),
    then the destructive "Remove agent" set apart below the divider. --%>
    <.action_bar>
      <:main>
        <.control_btn
          phx-click="restart_session"
          phx-value-id={@agent.id}
          data-confirm={"Restart agent \"#{@agent.name}\"? Reloads its tools and reconnects the harness. Any in-progress turn stops; the conversation is kept."}
          class="w-full justify-center"
        >
          Restart agent
        </.control_btn>
      </:main>
      <:danger>
        <.control_btn
          variant={:danger}
          phx-click="remove_agent"
          phx-value-id={@agent.id}
          data-confirm={"Remove agent \"#{@agent.name}\"? Its session stops and it's removed from this workspace. The code in the volume is not touched."}
          class="w-full justify-center"
        >
          Remove agent
        </.control_btn>
      </:danger>
    </.action_bar>
    """
  end

  # Prominent, color-coded harness state — the one place to glance at to know
  # whether it's safe to send, working, waiting, or in a bad state (rate-limited,
  # auth expired, reconnecting, offline). The bad states are loud on purpose: the
  # whole point is that "something's wrong / your message will wait" is never a
  # silent surprise.
  defp harness_status(assigns) do
    assigns =
      assigns
      |> assign(:hs, harness_state(assigns.agent))
      |> assign(:loud?, loud_status?(assigns.agent))

    ~H"""
    <%!-- ONLY the loud consequence card, for problem states (rate-limited, auth
    expired, reconnecting) — the calm "Ready/Asleep/Working" status now lives
    in the sticky hero, so there's no redundant one-liner here anymore. --%>
    <div :if={@loud?} class="px-3 pt-3 pb-1">
      <div class={["flex items-center gap-2.5 rounded-sm px-2.5 py-2", @hs.bg]}>
        <span class={["w-2 h-2 rounded-full flex-none", @hs.dot, @hs.pulse]}></span>
        <div class="min-w-0">
          <div class={["text-sm font-semibold leading-tight", @hs.text]}>{@hs.label}</div>
          <div :if={@hs.detail || @hs[:countdown]} class="text-sm text-zinc-500 dark:text-zinc-400">
            <span
              :if={@hs[:countdown]}
              id={"hs-cd-#{@agent[:id]}-#{@hs.countdown}"}
              phx-hook="Elapsed"
              phx-update="ignore"
              data-until={@hs.countdown}
              data-prefix="resets in "
              class="tabular-nums"
            ></span><span
              :if={@hs[:countdown] && @hs.detail}
              class="text-zinc-400 dark:text-zinc-500"
            > · </span>{@hs.detail}
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Which harness states deserve the loud card (vs a calm one-liner). Only the
  # ones where "your message will WAIT / something's wrong" — never the happy path.
  defp loud_status?(agent) do
    Map.get(agent, :rate_limit_status, :ok) != :ok or
      agent[:status] in [:rate_limited, :auth_expired, :backoff] or
      agent[:auth_error] != nil
  end

  # Map agent state → display. Order matters: worst/most-actionable states win,
  # so a rate-limit or dead session is never masked by a stale :thinking.
  defp harness_state(agent) do
    status = agent[:status]
    alive? = Map.get(agent, :alive?, true)

    cond do
      # Restored + resting (crashed/stopped with no live session) — the common
      # state after a server restart. NOT broken and NOT reconnecting: it wakes
      # on your next message. Calm zinc, not the scary red "offline" (#64).
      status in [:crashed, :stopped] ->
        %{
          bg: "bg-zinc-500/10",
          dot: "bg-zinc-400",
          pulse: "",
          text: "text-zinc-600 dark:text-zinc-300",
          label: "Asleep",
          detail: "wakes on your next message"
        }

      # Genuinely disconnected while it should be active (e.g. session died
      # mid-recovery) — this one IS reconnecting.
      alive? == false ->
        bad(
          "Reconnecting",
          "the connection dropped — reconnecting; your messages will queue and send"
        )

      agent[:auth_error] ->
        bad("Sign-in expired", "your Claude login expired — reconnect it on the Workstation page")

      Map.get(agent, :rate_limit_status, :ok) != :ok or status == :rate_limited ->
        resets_at = agent[:rate_limit_resets_at_ms]
        label = Loopyard.ChatAgent.StreamHandler.rate_limit_label(agent[:rate_limit_type])
        util = agent[:rate_limit_utilization]

        pct =
          if is_number(util) and util > 0, do: " · ~#{round(util * 100)}% of cap", else: ""

        detail =
          if is_integer(resets_at),
            # Live countdown ("resets in …") carries the timing; detail is the
            # reassurance so a wait visibly progresses instead of reading as stuck.
            do: "queued messages auto-send#{pct}",
            else:
              "resets #{Loopyard.ChatAgent.StreamHandler.format_reset(resets_at)}#{pct} · queued messages auto-send"

        base = warn("amber", "#{String.capitalize(label)} limit reached", detail)
        if is_integer(resets_at), do: Map.put(base, :countdown, resets_at), else: base

      status == :backoff ->
        warn("blue", "Reconnecting…", "reconnecting, then picking up where it left off")

      status in [:booting, :starting] ->
        warn("blue", "Starting…", "getting the agent ready")

      status == :thinking ->
        tool = agent[:active_tool]
        detail = if tool, do: "running #{short_tool(tool)}", else: "thinking…"

        %{
          bg: "bg-violet-500/10",
          dot: "bg-violet-500",
          pulse: "animate-pulse",
          text: "text-violet-700 dark:text-violet-300",
          label: "Working",
          detail: detail
        }

      status == :idle ->
        %{
          bg: "bg-emerald-500/10",
          dot: "bg-emerald-500",
          pulse: "",
          text: "text-emerald-700 dark:text-emerald-400",
          label: "Ready",
          detail: "connected — safe to send"
        }

      true ->
        %{
          bg: "bg-zinc-500/10",
          dot: "bg-zinc-400",
          pulse: "",
          text: "text-zinc-600 dark:text-zinc-300",
          label: to_string(status || "unknown"),
          detail: nil
        }
    end
  end

  defp bad(label, detail) do
    %{
      bg: "bg-red-500/10",
      dot: "bg-red-500",
      pulse: "animate-pulse",
      text: "text-red-600 dark:text-red-400",
      label: label,
      detail: detail
    }
  end

  # Literal class strings per color — Tailwind's purge only sees literals, never
  # interpolated names, so each tone is spelled out in full.
  defp warn("amber", label, detail) do
    %{
      bg: "bg-amber-500/10",
      dot: "bg-amber-500",
      pulse: "animate-pulse",
      text: "text-amber-700 dark:text-amber-400",
      label: label,
      detail: detail
    }
  end

  defp warn("blue", label, detail) do
    %{
      bg: "bg-blue-500/10",
      dot: "bg-blue-500",
      pulse: "animate-pulse",
      text: "text-blue-700 dark:text-blue-400",
      label: label,
      detail: detail
    }
  end

  defp docker_context(assigns) do
    ctx = docker_ctx(assigns.agent)
    assigns = assign(assigns, :ctx, ctx)

    ~H"""
    <%!-- Just Mode + Container. Volume is already in the switcher's Volumes
    list, and the Workspace id is redundant (you're in it). --%>
    <.section :if={@ctx.container} label="Docker">
      <.info_row
        label="Mode"
        value={@ctx.mode}
        class={
          if @ctx.mode == :container,
            do: "text-emerald-600 dark:text-emerald-400 font-medium",
            else: "text-amber-600 dark:text-amber-400 font-medium"
        }
      />
      <.info_row
        label="Container"
        value={@ctx.container}
        monospace
        class="text-zinc-700 dark:text-zinc-300"
      />
    </.section>
    """
  end

  defp claude_usage(assigns) do
    # Total = settled cumulative + this turn's streamed estimate — the SAME sum
    # the live status line shows, so the two never disagree mid-turn. The `~`
    # marks it as estimating; on turn settle the real total absorbs it.
    est = assigns[:live_token_est] || 0

    total_tokens =
      (assigns.agent[:total_input_tokens] || 0) + (assigns.agent[:total_output_tokens] || 0) + est

    assigns =
      assigns
      |> assign(:total_tokens, total_tokens)
      |> assign(:estimating?, est > 0)

    ~H"""
    <.section label="Usage">
      <%!-- Model is a SWITCHER, not a label: pick the CLI alias here and the
    live session flips via ACP session/set_model (persisted for future
    restarts). Options are the CLI's stable aliases; the row shows the
    resolved human name as the current selection. --%>
      <div class="flex items-center justify-between gap-3 px-2 min-h-7 md:min-h-5 text-sm">
        <span class="text-zinc-500 dark:text-zinc-400 flex-none">Model</span>
        <form phx-change="set_agent_model" class="flex-none">
          <input type="hidden" name="agent-id" value={@agent.id} />
          <select
            name="model"
            aria-label="Agent model"
            class="focus-ring rounded-sm border-0 bg-transparent py-0 pl-1 pr-6 text-sm font-medium text-zinc-700 dark:text-zinc-300 cursor-pointer hover:text-violet-600 dark:hover:text-violet-400"
          >
            <%!-- The container CLI's set_model passes FULL model ids through, so
    we offer the latest frontier models by id — not just the
    adapter's stale default/opus/haiku aliases. --%>
            <option value="" disabled selected={true}>
              {short_model(@agent[:model]) || "default"}
            </option>
            <option value="claude-opus-4-8">Opus 4.8</option>
            <option value="claude-fable-5">Fable 5</option>
            <option value="claude-sonnet-5">Sonnet 5</option>
            <option value="claude-haiku-4-5-20251001">Haiku 4.5</option>
            <option value="default">Adapter default</option>
          </select>
        </form>
      </div>
      <.info_row
        label="Total tokens"
        value={"#{if @estimating?, do: "~"}#{compact_number(@total_tokens)}"}
      />
      <.info_row label="Input" value={compact_number(@agent[:total_input_tokens] || 0)} />
      <.info_row label="Output" value={compact_number(@agent[:total_output_tokens] || 0)} />
      <.info_row label="Cache hits" value={compact_number(@agent[:total_cache_read_tokens] || 0)} />
      <.info_row label="Cost" value={"$#{Float.round((@agent[:total_cost_usd] || 0.0) * 1.0, 4)}"} />
    </.section>
    """
  end

  @doc "Shorten MCP tool name for display (strip server prefix)."
  def short_tool("mcp__" <> rest) do
    case String.split(rest, "__", parts: 2) do
      [_server, name] -> name
      _ -> rest
    end
  end

  def short_tool(name), do: name

  @doc "Human display name for a model id/name."
  def short_model(nil), do: nil

  # Known frontier ids → their marketing names (the adapter's list doesn't
  # carry these full ids, so map them ourselves). Anything already resolved to
  # a human name upstream (e.g. "Sonnet 4.5" from the adapter) passes through.
  def short_model("claude-opus-4-8"), do: "Opus 4.8"
  def short_model("claude-fable-5"), do: "Fable 5"
  def short_model("claude-sonnet-5"), do: "Sonnet 5"
  def short_model("claude-haiku-4-5" <> _), do: "Haiku 4.5"
  def short_model("default"), do: "Adapter default"

  def short_model(model) when is_binary(model) do
    model
    |> String.replace("claude-", "")
    |> String.replace(~r/-\d{8}$/, "")
  end

  @doc "Format a number with K/M suffixes for compact display."
  def compact_number(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  def compact_number(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  def compact_number(n) when is_integer(n), do: Integer.to_string(n)
  def compact_number(n) when is_float(n), do: compact_number(round(n))
  def compact_number(_), do: "0"

  @doc "Build Docker context info from agent state."
  def docker_ctx(agent) do
    ws_id = agent[:workspace_id]
    container = if ws_id, do: "loopyard-#{ws_id}-workspace-1"
    volume = if ws_id, do: "loopyard-#{ws_id}-code"
    mode = if agent[:bind_mount], do: :bind_mount, else: :container

    %{container: container, volume: volume, workspace_id: ws_id, mode: mode}
  end
end
