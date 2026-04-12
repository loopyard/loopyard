defmodule BoomLooperWeb.Live.ChatLive.AgentLifecycle do
  @moduledoc """
  Agent creation and selection — extracted from `BoomLooperWeb.ChatLive`.

  Handles spawning new agents, selecting existing ones, and generating
  auto-names. All functions take and return sockets (or socket-compatible
  tuples).

  This file does NOT subscribe to PubSub or manage GenServer lifecycle
  directly — it delegates to `ChatAgent` and returns updated assigns.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_navigate: 2]

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
      bind_mount: working_dir,
      workspace_id: ws_id
    ]

    agent_opts = if service_name, do: agent_opts ++ [service_name: service_name], else: agent_opts
    boot_opts = if service_name, do: [service_name: service_name], else: []

    ChatAgent.register_booting(id, name, working_dir, boot_opts)
    Task.Supervisor.start_child(BoomLooper.TaskSupervisor, fn -> BoomLooper.AgentBoot.boot(id, agent_opts, service_name: service_name) end)

    {:noreply, push_navigate(socket, to: "#{socket.assigns.base_path}/agents/#{id}")}
  end

  @doc """
  Spawn the Setup agent for initial workspace configuration.
  Returns `{:noreply, socket}`.
  """
  def spawn_setup_agent(socket) do
    workspace = socket.assigns.workspace
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    name = "Setup"
    ws_id = BoomLooper.Workspace.workspace_id(workspace.path)

    agent_opts = [
      id: id,
      name: name,
      working_dir: workspace.path,
      started_by: "auto_setup",
      bind_mount: workspace.path,
      workspace_id: ws_id
    ]

    ChatAgent.register_booting(id, name, workspace.path)
    Task.Supervisor.start_child(BoomLooper.TaskSupervisor, fn -> BoomLooper.AgentBoot.boot(id, agent_opts) end)

    {:noreply, push_navigate(socket, to: "#{socket.assigns.base_path}/agents/#{id}")}
  end

  @doc """
  Select an agent by ID. Unsubscribes from the previous agent, subscribes to
  the new one, and updates all relevant assigns. Returns `{:noreply, socket}`
  or `:not_found`.
  """
  def select_agent(socket, id) do
    if prev = socket.assigns.selected_id do
      ChatAgent.unsubscribe(prev)
    end

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
  """
  def list_workspace_agents(workspace_path) do
    ChatAgent.list_agents()
    |> Enum.filter(fn a ->
      a[:bind_mount] == workspace_path || a[:working_dir] == workspace_path
    end)
  end
end
