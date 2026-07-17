defmodule LoopyardWeb.Live.WorkspaceLive.Components.ContextPanel do
  @moduledoc """
  Agent Context sidebar panel — shows agent info, Docker context,
  Claude usage stats, and available MCP tools. Uses the shared
  LoopyardWeb.Components.SideNav building blocks for consistent
  section rhythm with the workspace sidebar.
  """
  use Phoenix.Component

  import LoopyardWeb.Components.SideNav, only: [section: 1, info_row: 1]
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
      "flex-col h-full bg-zinc-50 dark:bg-zinc-900/50 overflow-y-auto border-l border-zinc-200 dark:border-zinc-700/80",
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

  def context_sections(assigns) do
    ~H"""
    <%!-- Titled header so this pane reads as "the SELECTED agent's detail",
         clearly separated from the workspace nav (Agents/Services/Volumes) that
         sits directly above it in the shared right rail — otherwise the status
         line butts straight into that list with no divider. Hidden in the mobile
         sheet, which supplies its own title. --%>
    <div :if={!@in_sheet} class="border-t border-zinc-200 dark:border-zinc-700/80 pt-3 pb-2 mb-1">
      <div class="text-xs font-semibold uppercase tracking-wide text-zinc-400 dark:text-zinc-500">
        Agent
      </div>
      <h3 class="text-base font-semibold text-zinc-900 dark:text-zinc-100 truncate mt-0.5">
        {@agent.name}
      </h3>
    </div>

    <.harness_status agent={@agent} />

    <%!-- Changes moved OUT of the agent panel into the "Files" surface (the
         volume's Git tab), where they live with the file browser. The workspace
         nav's volume row still shows the ±N change badge for at-a-glance, and
         one click on it opens Files → changes. --%>

    <.claude_usage agent={@agent} />

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

    <%!-- Danger zone: remove THIS agent. Destructive + confirmed. Stops the
         session and removes the agent from the workspace; the code volume is
         untouched. Lives at the bottom, quiet, so it's reachable but not a
         fat-finger target. --%>
    <div class="border-t border-zinc-100 dark:border-zinc-800 mt-3 pt-2 pb-3">
      <button
        type="button"
        phx-click="remove_agent"
        phx-value-id={@agent.id}
        data-confirm={"Remove agent \"#{@agent.name}\"? Its session stops and it's removed from this workspace. The code in the volume is not touched."}
        class="w-full text-left text-sm text-zinc-400 hover:text-red-600 dark:text-zinc-500 dark:hover:text-red-400 px-2 py-1.5 rounded-lg hover:bg-red-50 dark:hover:bg-red-900/10 transition-colors"
      >
        Remove agent
      </button>
    </div>
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
    <div class="px-3 pt-3 pb-1">
      <%!-- Calm by default: a single subtle line ("● Ready"), aligned with the
           section rows below. Only PROBLEM states (rate-limited, auth expired,
           reconnecting) escalate to the loud card with a consequence line — those
           are the ones worth a glance; "you can send" isn't. --%>
      <div
        :if={@loud?}
        class={["flex items-center gap-2.5 rounded-lg px-2.5 py-2", @hs.bg]}
      >
        <span class={["w-2 h-2 rounded-full flex-none", @hs.dot, @hs.pulse]}></span>
        <div class="min-w-0">
          <div class={["text-sm font-semibold leading-tight", @hs.text]}>{@hs.label}</div>
          <div :if={@hs.detail} class="text-sm text-zinc-500 dark:text-zinc-400 truncate">
            {@hs.detail}
          </div>
        </div>
      </div>
      <div :if={!@loud?} class="flex items-center gap-2 px-2 min-h-6 text-sm">
        <span class={["w-1.5 h-1.5 rounded-full flex-none", @hs.dot, @hs.pulse]}></span>
        <span class={["font-medium", @hs.text]}>{@hs.label}</span>
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
        bad("Reconnecting", "the harness dropped — restarting; your messages will queue")

      agent[:auth_error] ->
        bad("Auth expired", "re-login required — connect Claude on /workstation")

      Map.get(agent, :rate_limit_status, :ok) != :ok or status == :rate_limited ->
        reset = Loopyard.ChatAgent.StreamHandler.format_reset(agent[:rate_limit_resets_at_ms])
        label = Loopyard.ChatAgent.StreamHandler.rate_limit_label(agent[:rate_limit_type])
        util = agent[:rate_limit_utilization]

        pct =
          if is_number(util) and util > 0, do: " · ~#{round(util * 100)}% of cap", else: ""

        warn(
          "amber",
          "#{String.capitalize(label)} limit reached",
          "resets #{reset}#{pct} · queued messages auto-send"
        )

      status == :backoff ->
        warn("blue", "Reconnecting…", "restarting the harness, then resuming")

      status in [:booting, :starting] ->
        warn("blue", "Starting…", "bringing the harness up")

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
    total_tokens =
      (assigns.agent[:total_input_tokens] || 0) + (assigns.agent[:total_output_tokens] || 0)

    assigns = assign(assigns, :total_tokens, total_tokens)

    ~H"""
    <.section label="Usage">
      <.info_row
        :if={@agent[:model]}
        label="Model"
        value={short_model(@agent.model)}
        monospace
        class="text-zinc-700 dark:text-zinc-300"
      />
      <.info_row
        :if={!@agent[:model]}
        label="Model"
        value="awaiting first response"
        class="text-zinc-500 italic"
      />
      <.info_row label="Total tokens" value={compact_number(@total_tokens)} />
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

  @doc "Shorten model name for display."
  def short_model(nil), do: nil

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
