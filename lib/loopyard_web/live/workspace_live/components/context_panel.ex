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
  attr :editing_name, :boolean, default: false

  def context_sections(assigns) do
    ~H"""
    <.agent_name agent={@agent} editing_name={@editing_name} />

    <.harness_status agent={@agent} />

    <.context_files agent={@agent} />

    <.section label="Info">
      <.info_row label="Turns" value={@agent[:turns] || 0} />
      <.info_row label="Tool calls" value={@agent.tool_calls} />
      <.info_row
        label="Errors"
        value={@agent.errors}
        class={if @agent.errors > 0, do: "text-red-500 font-medium"}
      />
      <.info_row label="Messages" value={length(@agent.messages)} />
      <.info_row :if={@agent[:started_at]} label="Started" value={time_ago(@agent.started_at)} />
      <.info_row
        :if={@agent[:last_activity_at]}
        label="Last active"
        value={time_ago(@agent.last_activity_at)}
      />
    </.section>

    <.docker_context agent={@agent} />
    <.claude_usage agent={@agent} />
    <.tool_list />
    """
  end

  # Prominent, color-coded harness state — the one place to glance at to know
  # whether it's safe to send, working, waiting, or in a bad state (rate-limited,
  # auth expired, reconnecting, offline). The bad states are loud on purpose: the
  # whole point is that "something's wrong / your message will wait" is never a
  # silent surprise.
  defp harness_status(assigns) do
    assigns = assign(assigns, :hs, harness_state(assigns.agent))

    ~H"""
    <div class="px-3 py-2.5 border-b border-zinc-200 dark:border-zinc-700/80">
      <div class={["flex items-center gap-2.5 rounded-lg px-2.5 py-2", @hs.bg]}>
        <span class={["w-2 h-2 rounded-full flex-none", @hs.dot, @hs.pulse]}></span>
        <div class="min-w-0">
          <div class={["text-xs font-semibold leading-tight", @hs.text]}>{@hs.label}</div>
          <div :if={@hs.detail} class="text-[11px] text-zinc-500 dark:text-zinc-400 truncate">
            {@hs.detail}
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Map agent state → display. Order matters: worst/most-actionable states win,
  # so a rate-limit or dead session is never masked by a stale :thinking.
  defp harness_state(agent) do
    status = agent[:status]
    alive? = Map.get(agent, :alive?, true)

    cond do
      alive? == false ->
        bad("Harness offline", "reconnecting the CLI — your messages will queue")

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

      status == :stopped ->
        %{
          bg: "bg-zinc-500/10",
          dot: "bg-zinc-400",
          pulse: "",
          text: "text-zinc-600 dark:text-zinc-300",
          label: "Stopped",
          detail: "send a message to start it"
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

  defp agent_name(assigns) do
    ~H"""
    <div class="px-3 py-3 md:py-2 border-b border-zinc-200 dark:border-zinc-700/80">
      <form
        :if={@editing_name}
        phx-submit="rename_agent"
        phx-click-away="cancel_rename"
        class="flex items-center gap-2"
      >
        <input
          type="text"
          name="name"
          value={@agent.name}
          autofocus
          phx-mounted={Phoenix.LiveView.JS.dispatch("focus")}
          class="flex-1 rounded-lg border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-3 py-1.5 text-sm
                 text-zinc-900 dark:text-zinc-100 focus:outline-none focus:ring-1 focus:ring-violet-500/30"
        />
        <button
          type="submit"
          class="focus-ring text-xs font-medium text-violet-600 dark:text-violet-400 hover:underline flex-none"
        >
          Save
        </button>
      </form>
      <div
        :if={!@editing_name}
        phx-click="start_rename"
        class="cursor-pointer group flex items-center gap-2 px-2"
      >
        <span class="text-sm font-medium text-zinc-900 dark:text-zinc-100">{@agent.name}</span>
        <svg
          xmlns="http://www.w3.org/2000/svg"
          viewBox="0 0 16 16"
          fill="currentColor"
          class="w-3 h-3 text-zinc-300 dark:text-zinc-600 opacity-0 group-hover:opacity-100 transition-opacity"
          aria-hidden="true"
        >
          <path d="M13.488 2.513a1.75 1.75 0 0 0-2.475 0L6.75 6.774a2.75 2.75 0 0 0-.596.892l-.848 2.047a.75.75 0 0 0 .98.98l2.047-.848a2.75 2.75 0 0 0 .892-.596l4.261-4.262a1.75 1.75 0 0 0 0-2.474Z" />
          <path d="M4.75 3.5c-.69 0-1.25.56-1.25 1.25v6.5c0 .69.56 1.25 1.25 1.25h6.5c.69 0 1.25-.56 1.25-1.25V9A.75.75 0 0 1 14 9v2.25A2.75 2.75 0 0 1 11.25 14h-6.5A2.75 2.75 0 0 1 2 11.25v-6.5A2.75 2.75 0 0 1 4.75 2H7a.75.75 0 0 1 0 1.5H4.75Z" />
        </svg>
      </div>
    </div>
    """
  end

  defp docker_context(assigns) do
    ctx = docker_ctx(assigns.agent)
    assigns = assign(assigns, :ctx, ctx)

    ~H"""
    <.section :if={@ctx.container} label="Docker">
      <.info_row
        label="Container"
        value={@ctx.container}
        monospace
        class="text-zinc-700 dark:text-zinc-300"
      />
      <.info_row
        :if={@ctx.volume}
        label="Volume"
        value={@ctx.volume}
        monospace
        class="text-zinc-700 dark:text-zinc-300"
      />
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
        :if={@ctx.workspace_id}
        label="Workspace"
        value={@ctx.workspace_id}
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
    <.section label="Claude">
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

  defp tool_list(assigns) do
    tools = mcp_tool_names()
    assigns = assign(assigns, :tools, tools)

    ~H"""
    <.section label="Tools">
      <div class="flex flex-wrap gap-1 px-2">
        <span
          :for={tool <- @tools}
          class="px-1.5 py-0.5 rounded text-[10px] font-mono bg-zinc-100 dark:bg-zinc-800 text-zinc-600 dark:text-zinc-400"
        >
          {tool}
        </span>
      </div>
    </.section>
    """
  end

  defp context_files(assigns) do
    files = discover_context_files(assigns.agent)
    assigns = assign(assigns, :files, files)

    ~H"""
    <.section :if={@files != []} label="Context">
      <div class="space-y-0.5 px-2">
        <div :for={file <- @files} class="flex items-center gap-2 min-h-6 text-xs">
          <span class="text-zinc-500 flex-none">{file.type}</span>
          <%= if file.url do %>
            <a
              href={file.url}
              target="_blank"
              rel="noopener"
              class="font-mono text-violet-600 dark:text-violet-400 hover:underline truncate"
            >
              {file.name}
            </a>
          <% else %>
            <span class="font-mono text-zinc-700 dark:text-zinc-300 truncate">{file.name}</span>
          <% end %>
        </div>
      </div>
    </.section>
    """
  end

  # Discover what context files are loaded for this agent.
  # Checks the agent's working_dir for CLAUDE.md, .claude/ configs,
  # skills, and the system prompt.
  defp discover_context_files(agent) do
    working_dir = agent[:working_dir]
    ws_id = agent[:workspace_id]

    files = []

    # CLAUDE.md
    files =
      if working_dir && File.exists?(Path.join(working_dir, "CLAUDE.md")) do
        volume = if ws_id, do: Loopyard.Workspace.volume_name_for(ws_id)
        url = if volume, do: file_url_path(ws_id, volume, "CLAUDE.md")
        files ++ [%{name: "CLAUDE.md", type: "memory", url: url}]
      else
        files
      end

    # .claude/CLAUDE.md
    files =
      if working_dir && File.exists?(Path.join(working_dir, ".claude/CLAUDE.md")) do
        files ++ [%{name: ".claude/CLAUDE.md", type: "memory", url: nil}]
      else
        files
      end

    # Skills — walk .claude/skills/**/ for any dir containing SKILL.md
    skills_dir = if working_dir, do: Path.join(working_dir, ".claude/skills")

    files =
      if skills_dir && File.dir?(skills_dir) do
        skill_files =
          Path.join(skills_dir, "**/SKILL.md")
          |> Path.wildcard()
          |> Enum.map(fn skill_path ->
            # Extract the skill name from the path relative to .claude/skills/
            skill_path
            |> Path.relative_to(skills_dir)
            |> Path.dirname()
          end)
          |> Enum.reject(&(&1 == "."))

        files ++ Enum.map(skill_files, &%{name: &1, type: "skill", url: nil})
      else
        files
      end

    # System prompt (always present)
    files ++ [%{name: "system prompt", type: "prompt", url: nil}]
  rescue
    _ -> [%{name: "system prompt", type: "prompt", url: nil}]
  end

  defp file_url_path(ws_id, volume, path) do
    # Find project_id for the URL
    case Loopyard.ProjectRegistry.get_workspace(ws_id) do
      %{project_id: pid} ->
        "/projects/#{pid}/workspaces/#{ws_id}/volumes/#{volume}/files/#{path}"

      _ ->
        nil
    end
  rescue
    _ -> nil
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

  @doc "List all MCP tool names from the default toolkit."
  def mcp_tool_names do
    Loopyard.ChatAgent.ToolConfig.default_tools()
    |> Enum.flat_map(fn mod ->
      info = mod.__tool_server__()
      Enum.map(info.tools, & &1.__tool_name__())
    end)
    |> Enum.sort()
  end
end
