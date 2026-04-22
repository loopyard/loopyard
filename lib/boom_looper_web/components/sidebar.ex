defmodule BoomLooperWeb.Components.Sidebar do
  @moduledoc """
  Reusable sidebar item components for agents, consoles, and services.

  All Docker-ish things follow the same lifecycle pattern:
  - Running → show status dot, no destructive actions
  - Stopped → show status dot, allow remove/delete

  Each item type adds its own details (ports, status words, etc.)
  on top of this shared pattern.
  """
  use Phoenix.Component

  @doc """
  Renders a sidebar item with consistent layout and lifecycle controls.

  Common attrs:
  - `selected` — whether this item is currently selected
  - `dot_class` — CSS class for the status dot color (e.g. "bg-green-500")
  - `name` — display name

  Slots:
  - `inner_block` — additional content after the name (status words, port links)
  - `actions` — right-aligned controls (remove button, etc.)
  """
  attr :selected, :boolean, default: false
  attr :dot_class, :string, required: true
  attr :name, :string, required: true
  attr :navigate, :string, default: nil
  attr :click, :string, default: nil
  attr :click_value, :string, default: nil
  slot :status_label
  slot :actions
  slot :subtitle

  def sidebar_item(assigns) do
    ~H"""
    <div class={"flex items-center gap-2 px-2 py-1.5 rounded text-sm transition-colors #{if @selected, do: "bg-white dark:bg-zinc-800 shadow-sm", else: "hover:bg-white/60 dark:hover:bg-zinc-800/40"}"}>
      <%= if @navigate do %>
        <.link navigate={@navigate} class="flex items-center gap-2 min-w-0 flex-1">
          <div class={"w-1.5 h-1.5 rounded-full flex-none #{@dot_class}"}></div>
          <span class="truncate text-zinc-600 dark:text-zinc-400">{@name}</span>
          <%= for label <- @status_label do %>
            {render_slot(label)}
          <% end %>
        </.link>
      <% else %>
        <button phx-click={@click} phx-value-id={@click_value} class="flex items-center gap-2 min-w-0 flex-1 text-left w-full">
          <div class={"w-1.5 h-1.5 rounded-full flex-none #{@dot_class}"}></div>
          <span class="truncate text-zinc-600 dark:text-zinc-400">{@name}</span>
          <%= for label <- @status_label do %>
            {render_slot(label)}
          <% end %>
        </button>
      <% end %>
      <%= for action <- @actions do %>
        {render_slot(action)}
      <% end %>
    </div>
    <%= for sub <- @subtitle do %>
      {render_slot(sub)}
    <% end %>
    """
  end

  # --- Agent ---

  attr :agent, :map, required: true
  attr :selected, :boolean, default: false

  def agent_item(assigns) do
    display = agent_display_status(assigns.agent)

    assigns =
      assigns
      |> assign(:display, display)
      |> assign(:dot_class, status_dot(display))

    ~H"""
    <.sidebar_item
      :if={@display != :hidden}
      selected={@selected}
      dot_class={@dot_class}
      name={@agent.name}
      click="select_agent"
      click_value={@agent.id}
    >
      <:status_label>
        <span :if={@display == :thinking} class="text-xs text-violet-500 flex-none">{thinking_word(@agent.id)}</span>
        <span :if={@display == :sleeping} class="text-xs text-zinc-400 flex-none">Sleeping</span>
        <span :if={@display == :crashed} class="text-xs text-red-500 flex-none">Crashed</span>
      </:status_label>
      <:actions></:actions>
      <:subtitle>
        <div :if={@display == :sleeping && @agent[:last_activity_at]} class="mt-1 ml-[18px] px-2 text-xs text-zinc-400 dark:text-zinc-500 truncate">last reply {time_ago_short(@agent.last_activity_at)}</div>
        <div :if={@agent[:status] == :booting} class="mt-1 ml-[18px] px-2 text-xs text-zinc-400 dark:text-zinc-500 truncate">{@agent[:boot_status] || "Initializing..."}</div>
      </:subtitle>
    </.sidebar_item>
    """
  end

  defp time_ago_short(nil), do: ""

  defp time_ago_short(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  # --- Console ---

  attr :console, :map, required: true
  attr :base_path, :string, required: true
  attr :selected, :boolean, default: false

  def console_item(assigns) do
    ~H"""
    <.sidebar_item
      selected={@selected}
      dot_class="bg-green-500"
      name={@console.name}
      navigate={"#{@base_path}/consoles/#{@console.id}"}
    />
    """
  end

  # --- Service ---

  attr :svc, :map, required: true
  attr :base_path, :string, required: true
  attr :selected, :boolean, default: false

  def service_item(assigns) do
    first_port = first_host_port(assigns.svc.ports)
    assigns = assign(assigns, :first_port, first_port)

    ~H"""
    <.sidebar_item
      selected={@selected}
      dot_class={service_dot(@svc)}
      name={@svc.name}
      navigate={"#{@base_path}/services/#{@svc.name}"}
    >
      <:actions>
        <a :if={@first_port && @svc.status == :running} href={"http://localhost:#{@first_port}"} target="_blank"
          class="text-[10px] text-violet-500 hover:text-violet-400 font-mono ml-auto flex-none transition-colors">
          :{@first_port}
        </a>
        <span :if={service_status_text(@svc)} class="text-[10px] text-blue-400 ml-auto flex-none">{service_status_text(@svc)}</span>
        <span :if={!service_status_text(@svc) && !@first_port && @svc.status == :running} class="text-[10px] text-zinc-400 dark:text-zinc-500 ml-auto font-mono truncate max-w-[100px]">{service_detail(@svc)}</span>
        <span :if={@svc.status == :crashed && @svc.exit_info} class="text-[10px] text-red-500 ml-auto truncate max-w-[140px]">{exit_reason(@svc.exit_info)}</span>
      </:actions>
    </.sidebar_item>
    """
  end

  # --- Status helpers (public for use in headers/panels) ---

  @doc """
  Translate an agent's internal status + liveness into the human-facing
  display state. Four visible states:

      :ready    — GenServer alive, CLI idle, waiting for input
      :thinking — a turn is in flight (includes :booting for simplicity)
      :sleeping — log exists but no GenServer (restart, user-stopped, etc.)
      :crashed  — session crashed in a way the agent couldn't recover from

  Plus `:hidden` for `:destroying` — the agent is about to be removed
  from the UI entirely.
  """
  def agent_display_status(%{id: id} = agent) do
    status = Map.get(agent, :status)

    # Liveness is authoritatively produced at assign time (see
    # `BoomLooperWeb.Live.WorkspaceLive.AgentLifecycle.annotate_liveness/1`)
    # and broadcast events keep it coherent. Falling back to a live
    # `Registry.lookup/2` here used to cause a "Sleeping" flash during
    # re-renders triggered by patches — Registry is authoritative, but
    # a compute-at-render-time call can race with a supervisor restart
    # and return `[]` for a microsecond, flipping a Ready dot to gray
    # and back. Prefer the cached `:alive?` flag; only fall back to
    # the Registry lookup for callers that hand us unannotated maps.
    alive? =
      case Map.fetch(agent, :alive?) do
        {:ok, flag} -> flag
        :error -> agent_alive?(id)
      end

    quarantined? = Map.get(agent, :quarantined) == true

    cond do
      status == :destroying -> :hidden
      # Quarantined is its own display state — operator must release
      # before the agent can run. Surfaced distinctly so the UI can
      # link to /system/quarantine instead of just offering Restart.
      quarantined? -> :quarantined
      not alive? -> :sleeping
      status in [:idle, nil] -> :ready
      # :backoff renders the same as :thinking for now — the agent is
      # still in-flight from the user's POV (we'll auto-retry). A
      # dedicated "Reconnecting…" label is deferred; audit-2 LOW #7.
      status in [:thinking, :booting, :backoff] -> :thinking
      # :rate_limited — auto-retry is armed; for UI purposes treat as
      # "thinking" (pulsing violet) so the user knows progress will
      # resume on its own.
      status == :rate_limited -> :thinking
      # :auth_expired — terminal without manual re-auth; render as
      # crashed so the user sees a red signal + the inline error
      # message explains what to do.
      status == :auth_expired -> :crashed
      status == :stopped -> :sleeping
      status == :crashed -> :crashed
      true -> :ready
    end
  end

  # Fallback for malformed agent maps (missing :id or unexpected
  # shape). Render as sleeping — neutral gray so the UI doesn't crash
  # on a bad row from an upstream bug. Better to see "unknown" in the
  # sidebar than take down the LiveView.
  def agent_display_status(_other), do: :sleeping

  defp agent_alive?(id) do
    case Registry.lookup(BoomLooper.ChatAgentRegistry, id) do
      [{pid, _}] -> Process.alive?(pid)
      _ -> false
    end
  end

  # Dot classes for both internal (:idle/:thinking/…) and display
  # (:ready/:thinking/:sleeping/:crashed) atoms. The four display states
  # are what `agent_display_status/1` returns and what the UI should
  # pass in; the raw atoms stay supported for places that still render
  # the internal status directly (chat header, etc.) — they map onto
  # the same four visible colors.
  def status_dot(:ready), do: "bg-green-500"
  def status_dot(:thinking), do: "bg-violet-500 animate-pulse"
  def status_dot(:sleeping), do: "bg-zinc-400"
  def status_dot(:crashed), do: "bg-red-500"
  def status_dot(:hidden), do: "bg-zinc-400"
  # Quarantined is distinct from :crashed in meaning (operator must
  # manually release via /system/quarantine) but we use the same red
  # dot so the UI visibly signals "not working." The label + tooltip
  # are what carry the meaning.
  def status_dot(:quarantined), do: "bg-red-500"
  # Internal-atom fallbacks
  def status_dot(:idle), do: "bg-green-500"
  def status_dot(:booting), do: "bg-violet-500 animate-pulse"
  # Audit-2 LOW #7 — :backoff shares the thinking look for now.
  def status_dot(:backoff), do: "bg-violet-500 animate-pulse"
  # Surface #10 — rate-limited is auto-retrying; thinking look.
  def status_dot(:rate_limited), do: "bg-violet-500 animate-pulse"
  # Surface #10 — auth_expired is terminal without re-auth.
  def status_dot(:auth_expired), do: "bg-red-500"
  def status_dot(:stopped), do: "bg-zinc-400"
  def status_dot(:destroying), do: "bg-zinc-400"
  def status_dot(_), do: "bg-zinc-400"

  # Service status states → dot color:
  # :running - confirmed running via Docker → green
  # :stopped - not running (never started or cleanly stopped) → gray
  # :crashed - exited with non-zero code → red
  # :starting - container started but port not yet listening (transitional) → blue pulse
  def service_dot(%{status: :running}), do: "bg-green-500"
  def service_dot(%{status: :starting}), do: "bg-blue-400 animate-pulse"
  def service_dot(%{status: :crashed}), do: "bg-red-500"
  def service_dot(%{status: :stopped}), do: "bg-zinc-400"
  # Default for unknown/nil status → gray, NEVER green
  def service_dot(_), do: "bg-zinc-400"

  def service_detail(%{image: image}) when is_binary(image), do: image
  def service_detail(%{processes: procs}) when is_list(procs), do: Enum.join(procs, ", ")
  def service_detail(%{command: cmd}) when is_binary(cmd), do: String.slice(cmd, 0..30)
  def service_detail(_), do: ""

  def first_host_port(ports) when is_map(ports) and map_size(ports) > 0 do
    case Enum.at(ports, 0) do
      {_container_port, host_port} -> to_string(host_port)
      _ -> nil
    end
  end
  def first_host_port(_), do: nil

  @thinking_words [
    "thinking", "pondering", "working", "contemplating", "ruminating", "computing",
    "analyzing", "reasoning", "deliberating", "investigating", "galavanting",
    "pontificating", "abstracting", "noodling", "scheming", "conjuring",
    "percolating", "marinating", "vibing", "manifesting", "doin' my thang",
    "cookin'", "brewing", "churning", "crunching", "simmering", "riffing",
    "jamming", "wrangling", "spelunking", "deciphering", "musing",
    "rerouting encryption", "mainframing", "burning tokens", "foxtrotting",
    "beep boop beep boop", "reverse engineering gravity", "consulting the oracle",
    "asking the magic 8-ball", "stacking tokens", "defragmenting thoughts",
    "compiling vibes", "reticulating splines", "makin' bacon", "fishing",
    "cruisin'", "chillaxing", "twirling", "whirling"
  ]

  # Tool-specific phrases — used when the agent's active_tool is known.
  # Each tool gets a list of fun alternatives. Pick one per 3s window.
  @tool_phrases %{
    "read_file" => ["reading", "scanning", "peeking at", "eyeballing"],
    "read_files" => ["speed-reading", "devouring files", "binge-reading"],
    "edit" => ["editing", "surgically modifying", "tweaking", "patching"],
    "multi_edit" => ["bulk editing", "refactoring", "rewriting"],
    "write_file" => ["writing", "authoring", "crafting"],
    "grep" => ["grepping", "hunting for matches", "searching"],
    "glob" => ["finding files", "globbing", "scouting"],
    "tree" => ["mapping the codebase", "surveying", "exploring"],
    "exec" => ["running a command", "executing", "shelling out"],
    "exec_stream" => ["streaming output", "tailing", "watching"],
    "logs" => ["reading logs", "log diving", "checking output"],
    "docker_compose" => ["composing", "orchestrating containers", "wrangling Docker"],
    "probe_http" => ["probing", "pinging the server", "checking if it's alive"],
    "git" => ["git-ing", "committing", "versioning"],
    "inspect_service" => ["inspecting", "diagnosing", "checking vitals"],
    "inspect_env" => ["checking the environment", "env snooping"],
    "service_containers" => ["listing containers", "taking inventory"],
    "app_url" => ["building a link", "URL crafting"],
    "file_url" => ["linking a file", "URL crafting"],
    "workspace_info" => ["checking workspace", "getting bearings"]
  }

  @doc """
  Status word for the sidebar and chat bubble. When the agent has an
  active tool, returns a fun tool-specific phrase. Otherwise falls
  back to the generic thinking word rotation.
  """
  def thinking_word(agent_id, active_tool \\ nil) do
    tool_name = extract_tool_name(active_tool)

    case @tool_phrases[tool_name] do
      phrases when is_list(phrases) ->
        idx = :erlang.phash2({agent_id, div(System.system_time(:second), 3)}, length(phrases))
        Enum.at(phrases, idx)

      nil ->
        idx = :erlang.phash2({agent_id, div(System.system_time(:second), 3)}, length(@thinking_words))
        Enum.at(@thinking_words, idx)
    end
  end

  # Strip the MCP server prefix: "mcp__boom-looper-container__exec" → "exec"
  defp extract_tool_name(nil), do: nil
  defp extract_tool_name("mcp__" <> rest) do
    case String.split(rest, "__", parts: 2) do
      [_server, name] -> name
      _ -> rest
    end
  end
  defp extract_tool_name(name), do: name

  defp service_status_text(%{status: :running}), do: nil
  defp service_status_text(%{status: :starting}), do: "starting"
  defp service_status_text(%{status: :crashed}), do: nil
  defp service_status_text(%{status: :stopped}), do: nil
  defp service_status_text(_), do: nil

  defp exit_reason(%{oom_killed: true}), do: "OOM killed"
  defp exit_reason(%{error: error}) when is_binary(error), do: error
  defp exit_reason(%{exit_code: 0}), do: "exited cleanly"
  defp exit_reason(%{exit_code: 137}), do: "killed (SIGKILL)"
  defp exit_reason(%{exit_code: 143}), do: "stopped (SIGTERM)"
  defp exit_reason(%{exit_code: code}), do: "exit code #{code}"
  defp exit_reason(_), do: "stopped"
end
