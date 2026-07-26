defmodule LoopyardWeb.Components.Sidebar do
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
        <button
          phx-click={@click}
          phx-value-id={@click_value}
          class="flex items-center gap-2 min-w-0 flex-1 text-left w-full"
        >
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
        <%!-- A running service with a host port IS the dev server — surface a
             conspicuous "Open" button (not a tiny port number) so launching it
             in a browser is obvious, no hunting. stopPropagation so it opens the
             app instead of navigating into the service detail. --%>
        <a
          :if={@first_port && @svc.status == :running}
          href={"http://localhost:#{@first_port}"}
          target="_blank"
          rel="noopener"
          onclick="event.stopPropagation()"
          title={"Open the running app (http://localhost:#{@first_port})"}
          class="ml-auto flex-none inline-flex items-center gap-1 rounded-md px-2 py-0.5 text-xs font-medium bg-emerald-500/15 text-emerald-600 dark:text-emerald-400 hover:bg-emerald-500/25 transition-colors"
        >
          Open <span class="font-mono opacity-70">:{@first_port}</span>
          <svg viewBox="0 0 20 20" fill="currentColor" class="w-3 h-3 flex-none">
            <path d="M11 3a1 1 0 1 0 0 2h2.586l-6.293 6.293a1 1 0 1 0 1.414 1.414L15 6.414V9a1 1 0 1 0 2 0V4a1 1 0 0 0-1-1h-5Z" /><path d="M5 5a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2v-3a1 1 0 1 0-2 0v3H5V7h3a1 1 0 0 0 0-2H5Z" />
          </svg>
        </a>
        <span :if={service_status_text(@svc)} class="text-xs text-blue-400 ml-auto flex-none">
          {service_status_text(@svc)}
        </span>
        <span
          :if={!service_status_text(@svc) && !@first_port && @svc.status == :running}
          class="text-xs text-zinc-500 dark:text-zinc-400 ml-auto font-mono truncate max-w-[100px]"
        >
          {service_detail(@svc)}
        </span>
        <span
          :if={@svc.status == :crashed && @svc.exit_info}
          class="text-xs text-red-500 ml-auto truncate max-w-[140px]"
        >
          {exit_reason(@svc.exit_info)}
        </span>
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
    # `LoopyardWeb.Live.WorkspaceLive.AgentLifecycle.annotate_liveness/1`)
    # and broadcast events keep it coherent. Falling back to a live
    # `Registry.lookup/2` here used to cause a "Sleeping" flash during
    # re-renders triggered by patches — Registry is authoritative, but
    # a compute-at-render-time call can race with a supervisor restart
    # and return `[]` for a microsecond, flipping a Ready dot to gray
    # and back. Prefer the cached `:alive?` flag; only fall back to
    # the Registry lookup for callers that hand us unannotated maps.
    alive? =
      case Map.fetch(agent, :alive?) do
        {:ok, true} -> true
        {:ok, _} -> false
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
    case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
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
    "thinking",
    "pondering",
    "working",
    "contemplating",
    "ruminating",
    "computing",
    "analyzing",
    "reasoning",
    "deliberating",
    "investigating",
    "galavanting",
    "pontificating",
    "abstracting",
    "noodling",
    "scheming",
    "conjuring",
    "percolating",
    "marinating",
    "vibing",
    "manifesting",
    "doin' my thang",
    "cookin'",
    "brewing",
    "churning",
    "crunching",
    "simmering",
    "riffing",
    "jamming",
    "wrangling",
    "spelunking",
    "deciphering",
    "musing",
    "rerouting encryption",
    "mainframing",
    "burning tokens",
    "foxtrotting",
    "beep boop beep boop",
    "reverse engineering gravity",
    "consulting the oracle",
    "asking the magic 8-ball",
    "stacking tokens",
    "defragmenting thoughts",
    "compiling vibes",
    "reticulating splines",
    "makin' bacon",
    "fishing",
    "cruisin'",
    "chillaxing",
    "twirling",
    "whirling"
  ]

  # Tool name → module index, built at compile time from the toolkit.
  # Each tool module defines __busy_words__/0 via the Tool macro.
  @tool_modules Loopyard.Tools.Container.__tool_server__().tools
                |> Enum.into(%{}, fn mod -> {mod.__tool_name__(), mod} end)

  @doc """
  Status word for the sidebar and chat bubble. When the agent has an
  active tool, returns a fun tool-specific phrase from the tool module.
  Falls back to the generic thinking word rotation.
  """
  def thinking_word(agent_id, active_tool \\ nil) do
    tool_name = extract_tool_name(active_tool)
    phrases = tool_busy_words(tool_name)

    words = if phrases != [], do: phrases, else: @thinking_words
    idx = :erlang.phash2({agent_id, div(System.system_time(:second), 3)}, length(words))
    word = Enum.at(words, idx)
    sentence_case(word)
  end

  defp sentence_case(<<first::utf8, rest::binary>>),
    do: <<String.upcase(<<first::utf8>>)::binary, rest::binary>>

  defp sentence_case(other), do: other

  defp tool_busy_words(nil), do: []

  defp tool_busy_words(name) do
    case @tool_modules[name] do
      nil -> []
      mod -> mod.__busy_words__()
    end
  end

  # Strip the MCP server prefix: "mcp__loopyard-container__exec" → "exec"
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
