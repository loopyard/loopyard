defmodule BoomLooperWeb.Live.WorkspaceLive.Components.ContextPanel do
  @moduledoc """
  Agent Context sidebar panel — shows agent info, Docker context,
  Claude usage stats, and available MCP tools. Uses the shared
  BoomLooperWeb.Components.SideNav building blocks for consistent
  section rhythm with the workspace sidebar.
  """
  use Phoenix.Component

  import BoomLooperWeb.Components.SideNav, only: [section: 1, info_row: 1]
  import BoomLooperWeb.Live.WorkspaceLive.Components.Formatters, only: [time_ago: 1]

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
      <.agent_name agent={@agent} editing_name={@editing_name} />

      <.section label="Info">
        <.info_row
          label="Status"
          value={if @agent[:active_tool] && @agent.status == :thinking, do: "using #{short_tool(@agent.active_tool)}", else: @agent.status}
        />
        <.info_row label="Turns" value={@agent[:turns] || 0} />
        <.info_row label="Tool calls" value={@agent.tool_calls} />
        <.info_row label="Errors" value={@agent.errors} class={if @agent.errors > 0, do: "text-red-500 font-medium"} />
        <.info_row label="Messages" value={length(@agent.messages)} />
        <.info_row :if={@agent[:started_at]} label="Started" value={time_ago(@agent.started_at)} />
        <.info_row :if={@agent[:last_activity_at]} label="Last active" value={time_ago(@agent.last_activity_at)} />
      </.section>

      <.docker_context agent={@agent} />
      <.claude_usage agent={@agent} />
      <.tool_list />
    </aside>
    """
  end

  defp agent_name(assigns) do
    ~H"""
    <div class="px-3 py-3 md:py-2 border-b border-zinc-200 dark:border-zinc-700/80">
      <form :if={@editing_name} phx-submit="rename_agent" phx-click-away="cancel_rename" class="flex items-center gap-2">
        <input type="text" name="name" value={@agent.name} autofocus phx-mounted={Phoenix.LiveView.JS.dispatch("focus")}
          class="flex-1 rounded-lg border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-3 py-1.5 text-sm
                 text-zinc-900 dark:text-zinc-100 focus:outline-none focus:ring-1 focus:ring-violet-500/30" />
        <button type="submit" class="focus-ring text-xs font-medium text-violet-600 dark:text-violet-400 hover:underline flex-none">Save</button>
      </form>
      <div :if={!@editing_name} phx-click="start_rename" class="cursor-pointer group flex items-center gap-2 px-2">
        <span class="text-sm font-medium text-zinc-900 dark:text-zinc-100">{@agent.name}</span>
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3 h-3 text-zinc-300 dark:text-zinc-600 opacity-0 group-hover:opacity-100 transition-opacity" aria-hidden="true">
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
      <.info_row label="Container" value={@ctx.container} monospace class="text-zinc-700 dark:text-zinc-300" />
      <.info_row :if={@ctx.volume} label="Volume" value={@ctx.volume} monospace class="text-zinc-700 dark:text-zinc-300" />
      <.info_row
        label="Mode"
        value={@ctx.mode}
        class={if @ctx.mode == :container, do: "text-emerald-600 dark:text-emerald-400 font-medium", else: "text-amber-600 dark:text-amber-400 font-medium"}
      />
      <.info_row :if={@ctx.workspace_id} label="Workspace" value={@ctx.workspace_id} monospace class="text-zinc-700 dark:text-zinc-300" />
    </.section>
    """
  end

  defp claude_usage(assigns) do
    total_tokens = (assigns.agent[:total_input_tokens] || 0) + (assigns.agent[:total_output_tokens] || 0)
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
        <span :for={tool <- @tools} class="px-1.5 py-0.5 rounded text-[10px] font-mono bg-zinc-100 dark:bg-zinc-800 text-zinc-600 dark:text-zinc-400">
          {tool}
        </span>
      </div>
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
  def compact_number(n) when is_integer(n) and n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  def compact_number(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  def compact_number(n) when is_integer(n), do: Integer.to_string(n)
  def compact_number(n) when is_float(n), do: compact_number(round(n))
  def compact_number(_), do: "0"

  @doc "Build Docker context info from agent state."
  def docker_ctx(agent) do
    ws_id = agent[:workspace_id]
    container = if ws_id, do: "bl-#{ws_id}-workspace-1"
    volume = if ws_id, do: "bl-#{ws_id}-code"
    mode = if agent[:bind_mount], do: :bind_mount, else: :container

    %{container: container, volume: volume, workspace_id: ws_id, mode: mode}
  end

  @doc "List all MCP tool names from the default toolkit."
  def mcp_tool_names do
    BoomLooper.ChatAgent.ToolConfig.default_tools()
    |> Enum.flat_map(fn mod ->
      info = mod.__tool_server__()
      Enum.map(info.tools, & &1.__tool_name__())
    end)
    |> Enum.sort()
  end
end
