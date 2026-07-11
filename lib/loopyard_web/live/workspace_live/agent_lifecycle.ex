defmodule LoopyardWeb.Live.WorkspaceLive.AgentLifecycle do
  @moduledoc """
  Agent creation and selection — extracted from `LoopyardWeb.WorkspaceLive`.

  Handles spawning new agents, selecting existing ones, and generating
  auto-names. All functions take and return sockets (or socket-compatible
  tuples).

  This file does NOT subscribe to PubSub or manage GenServer lifecycle
  directly — it delegates to `ChatAgent` and returns updated assigns.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_patch: 2]

  alias Loopyard.ChatAgent
  alias Loopyard.StreamBuffer

  @doc """
  Spawn a new agent for the given workspace. Accepts optional `service_name: name`
  in opts. Returns `{:noreply, socket}`.
  """
  def do_spawn_agent(socket, opts \\ []) do
    ws_id = Loopyard.Workspace.workspace_id(socket.assigns.workspace.path)

    # Delegate to the single backend spawn path (Onboarding.spawn_agent) so the
    # "New agent" button and the fork-provisioning flow build agents identically.
    case Loopyard.Onboarding.spawn_agent(ws_id, Keyword.put(opts, :started_by, "browser")) do
      {:ok, id} ->
        {:noreply, push_patch(socket, to: "#{socket.assigns.base_path}/agents/#{id}")}

      {:error, _reason} ->
        {:noreply, socket}
    end
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
          |> assign_message_page(agent)
          |> assign(:streaming_text, "")
          |> assign(:booting_agent_id, nil)
          |> assign(:stream_buffer, stream_buffer)
          |> assign(:building, existing_build != nil && existing_build.role == :build)

        {:noreply, socket}
    end
  end

  # WINDOWED transcript. The chat is a narrow window into a possibly-huge stream,
  # not the whole thing — an agent with thousands of messages must not blow up
  # the DOM (it was OOM-ing the tab). Load only a batch at the bottom; older
  # loads lazily on scroll-up (may never load); newer drops off the top as the
  # stream grows. `window_tail?` tracks whether the window still includes the
  # live tail — see the load_older / on_message / load_latest handlers.
  #
  # Sourced from the live `get_state` snapshot (prefers the GenServer), not a
  # second ETS read: per-message events only write ETS at turn boundaries, so an
  # ETS read lags the live conversation and is empty right after a resume
  # re-stream — that was the blank chat.
  @message_page_size 60

  defp assign_message_page(socket, agent) do
    msgs = agent[:messages] || []
    page = Enum.take(msgs, -@message_page_size)

    socket
    |> assign(:messages, page)
    |> assign(:has_more_messages, length(page) < length(msgs))
    |> assign(:window_tail?, true)
  end

  @doc "Initial window batch size + the DOM cap, shared with the window handlers."
  def message_page_size, do: @message_page_size
  def message_window_max, do: 160

  @doc """
  List agents belonging to the given workspace path.

  Each agent is annotated with an `:alive?` flag via a single
  `Registry.lookup/2` at produce-time. The sidebar reads this cached
  flag instead of querying the registry at render time, which used
  to cause a transient "Sleeping" flash when the lookup raced with a
  supervisor restart or momentarily returned `[]` under load.
  """
  def list_workspace_agents(workspace_path) do
    # Resolve the workspace_id from the path via ProjectRegistry —
    # agents are associated with workspaces by ID, not path. Filtering
    # by path breaks for every agent whose `working_dir` legitimately
    # differs from the workspace root: container-scoped agents whose
    # `working_dir` is the IN-CONTAINER path (e.g. "/workspace"),
    # agents running from a subdirectory, volume-based workspaces,
    # agents whose bind_mount was omitted. All of those got silently
    # hidden from the sidebar.
    #
    # path → id is a pure ETS lookup; cheap.
    workspace_id = Loopyard.Workspace.workspace_id(workspace_path)

    ChatAgent.list_agents()
    |> Enum.filter(fn a -> a[:workspace_id] == workspace_id end)
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
      case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
        [{pid, _}] -> Process.alive?(pid)
        _ -> false
      end

    Map.put(agent, :alive?, alive?)
  end

  def annotate_liveness(other), do: other

  # Wake a sleeping agent — agent exists in ETS but its GenServer is gone
  # (server restart without ServiceManager replay, user stopped it, crash).
  # Spawns a new ChatAgent with resume: true; init_resume pulls the rest
  # of the opts (working_dir, bind_mount, workspace_id) from
  # the agent's saved ETS entry. No-op if the agent is already running
  # or has no ETS entry at all.
  defp maybe_wake_agent(id) do
    case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
      [{pid, _}] ->
        if Process.alive?(pid), do: :ok, else: do_wake(id)

      _ ->
        do_wake(id)
    end
  end

  defp do_wake(id) do
    case ChatAgent.get_state(id) do
      # Agent is mid-boot (register_booting wrote the stub, AgentBoot
      # hasn't started the GenServer yet). Don't double-start it —
      # that would overwrite the booting ETS row and drop the
      # :boot_status key the UI depends on.
      %{status: :booting} ->
        :ok

      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        Loopyard.WorkspaceGroup.start_agent(workspace_id, id: id, resume: true)

      _ ->
        :ok
    end
  end
end
