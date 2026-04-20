defmodule BoomLooperWeb.Live.WorkspaceLive.AgentLifecycle do
  @moduledoc """
  Agent creation and selection — extracted from `BoomLooperWeb.WorkspaceLive`.

  Handles spawning new agents, selecting existing ones, and generating
  auto-names. All functions take and return sockets (or socket-compatible
  tuples).

  This file does NOT subscribe to PubSub or manage GenServer lifecycle
  directly — it delegates to `ChatAgent` and returns updated assigns.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_patch: 2]

  alias BoomLooper.ChatAgent
  alias BoomLooper.StreamBuffer

  @adjectives ~w(Swift Bright Calm Deep Quick Sharp Keen Bold Clear True)
  @nouns ~w(Spark Drift Pulse Wave Bloom Forge Sage Fern Tide Mesa)

  @doc """
  Spawn a new agent for the given workspace. Accepts optional `service_name: name`
  in opts. Returns `{:noreply, socket}`.
  """
  def do_spawn_agent(socket, opts \\ []) do
    workspace = socket.assigns.workspace
    working_dir = workspace.path
    ws_id = BoomLooper.Workspace.workspace_id(working_dir)
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    service_name = Keyword.get(opts, :service_name)

    ws_config =
      case BoomLooper.Workspace.load_from_volume("code-#{ws_id}") do
        {:ok, ws} -> ws
        _ -> nil
      end

    # agent_type: explicit opt > ws_config-aware default (setup if unconfigured, coding otherwise)
    agent_type =
      Keyword.get(opts, :agent_type) ||
        if ws_config, do: "coding", else: "setup"

    name =
      cond do
        service_name -> "#{service_name}-agent"
        ws_config && ws_config.name -> ws_config.name
        true -> auto_name()
      end

    agent_opts = [
      id: id,
      name: name,
      working_dir: working_dir,
      started_by: "browser",
      workspace_id: ws_id,
      agent_type: agent_type
    ]

    # Only set bind_mount if no workspace container exists (pre-setup state).
    # When containers are running, agents use volume-based MCP tools instead.
    agent_opts =
      if BoomLooper.Workspace.container_running?(ws_id),
        do: agent_opts,
        else: agent_opts ++ [bind_mount: working_dir]

    agent_opts = if service_name, do: agent_opts ++ [service_name: service_name], else: agent_opts
    initial_message = Keyword.get(opts, :initial_message)

    boot_opts =
      cond do
        service_name -> [service_name: service_name]
        initial_message -> [initial_message: initial_message]
        true -> [initial_message: :none]
      end

    register_opts = if service_name, do: [service_name: service_name], else: []
    ChatAgent.register_booting(id, name, working_dir, register_opts)
    BoomLooper.AgentBoot.start_monitored(id, agent_opts, boot_opts)

    {:noreply, push_patch(socket, to: "#{socket.assigns.base_path}/agents/#{id}")}
  end

  @doc """
  Select an agent by ID. Unsubscribes from the previous agent, subscribes to
  the new one, and updates all relevant assigns. Returns `{:noreply, socket}`
  or `:not_found`.
  """
  def select_agent(socket, id) do
    # Always unsubscribe from previous AND current agent ID to prevent
    # double subscriptions on mobile reconnect / handle_params re-fire.
    if prev = socket.assigns.selected_id do
      ChatAgent.unsubscribe(prev)
    end
    ChatAgent.unsubscribe(id)

    # Sleeping → wake. If the agent exists in ETS but no GenServer is
    # alive, spawn a new one with resume: true so it rebuilds state
    # from the log. The subsequent get_state below picks up the
    # freshly-running agent.
    maybe_wake_agent(id)

    case ChatAgent.get_state(id) do
      nil ->
        :not_found

      %{status: :booting} = summary ->
        agents = list_workspace_agents(socket.assigns.workspace.path)

        socket =
          socket
          |> assign(:agents, agents)
          |> assign(:selected_id, id)
          |> assign(:selected_agent, nil)
          |> assign(:booting_agent_id, id)
          |> assign(:booting_agent_name, summary.name)
          |> assign(:boot_status, summary[:boot_status] || "Initializing...")
          |> assign(:boot_log, [])

        {:noreply, socket}

      agent ->
        ChatAgent.subscribe(id)
        agents = list_workspace_agents(socket.assigns.workspace.path)
        # Restore stream buffer from any existing :build message so streaming continues seamlessly
        existing_build = Enum.find(agent.messages, &(&1.role == :build))
        stream_buffer = StreamBuffer.restore(existing_build)

        socket =
          socket
          |> assign(:agents, agents)
          |> assign(:selected_id, id)
          |> assign(:selected_agent, agent)
          |> assign(:messages, agent.messages)
          |> assign(:streaming_text, "")
          |> assign(:booting_agent_id, nil)
          |> assign(:stream_buffer, stream_buffer)
          |> assign(:building, existing_build != nil && existing_build.role == :build)

        {:noreply, socket}
    end
  end

  @doc """
  Generate a random two-word agent name.
  """
  def auto_name do
    adj = Enum.random(@adjectives)
    noun = Enum.random(@nouns)
    "#{adj} #{noun}"
  end

  @doc """
  List agents belonging to the given workspace path.

  Each agent is annotated with an `:alive?` flag via a single
  `Registry.lookup/2` at produce-time. The sidebar reads this cached
  flag instead of querying the registry at render time, which used
  to cause a transient "Sleeping" flash when the lookup raced with a
  supervisor restart or momentarily returned `[]` under load.
  """
  def list_workspace_agents(workspace_path) do
    ChatAgent.list_agents()
    |> Enum.filter(fn a ->
      a[:bind_mount] == workspace_path || a[:working_dir] == workspace_path
    end)
    |> Enum.map(&annotate_liveness/1)
  end

  @doc """
  Stamp an agent summary with a cached `:alive?` flag.

  Callers that hand a single updated summary to the UI (PubSub event
  handlers, refresh paths) should run the summary through this before
  assigning, so the sidebar's display status stays stable across
  renders. For the whole-list rebuild path, `list_workspace_agents/1`
  already applies this.
  """
  def annotate_liveness(%{id: id} = agent) do
    alive? =
      case Registry.lookup(BoomLooper.ChatAgentRegistry, id) do
        [{pid, _}] -> Process.alive?(pid)
        _ -> false
      end

    Map.put(agent, :alive?, alive?)
  end

  def annotate_liveness(other), do: other

  # Wake a sleeping agent — agent exists in ETS but its GenServer is gone
  # (server restart without ServiceManager replay, user stopped it, crash).
  # Spawns a new ChatAgent with resume: true; init_resume pulls the rest
  # of the opts (working_dir, bind_mount, workspace_id, agent_type) from
  # the agent's saved ETS entry. No-op if the agent is already running
  # or has no ETS entry at all.
  defp maybe_wake_agent(id) do
    case Registry.lookup(BoomLooper.ChatAgentRegistry, id) do
      [{pid, _}] ->
        if Process.alive?(pid), do: :ok, else: do_wake(id)

      _ ->
        do_wake(id)
    end
  end

  defp do_wake(id) do
    case ChatAgent.get_state(id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        BoomLooper.WorkspaceGroup.start_agent(workspace_id, id: id, resume: true)

      _ ->
        :ok
    end
  end
end
