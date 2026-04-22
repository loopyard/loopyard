defmodule BoomLooperWeb.WorkspaceLive do
  use BoomLooperWeb, :live_view
  use BoomLooperWeb.IExAware

  alias BoomLooper.ChatAgent
  alias BoomLooper.Events
  alias BoomLooper.StreamBuffer

  use BoomLooperWeb.Live.WorkspaceLive.Components
  alias BoomLooperWeb.Live.WorkspaceLive.{AgentLifecycle, DiffLoader, FileBrowser, ServiceLogs}

  # Move #3 strict subscriber behaviours — compile-time enforcement that
  # every event published on these topics has a matching callback here.
  # A new event added to any of the publishers shows up as a Dialyzer /
  # `@impl` warning until we wire it in.
  @behaviour BoomLooper.Events.ChatAgent.Subscriber
  @behaviour BoomLooper.Events.ChatAgentMessage.Subscriber
  @behaviour BoomLooper.Events.DockerObserver.Subscriber
  @behaviour BoomLooper.Events.WorkspaceServices.Subscriber
  @behaviour BoomLooper.Events.SourceSync.Subscriber

  @impl true
  def mount(%{"project_id" => project_id, "workspace_id" => workspace_id}, _session, socket) do
    project = BoomLooper.ProjectRegistry.get_project(project_id)
    workspace_entry = BoomLooper.ProjectRegistry.get_workspace(workspace_id)

    unless project && workspace_entry do
      {:ok, push_navigate(socket, to: "/")}
    else
      # workspace_entry is normalized by ProjectRegistry - always has :path
      workspace = %{id: workspace_entry.id, path: workspace_entry.path, name: project.name}
      mount_with_workspace(socket, workspace, %{project: project, workspace_entry: workspace_entry})
    end
  end


  defp mount_with_workspace(socket, workspace, extra_assigns) do
    is_local? = extra_assigns[:project] && extra_assigns[:project][:source_type] == :local

    if connected?(socket) do
      ChatAgent.subscribe()
      BoomLooper.Workspace.ServiceManager.subscribe()
      BoomLooper.Docker.Observer.subscribe()

      # Local workspaces broadcast sync-session state changes on their own
      # PubSub topic; the sidebar shows them in a small "Sync" card.
      if is_local? do
        Phoenix.PubSub.subscribe(
          BoomLooper.PubSub,
          BoomLooper.Source.Local.SyncMonitor.topic(workspace.id)
        )
      end

      # Silent reconnect: if our supervisor tree is already healthy OR
      # there are live containers for this workspace, bring up the
      # supervisor so PubSub + ChatAgent reconnect logic runs. Use
      # workspace_healthy? (not workspace_running?) so a partial
      # group with a dead ServiceManager doesn't count as "running" —
      # that state used to leave the LV stuck at :starting after a
      # failed compose because start_workspace short-circuited on
      # :already_running.
      supervisor_up? = BoomLooper.WorkspaceSupervisor.workspace_healthy?(workspace.id)
      containers_up? = any_running_containers?(workspace.id)

      if supervisor_up? or containers_up? do
        send(self(), {:start_workspace, workspace.path})
      end
    end

    socket = if connected?(socket), do: subscribe_iex(socket), else: assign(socket, :iex_session, %{level: nil})

    # Agents survive server restarts via an append-only ETF log. On a
    # fresh boot the :chat_agents ETS table is empty and list_agents
    # returns []. Pre-populate from the log so the sidebar shows the
    # agent list even before the workspace is started. ChatAgent
    # processes start later (when ServiceManager runs).
    ws_id = extra_assigns[:workspace_entry] && extra_assigns[:workspace_entry].id || workspace.id
    prime_agents_from_log(ws_id)

    # Services + volumes come from Docker.Observer's ETS cache (instant,
    # zero docker calls). The sidebar renders immediately with real data.
    agents = AgentLifecycle.list_workspace_agents(workspace.path)
    {service_statuses, volumes} = load_sidebar_from_observer(workspace.path, ws_id)

    base_path = if extra_assigns[:project] do
      "/projects/#{extra_assigns[:project].id}/workspaces/#{extra_assigns[:workspace_entry].id}"
    else
      "/projects/#{workspace.id}/workspaces/#{workspace.id}"
    end

    host = case socket.host_uri do
      %URI{host: h} when is_binary(h) and h != "" -> h
      _ -> "localhost"
    end

    {:ok,
     socket
     |> assign(:workspace, workspace)
     |> assign(:project, extra_assigns[:project])
     |> assign(:workspace_entry, extra_assigns[:workspace_entry])
     |> assign(:base_path, base_path)
     |> assign(:host, host)
     |> assign(:agents, agents)
     |> assign(:service_statuses, service_statuses)
     |> assign(:services_loaded, true)
     |> assign(:volumes_loaded, true)
     |> assign(:volumes, volumes)
     |> assign(:selected_id, nil)
     |> assign(:selected_agent, nil)
     |> assign(:messages, [])
     |> assign(:streaming_text, "")
     |> assign(:thinking_word, nil)
     |> assign(:tab, :chat)
     |> assign(:container_logs, "")
     |> assign(:container_env, nil)
     |> assign(:container_log_service, nil)
     |> assign(:has_container, false)
     |> assign(:booting_agent_id, nil)
     |> assign(:booting_agent_name, nil)
     |> assign(:boot_status, "Initializing...")
     |> assign(:boot_log, [])
     |> assign(:editing_name, false)
     |> assign(:selected_service, nil)
     |> assign(:selected_volume, nil)
     |> assign(:volume_tab, :info)
     |> assign(:file_tree, nil)
     |> assign(:file_content, nil)
     |> assign(:file_path, nil)
     |> assign(:browse_path, ".")
     |> assign(:git_log, [])
     |> assign(:git_status, [])
     |> assign(:diff_content, nil)
     |> assign(:diff_path, nil)
     |> assign(:commit_detail, nil)
     |> assign(:commit_sha, nil)
     |> assign(:supports_git, false)
     |> assign(:service_logs, "")
     |> assign(:all_service_logs, [])
     |> assign(:stream_buffer, StreamBuffer.new())
     |> assign(:building, false)
     |> assign(:console_container, nil)
     |> assign(:is_local_source?, is_local?)
     |> assign(:sync_status, initial_sync_status(workspace.id, is_local?))
     |> assign(:workspace_state, derive_workspace_state(workspace.id, service_statuses, nil))
     |> assign(:workspace_state_since, DateTime.utc_now())
     |> assign(:docker_connected?, docker_connected?())}
  end

  # The single source of truth for the workspace Start/Stop pill.
  # Returns one of :stopped | :starting | :started | :stopping.
  # Validated against BoomLooper.Cluster.StateMachine so illegal moves
  # (e.g. :stopped → :started without going through :starting) never
  # land in the assigns.
  #
  # `previous` is the assign's current value (or nil on mount). User
  # intent drives transitional states; observer data drives confirmed
  # states:
  #
  #   :starting  + any container up       → :started   (user-start confirmed)
  #   :stopping  + no containers up       → :stopped   (user-stop confirmed)
  #   :starting  + no containers up yet   → :starting  (waiting)
  #   :stopping  + containers still up    → :stopping  (waiting)
  #
  # Without a user-initiated transition in flight, state is derived
  # purely from container reality — any container up means :started,
  # none up means :stopped. The old code had a `supervisor_up? →
  # :running` fallback that lied when compose up failed mid-build:
  # WorkspaceGroup stayed alive (doesn't crash on compose failure)
  # so the UI reported "Running" despite zero containers. Supervisor
  # presence is not equal to "services are up."
  defp derive_workspace_state(_workspace_id, service_statuses, previous) do
    # If the Docker event stream is down, Observer returns an empty
    # container list — not because nothing is running, but because we
    # can't see. Collapsing that into :stopped is the "lying UI" bug
    # from the other direction: it tells the user their services are
    # gone when really they're invisible. Hold the previous state
    # until Docker comes back; the Observer reconnects and fires a
    # fresh :docker_state_changed which re-derives on real data.
    if not docker_connected?() do
      previous || :stopped
    else
      any_running? = Enum.any?(service_statuses, &(&1.status == :running))

      target =
        case previous do
          :starting -> if any_running?, do: :started, else: :starting
          :stopping -> if any_running?, do: :stopping, else: :stopped
          _ -> if any_running?, do: :started, else: :stopped
        end

      # Gate transitions through the state machine. Same-state is a
      # no-op and always legal. Anything illegal falls back to the
      # observable truth (:started or :stopped from any_running?).
      case BoomLooper.Cluster.StateMachine.transition(previous || target, target) do
        {:ok, state} -> state
        {:error, _} -> if any_running?, do: :started, else: :stopped
      end
    end
  end

  defp docker_connected? do
    BoomLooper.Docker.Observer.connected?()
  rescue
    _ -> false
  end

  defp truncate(bin, max) when is_binary(bin) do
    if byte_size(bin) > max, do: binary_part(bin, 0, max) <> "…", else: bin
  end

  defp truncate(other, max), do: other |> inspect() |> truncate(max)

  # Refresh the :selected_agent assign with the agent's latest summary
  # (model, token counts, cost, turns). The context-panel template reads
  # those fields from :selected_agent, but select_agent/2 only runs on
  # mount / click — without this, the panel stays pinned at "awaiting
  # first response" / 0 tokens even as the agent streams through turns.
  # ETS has the current summary courtesy of ChatAgent's on-every-update
  # writes, so this is an O(1) read.
  defp refresh_selected_agent(socket, id) do
    case :ets.lookup(:chat_agents, id) do
      [{^id, summary}] -> assign(socket, :selected_agent, summary)
      _ -> socket
    end
  end

  defp any_running_containers?(workspace_id) do
    BoomLooper.Docker.Observer.containers_for(workspace_id)
    |> Enum.any?(&Map.get(&1, :running, false))
  rescue
    _ -> false
  end

  # Commit a new workspace_state and stamp the entered_at timestamp iff
  # the state actually changed. The sidebar pill reads
  # `:workspace_state_since` to show elapsed time during :starting /
  # :stopping transitions; pinning the timestamp on every same-state
  # broadcast would make "Starting… Ns" counter reset to 0 repeatedly.
  defp transition_workspace_state(socket, new_state) do
    if socket.assigns.workspace_state == new_state do
      socket
    else
      socket
      |> assign(:workspace_state, new_state)
      |> assign(:workspace_state_since, DateTime.utc_now())
    end
  end

  defp initial_sync_status(_workspace_id, false), do: nil

  defp initial_sync_status(workspace_id, true) do
    BoomLooper.Source.Local.SyncMonitor.status(workspace_id)
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: action}} = socket)
      when action in [:chat, :container, :context_panel] do
    tab = case action do
      :container -> :container
      :context_panel -> :context_panel
      _ -> :chat
    end

    socket =
      if socket.assigns.selected_id != id do
        case AgentLifecycle.select_agent(socket, id) do
          {:noreply, s} ->
            clear_flash(s)

          :not_found ->
            socket
            |> put_flash(:error, "Agent not found")
            |> push_patch(to: workspace_path(socket))
        end
      else
        clear_flash(socket)
      end

    socket = assign(socket, :tab, tab)
    socket = if tab == :container, do: fetch_container_data(socket), else: socket
    {:noreply, socket}
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :new}} = socket) do
    # If a Setup agent is already running we just hop to it — this branch
    # is fast (in-memory list scan).
    existing_setup = socket.assigns.agents
      |> Enum.find(fn a -> a[:name] == "Setup" && a[:status] not in [:stopped, :crashed] end)

    cond do
      existing_setup ->
        {:noreply, push_patch(socket, to: "#{workspace_path(socket)}/agents/#{existing_setup.id}")}

      true ->
        # Show the New Agent screen. Setup only runs when the user picks
        # the Setup preset explicitly — no auto-launch on blank workspaces.
        {:noreply, socket}
    end
  end

  def handle_params(%{"service_name" => service_name}, _uri, %{assigns: %{live_action: :service}} = socket) do
    # Fetch logs async so the page loads immediately
    send(self(), {:fetch_service_logs, service_name})
    ServiceLogs.schedule_log_refresh()

    {:noreply,
     socket
     |> assign(:selected_id, nil)
     |> assign(:selected_agent, nil)
     |> assign(:selected_service, service_name)
     |> assign(:service_logs, "Loading logs...")
     |> assign(:all_service_logs, [])}
  end

  def handle_params(%{"service_name" => service_name}, _uri, %{assigns: %{live_action: :console}} = socket) do
    svc = Enum.find(socket.assigns.service_statuses, &(&1.name == service_name))

    # Process containers exec into workspace service (has shell + tools)
    # Stock services exec into their own container
    workspace_id = BoomLooper.ProjectRegistry.workspace_id(socket.assigns.workspace.path)
    container = cond do
      svc && svc.type == :process ->
        BoomLooper.Workspace.ServiceManager.service_container_name(workspace_id, "workspace")
      svc ->
        svc.container
      true ->
        nil
    end

    {:noreply,
     socket
     |> assign(:selected_id, nil)
     |> assign(:selected_agent, nil)
     |> assign(:selected_service, service_name)
     |> assign(:console_container, container)}
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :services}} = socket) do
    send(self(), :fetch_all_service_logs)
    ServiceLogs.schedule_log_refresh()

    {:noreply,
     socket
     |> assign(:selected_id, nil)
     |> assign(:selected_agent, nil)
     |> assign(:selected_service, nil)
     |> assign(:all_service_logs, [])
     |> assign(:service_logs, "")}
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :index}} = socket) do
    # Always reset selection when landing on :index — this is what the
    # mobile back button relies on. Otherwise stale selected_id keeps the
    # sidebar hidden and the user is stuck.
    socket =
      socket
      |> assign(:selected_id, nil)
      |> assign(:selected_agent, nil)
      |> assign(:selected_service, nil)
      |> assign(:tab, :chat)

    {:noreply, socket}
  end

  # Volume info page
  def handle_params(%{"volume_name" => name}, _uri, %{assigns: %{live_action: :volume}} = socket) do
    # Default to files view — more useful than info
    {:noreply, push_patch(socket, to: "#{socket.assigns.base_path}/volumes/#{name}/files")}
  end

  # File browser root: /volumes/:name/files
  def handle_params(%{"volume_name" => name}, _uri, %{assigns: %{live_action: :volume_files_root}} = socket) do
    socket = setup_volume(socket, name, :files)
    {:noreply, FileBrowser.enter_root(socket, name)}
  end

  # File browser: /volumes/:name/files/path/to/thing
  # Could be a file or a directory — FileBrowser probes both and the
  # :file_content handle_async dispatches on the returned shape.
  def handle_params(%{"volume_name" => name, "path" => path_parts}, _uri, %{assigns: %{live_action: :volume_file}} = socket) do
    file_path = Path.join(path_parts)
    socket = setup_volume(socket, name, :files)
    {:noreply, FileBrowser.enter_path(socket, name, file_path)}
  end

  # Git view
  def handle_params(%{"volume_name" => name}, _uri, %{assigns: %{live_action: :volume_git}} = socket) do
    socket = setup_volume(socket, name, :git)

    socket =
      if socket.assigns.git_log == [] do
        git_assigns = Map.take(socket.assigns, [:project, :workspace_entry])
        start_async(socket, :git_data, fn -> load_git_data(git_assigns) end)
      else
        socket
      end

    {:noreply, socket}
  end

  # Git diff for unstaged file
  def handle_params(%{"volume_name" => name, "path" => path_parts}, _uri, %{assigns: %{live_action: :git_diff}} = socket) do
    file_path = Path.join(path_parts)
    socket = setup_volume(socket, name, :git)
    %{project: project, workspace_entry: workspace_entry} = socket.assigns

    {:noreply,
     socket
     |> assign(:diff_content, :loading)
     |> assign(:diff_path, file_path)
     |> start_async(:git_file_diff, fn ->
       DiffLoader.file_diff(project, workspace_entry, file_path, :unstaged)
     end)}
  end

  # Git diff for staged file
  def handle_params(%{"volume_name" => name, "path" => path_parts}, _uri, %{assigns: %{live_action: :git_staged_diff}} = socket) do
    file_path = Path.join(path_parts)
    socket = setup_volume(socket, name, :git)
    %{project: project, workspace_entry: workspace_entry} = socket.assigns

    {:noreply,
     socket
     |> assign(:diff_content, :loading)
     |> assign(:diff_path, file_path)
     |> start_async(:git_file_diff, fn ->
       DiffLoader.file_diff(project, workspace_entry, file_path, :staged)
     end)}
  end

  # Git commit detail
  def handle_params(%{"volume_name" => name, "sha" => sha}, _uri, %{assigns: %{live_action: :git_commit}} = socket) do
    socket = setup_volume(socket, name, :git)
    %{project: project, workspace_entry: workspace_entry} = socket.assigns

    {:noreply,
     socket
     |> assign(:commit_detail, :loading)
     |> assign(:commit_sha, sha)
     |> start_async(:git_commit_detail, fn ->
       DiffLoader.commit_detail(project, workspace_entry, sha)
     end)}
  end

  # Git commit file diff
  def handle_params(%{"volume_name" => name, "sha" => sha, "path" => path_parts}, _uri, %{assigns: %{live_action: :git_commit_file}} = socket) do
    file_path = Path.join(path_parts)
    socket = setup_volume(socket, name, :git)
    %{project: project, workspace_entry: workspace_entry} = socket.assigns

    {:noreply,
     socket
     |> assign(:diff_content, :loading)
     |> assign(:diff_path, file_path)
     |> assign(:commit_sha, sha)
     |> start_async(:git_file_diff, fn ->
       DiffLoader.commit_file_diff(project, workspace_entry, sha, file_path)
     end)}
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :sync}} = socket) do
    {:noreply,
     socket
     |> assign(:selected_id, nil)
     |> assign(:selected_agent, nil)
     |> assign(:selected_service, nil)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, :tab, :chat)}

  @impl true
  def handle_async({:container_data, id}, {:ok, result}, socket) do
    # Discard if the user has switched to a different agent in the meantime.
    if socket.assigns.selected_id == id do
      {:noreply,
       socket
       |> assign(:container_logs, result.logs)
       |> assign(:container_env, result.env)
       |> assign(:has_container, result.has_container)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:container_data, _}, {:exit, _reason}, socket) do
    {:noreply, socket}
  end

  def handle_async(:file_tree, {:ok, {:ok, entries}}, socket) do
    {:noreply, assign(socket, :file_tree, entries)}
  end

  def handle_async(:file_tree, {:ok, {:error, _reason}}, socket) do
    {:noreply, assign(socket, :file_tree, [])}
  end

  def handle_async(:file_tree, {:exit, _reason}, socket) do
    {:noreply, assign(socket, :file_tree, [])}
  end

  # File read succeeded — show the file
  def handle_async(:file_content, {:ok, %{content: content, path: path}}, socket) when is_binary(content) do
    {:noreply, socket |> assign(:file_content, content) |> assign(:file_path, path)}
  end

  # Path was a directory, not a file — show directory listing instead
  def handle_async(:file_content, {:ok, %{is_dir: true, path: path, entries: entries}}, socket) do
    {:noreply,
     socket
     |> assign(:file_content, nil)
     |> assign(:file_path, nil)
     |> assign(:browse_path, path)
     |> assign(:file_tree, entries)}
  end

  # File not found
  def handle_async(:file_content, {:ok, %{not_found: true, path: path}}, socket) do
    {:noreply, socket |> assign(:file_content, "File not found: #{path}") |> assign(:file_path, path)}
  end

  def handle_async(:file_content, {:exit, _reason}, socket) do
    {:noreply, assign(socket, :file_content, nil)}
  end

  def handle_async(:git_data, {:ok, {log_result, status_result}}, socket) do
    git_log = case log_result do
      {:ok, entries} -> entries
      _ -> []
    end

    git_status = case status_result do
      {:ok, entries} -> entries
      _ -> []
    end

    {:noreply, socket |> assign(:git_log, git_log) |> assign(:git_status, git_status)}
  end

  def handle_async(:git_data, {:exit, _reason}, socket) do
    {:noreply, socket}
  end

  def handle_async(:diff_content, {:ok, content}, socket) when is_binary(content) do
    {:noreply, assign(socket, :diff_content, content)}
  end

  def handle_async(:diff_content, {:exit, _reason}, socket) do
    {:noreply, socket}
  end

  def handle_async(:git_file_diff, {:ok, diff}, socket) when is_binary(diff) do
    {:noreply, assign(socket, :diff_content, diff)}
  end

  def handle_async(:git_file_diff, _, socket) do
    {:noreply, assign(socket, :diff_content, "(could not load diff)")}
  end

  def handle_async(:git_commit_detail, {:ok, commit}, socket) when is_map(commit) do
    {:noreply, assign(socket, :commit_detail, commit)}
  end

  def handle_async(:git_commit_detail, _, socket) do
    {:noreply, assign(socket, :commit_detail, nil)}
  end

  # --- Events ---

  @impl true
  def handle_event("select_agent", %{"id" => id}, socket) do
    tab = socket.assigns.tab
    bp = workspace_path(socket)
    path = if tab == :container, do: "#{bp}/agents/#{id}/container", else: "#{bp}/agents/#{id}"
    {:noreply, push_patch(socket, to: path) |> push_event("focus_input", %{})}
  end

  @impl true
  def handle_event("spawn_agent_with_message", %{"preset" => preset}, socket) do
    AgentLifecycle.do_spawn_agent(socket,
      initial_message: preset_message(preset),
      agent_type: preset_agent_type(preset)
    )
  end

  def handle_event("spawn_agent_with_message", %{"message" => message}, socket) do
    message = String.trim(message)
    opts = if message == "", do: [], else: [initial_message: message]
    AgentLifecycle.do_spawn_agent(socket, opts)
  end

  def handle_event("spawn_agent", _params, socket) do
    AgentLifecycle.do_spawn_agent(socket)
  end

  @impl true
  def handle_event("spawn_service_agent", %{"service_name" => service_name}, socket) do
    AgentLifecycle.do_spawn_agent(socket, service_name: service_name)
  end

  @impl true
  def handle_event("send_message", %{"message" => message}, socket) do
    message = String.trim(message)

    if message != "" && socket.assigns.selected_id do
      # Don't add optimistically — let PubSub broadcast handle it for ALL viewers.
      # This ensures multiplayer: every viewer (including the sender) sees the
      # message via the same path.
      ChatAgent.send_message(socket.assigns.selected_id, message)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("restart_session", %{"id" => id}, socket) do
    ChatAgent.restart_session(id)
    {:noreply, socket}
  end

  @impl true
  def handle_event("stop_agent", %{"id" => id}, socket) do
    ChatAgent.stop_agent(id)
    {:noreply, socket}
  end

  @impl true
  def handle_event("remove_agent", %{"id" => id}, socket) do
    ChatAgent.remove_agent(id)
    {:noreply, socket}
  end

  @impl true
  def handle_event("start_agent", %{"id" => id}, socket) do
    case ChatAgent.start_agent(id) do
      :ok ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not start agent: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("toggle_port_exposure", %{"service" => svc_name, "container_port" => cport, "expose" => expose}, socket) do
    workspace_id = socket.assigns.workspace.id
    cport = String.to_integer(cport)
    exposed? = expose == "true"

    case BoomLooper.PortRegistry.set_exposure(workspace_id, svc_name, cport, exposed?) do
      :ok ->
        # Surgical update: patch ONLY the toggled service's :exposed
        # flag in assigns. Re-running load_sidebar_from_observer here
        # re-renders every service and briefly shows the fallback
        # annotation path, which is what made the port button flicker
        # off then on.
        updated =
          Enum.map(socket.assigns.service_statuses, fn s ->
            if s.name == svc_name, do: Map.put(s, :exposed, exposed?), else: s
          end)

        # Route through guard_service_statuses even though `updated`
        # is a map over the existing list and can't go empty —
        # keeps the invariant uniform.
        {:noreply, assign(socket, :service_statuses, guard_service_statuses(socket, updated))}

      {:error, reason} ->
        require Logger
        Logger.warning("[workspace_live] toggle_port_exposure failed: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("start_rename", _params, socket) do
    {:noreply, assign(socket, :editing_name, true)}
  end

  @impl true
  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, :editing_name, false)}
  end

  @impl true
  def handle_event("rename_agent", %{"name" => name}, socket) do
    if socket.assigns.selected_id && String.trim(name) != "" do
      ChatAgent.rename(socket.assigns.selected_id, String.trim(name))
    end

    {:noreply, assign(socket, :editing_name, false)}
  end

  @impl true
  # --- UI state events ---

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab = case tab do
      "chat" -> :chat
      "container" -> :container
      _ -> :chat
    end
    bp = workspace_path(socket)

    path =
      case {socket.assigns.selected_id, tab} do
        {nil, _} -> bp
        {id, :container} -> "#{bp}/agents/#{id}/container"
        {id, _} -> "#{bp}/agents/#{id}"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  # --- Source-adapter sync events (Local/Mutagen) ---

  def handle_event("sync_restart", %{"workspace-id" => ws_id}, socket) do
    case BoomLooper.Source.Local.SyncMonitor.whereis(ws_id) do
      nil ->
        # No SyncMonitor running — update the card to show the real state
        {:noreply, assign(socket, :sync_status, %{status: :stopped, last_error: "No sync process — workspace container may not be running", last_checked_at: DateTime.utc_now()})}

      _pid ->
        BoomLooper.Source.Local.SyncMonitor.restart(ws_id)
        # Immediately show "starting" so the button feels responsive
        {:noreply, assign(socket, :sync_status, %{status: :starting, last_error: nil, last_checked_at: DateTime.utc_now()})}
    end
  end

  def handle_event("sync_pause", %{"workspace-id" => ws_id}, socket) do
    BoomLooper.Source.Local.SyncMonitor.pause(ws_id)
    {:noreply, socket}
  end

  def handle_event("sync_resume", %{"workspace-id" => ws_id}, socket) do
    BoomLooper.Source.Local.SyncMonitor.resume(ws_id)
    {:noreply, socket}
  end

  # --- Cluster events (Docker Compose + volumes) ---

  def handle_event("restart_service", %{"service_name" => name}, socket) do
    run_compose_async(socket, ["restart", name], 30_000)
  end

  def handle_event("start_service", %{"service_name" => name}, socket) do
    # `up -d <service>` brings a stopped/crashed service back without
    # touching the rest of the compose project. `restart` is a no-op
    # on a non-running container, which is why the single-button
    # "Restart" was the wrong call to show in the log view when the
    # service isn't running.
    run_compose_async(socket, ["up", "-d", name], 60_000)
  end

  def handle_event("stop_service", %{"service_name" => name}, socket) do
    run_compose_async(socket, ["stop", name], 30_000)
  end

  def handle_event("boot_workspace", _params, socket) do
    # Flip to :starting immediately so the UI shows the transitional
    # state. The actual start runs async — observer events will flip
    # us to :started when containers come up.
    send(self(), {:start_workspace, socket.assigns.workspace.path})
    {:noreply, transition_workspace_state(socket, :starting)}
  end

  @impl true
  def handle_event("shutdown_workspace", _params, socket) do
    ws_id = socket.assigns.workspace.id
    parent = self()

    # Real stop: compose down (containers actually exit), THEN tear
    # down our supervisor tree. Previously we only stopped the
    # supervisor, which left containers running — the UI would show
    # "Stopped" then flicker back to "Running" on the next observer
    # tick because nothing had actually stopped.
    Task.Supervisor.start_child(BoomLooper.TaskSupervisor, fn ->
      effective_dir = BoomLooper.Workspace.compose_dir(ws_id)
      BoomLooper.Compose.down(effective_dir, ws_id)
      BoomLooper.WorkspaceSupervisor.stop_workspace(ws_id)
      BoomLooper.ProjectRegistry.update_workspace_status(ws_id, :stopped)
      BoomLooper.Docker.Observer.poll_now()
      send(parent, :workspace_stopped)
    end)

    {:noreply, transition_workspace_state(socket, :stopping)}
  end

  @impl true


  def handle_event("delete_volume", %{"volume_name" => name}, socket) do
    BoomLooper.Docker.docker(["volume", "rm", name])
    BoomLooper.Docker.Observer.poll_now()
    {:noreply, push_patch(socket, to: workspace_path(socket))}
  end


  # --- Git diff viewer events ---

  def handle_event("view_diff", %{"path" => path}, socket) do
    %{project: project, workspace_entry: workspace_entry} = socket.assigns

    {:noreply,
     start_async(socket, :diff_content, fn ->
       DiffLoader.working_file_diff(project, workspace_entry, path)
     end)}
  end

  def handle_event("view_commit", %{"sha" => sha}, socket) do
    %{project: project, workspace_entry: workspace_entry} = socket.assigns

    {:noreply,
     start_async(socket, :diff_content, fn ->
       DiffLoader.commit_diff(project, workspace_entry, sha)
     end)}
  end

  def handle_event("close_diff", _params, socket) do
    {:noreply, assign(socket, :diff_content, nil)}
  end

  # --- Container view events ---

  def handle_event("refresh_container", _params, socket) do
    {:noreply, fetch_container_data(socket)}
  end

  @impl true
  def handle_event("filter_container_service", %{"service" => service}, socket) do
    service = if service == "", do: nil, else: service
    socket = assign(socket, :container_log_service, service)
    {:noreply, fetch_container_data(socket)}
  end

  # --- PubSub ---
  #
  # Every PubSub broadcast we subscribe to arrives as a typed struct from
  # BoomLooper.Events.*. The handle_info clauses below are two-line
  # dispatches to the on_* callbacks declared by each Subscriber behaviour
  # — missing callbacks compile-warn, so new events forced us to wire them
  # explicitly or justify the drop. Per plans/coordination-hardening.md
  # Move #3, each LV writes its own dispatch (no macro magic).

  @impl true
  def handle_info(%Events.ChatAgent.Started{} = e, socket), do: on_started(e, socket)
  def handle_info(%Events.ChatAgent.Resumed{} = e, socket), do: on_resumed(e, socket)
  def handle_info(%Events.ChatAgent.Booting{} = e, socket), do: on_booting(e, socket)
  def handle_info(%Events.ChatAgent.BootStatus{} = e, socket), do: on_boot_status(e, socket)
  def handle_info(%Events.ChatAgent.BootFailed{} = e, socket), do: on_boot_failed(e, socket)
  def handle_info(%Events.ChatAgent.Stopped{} = e, socket), do: on_stopped(e, socket)
  def handle_info(%Events.ChatAgent.Removed{} = e, socket), do: on_removed(e, socket)
  def handle_info(%Events.ChatAgent.Renamed{} = e, socket), do: on_renamed(e, socket)
  def handle_info(%Events.ChatAgent.StatusChanged{} = e, socket), do: on_status_changed(e, socket)
  # Quarantine / release aren't rendered here (SystemQuarantineLive owns
  # that surface) but we subscribe to the "chat_agents" topic so the
  # behaviour forces us to acknowledge them explicitly instead of letting
  # them slip into a catch-all.
  def handle_info(%Events.ChatAgent.Quarantined{} = e, socket), do: on_quarantined(e, socket)
  def handle_info(%Events.ChatAgent.Released{} = e, socket), do: on_released(e, socket)

  def handle_info(%Events.ChatAgentMessage.Message{} = e, socket), do: on_message(e, socket)
  def handle_info(%Events.ChatAgentMessage.TextDelta{} = e, socket), do: on_text_delta(e, socket)
  def handle_info(%Events.ChatAgentMessage.StreamOutput{} = e, socket), do: on_stream_output(e, socket)

  def handle_info(%Events.DockerObserver.Changed{} = e, socket), do: on_changed(e, socket)
  def handle_info(%Events.DockerObserver.Reset{} = e, socket), do: on_reset(e, socket)
  def handle_info(%Events.DockerObserver.Disconnected{} = e, socket), do: on_disconnected(e, socket)
  def handle_info(%Events.DockerObserver.Reconnected{} = e, socket), do: on_reconnected(e, socket)

  def handle_info(%Events.WorkspaceServices.ServicesUpdated{} = e, socket), do: on_services_updated(e, socket)
  def handle_info(%Events.WorkspaceServices.ComposeResult{} = e, socket), do: on_compose_result(e, socket)

  def handle_info(%Events.SourceSync.Updated{} = e, socket), do: on_updated(e, socket)

  # Non-PubSub internal messages (send/2 self-dispatches, async task
  # replies). These aren't subject to the publisher-module boundary
  # because they never leave this process.

  def handle_info(:workspace_stopped, socket) do
    ws_id = socket.assigns.workspace_entry && socket.assigns.workspace_entry.id || socket.assigns.workspace.id
    {service_statuses, volumes} = load_sidebar_from_observer(nil, ws_id)

    # Intentional empty replacement on :workspace_stopped — workspace
    # stopped, no services. The guard_service_statuses guard exists to
    # prevent ACCIDENTAL flapping from non-empty to empty. This is
    # deliberate, so we bypass the guard with force_assign_service_statuses.
    {:noreply,
     socket
     |> transition_workspace_state(:stopped)
     |> force_assign_service_statuses(service_statuses)
     |> assign(:volumes, volumes)
     |> assign(:agents, [])}
  end

  def handle_info({:start_workspace, path}, socket) do
    workspace_id = BoomLooper.ProjectRegistry.workspace_id(path)

    # Start workspace in a Task so it doesn't block the LiveView. The
    # supervisor start triggers compose up inside ServiceManager.
    # Subsequent DockerObserver.Changed events flip us from :starting → :running.
    Task.Supervisor.start_child(BoomLooper.TaskSupervisor, fn ->
      BoomLooper.WorkspaceSupervisor.start_workspace(workspace_id, path)
      BoomLooper.ProjectRegistry.update_workspace_status(workspace_id, :running)
      BoomLooper.Docker.Observer.poll_now()
    end)

    {:noreply, socket}
  end

  def handle_info({:build_output, id, data}, socket) when id == socket.assigns.selected_id do
    upsert_stream_message(socket, data, "Building Docker image...", nil)
  end

  def handle_info({:fetch_service_logs, service_name}, socket) do
    ws_id = socket.assigns.workspace_entry && socket.assigns.workspace_entry.id || socket.assigns.workspace.id
    {:noreply, ServiceLogs.start_service_logs_fetch(socket, ws_id, service_name)}
  end

  def handle_info(:fetch_all_service_logs, socket) do
    ws_id = socket.assigns.workspace_entry && socket.assigns.workspace_entry.id || socket.assigns.workspace.id
    {:noreply, ServiceLogs.start_all_service_logs_fetch(socket, ws_id)}
  end

  def handle_info(:refresh_service_logs, socket) do
    ws_id = socket.assigns.workspace_entry && socket.assigns.workspace_entry.id || socket.assigns.workspace.id

    case socket.assigns.live_action do
      :service ->
        ServiceLogs.schedule_log_refresh()
        {:noreply, ServiceLogs.start_service_logs_fetch(socket, ws_id, socket.assigns.selected_service)}

      :services ->
        ServiceLogs.schedule_log_refresh()
        {:noreply, ServiceLogs.start_all_service_logs_fetch(socket, ws_id)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:service_logs_fetched, service_name, logs}, socket) do
    # Intentionally does NOT touch service_statuses. The log fetch task
    # used to ship the raw (un-annotated) service list back alongside the
    # logs, and assigning it here wiped the annotated host_port/exposed/
    # container_port fields — causing the port button to flash off every
    # 3s until the next docker_state_changed re-annotated. The LV's own
    # assigns are already fresh via docker_state_changed broadcasts.
    socket =
      if socket.assigns[:selected_service] == service_name do
        assign(socket, :service_logs, logs)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:all_service_logs_fetched, all_logs}, socket) do
    # Same rule: logs only, don't clobber annotated service_statuses.
    {:noreply, assign(socket, :all_service_logs, all_logs)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- ChatAgent subscriber callbacks ---

  @impl Events.ChatAgent.Subscriber
  def on_started(%Events.ChatAgent.Started{summary: agent_summary}, socket) do
    socket = assign(socket, :agents, AgentLifecycle.list_workspace_agents(socket.assigns.workspace.path))

    if socket.assigns.booting_agent_id && agent_summary.id == socket.assigns.booting_agent_id do
      socket = assign(socket, :booting_agent_id, nil)

      if socket.assigns.selected_id == agent_summary.id do
        case AgentLifecycle.select_agent(socket, agent_summary.id) do
          {:noreply, s} -> {:noreply, s}
          :not_found -> {:noreply, socket}
        end
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl Events.ChatAgent.Subscriber
  def on_resumed(%Events.ChatAgent.Resumed{summary: summary}, socket) do
    # Resume = an agent supervisor (re)started the GenServer after a
    # crash or log replay. Without this handler the sidebar would
    # latch at whatever `:chat_agent_status_changed` last said — often
    # `:crashed` — even though the new GenServer is alive and idle.
    # That's the "it says Sleeping but the agent is actually up" bug.
    annotated = AgentLifecycle.annotate_liveness(summary)

    agents =
      Enum.map(socket.assigns.agents, fn a ->
        if a.id == summary.id, do: annotated, else: a
      end)

    socket = assign(socket, :agents, agents)

    socket =
      if summary.id == socket.assigns.selected_id do
        refresh_selected_agent(socket, summary.id)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl Events.ChatAgent.Subscriber
  def on_booting(%Events.ChatAgent.Booting{summary: summary}, socket) do
    {:noreply, assign(socket, :agents, AgentLifecycle.list_workspace_agents(socket.assigns.workspace.path))
     |> then(fn s ->
       if s.assigns.selected_id == summary.id do
         assign(s, booting_agent_id: summary.id, booting_agent_name: summary.name, boot_status: summary[:boot_status] || "Initializing...", boot_log: [])
       else
         s
       end
     end)}
  end

  @impl Events.ChatAgent.Subscriber
  def on_boot_status(%Events.ChatAgent.BootStatus{id: id, status: status_text}, socket) do
    agents =
      Enum.map(socket.assigns.agents, fn a ->
        if a.id == id, do: Map.put(a, :boot_status, status_text), else: a
      end)

    socket = assign(socket, :agents, agents)

    socket =
      if socket.assigns.booting_agent_id == id do
        socket
        |> assign(:boot_status, status_text)
        |> update(:boot_log, &(&1 ++ [status_text]))
      else
        socket
      end

    {:noreply, socket}
  end

  @impl Events.ChatAgent.Subscriber
  def on_boot_failed(%Events.ChatAgent.BootFailed{id: id, reason: reason}, socket) do
    socket = assign(socket, :agents, AgentLifecycle.list_workspace_agents(socket.assigns.workspace.path))

    socket =
      if socket.assigns.booting_agent_id == id || socket.assigns.selected_id == id do
        socket
        |> assign(:booting_agent_id, nil)
        |> put_flash(:error, "Failed to start agent: #{inspect(reason)}")
        |> push_patch(to: workspace_path(socket))
      else
        socket
      end

    {:noreply, socket}
  end

  @impl Events.ChatAgent.Subscriber
  def on_stopped(%Events.ChatAgent.Stopped{}, socket) do
    agents = AgentLifecycle.list_workspace_agents(socket.assigns.workspace.path)

    {:noreply,
     socket
     |> assign(:agents, agents)
     |> refresh_selected_agent(socket.assigns.selected_id)}
  end

  @impl Events.ChatAgent.Subscriber
  def on_removed(%Events.ChatAgent.Removed{id: id}, socket) do
    socket = assign(socket, :agents, AgentLifecycle.list_workspace_agents(socket.assigns.workspace.path))

    socket =
      if socket.assigns.selected_id == id do
        assign(socket, selected_id: nil, selected_agent: nil, messages: [])
      else
        socket
      end

    {:noreply, socket}
  end

  @impl Events.ChatAgent.Subscriber
  def on_renamed(%Events.ChatAgent.Renamed{id: id, name: new_name}, socket) do
    agents =
      Enum.map(socket.assigns.agents, fn a ->
        if a.id == id, do: %{a | name: new_name}, else: a
      end)

    socket = assign(socket, :agents, agents)

    socket =
      if id == socket.assigns.selected_id do
        # Pull the fresh summary from ETS — not the stale copy in
        # the sidebar list. Otherwise we clobber the live token/cost
        # counts every time an agent is renamed.
        refresh_selected_agent(socket, id)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl Events.ChatAgent.Subscriber
  def on_status_changed(%Events.ChatAgent.StatusChanged{id: id, status: status}, socket) do
    # Compute thinking word ONCE per status change
    active_tool =
      case Enum.find(socket.assigns.agents, &(&1.id == id)) do
        %{active_tool: t} -> t
        _ -> nil
      end

    word =
      if status in [:thinking, :booting, :backoff],
        do: BoomLooperWeb.Components.Sidebar.thinking_word(id, active_tool),
        else: nil

    agents =
      Enum.map(socket.assigns.agents, fn a ->
        if a.id == id do
          a |> Map.put(:status, status) |> Map.put(:thinking_word, word) |> AgentLifecycle.annotate_liveness()
        else
          a
        end
      end)

    socket = assign(socket, :agents, agents)
    socket = assign(socket, :thinking_word, word)

    socket =
      if id == socket.assigns.selected_id do
        refresh_selected_agent(socket, id)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl Events.ChatAgent.Subscriber
  def on_quarantined(%Events.ChatAgent.Quarantined{}, socket) do
    # Quarantine UI lives on /system/quarantine. The workspace sidebar
    # already reflects the :crashed status that accompanies it via the
    # separate StatusChanged event, so nothing to do here.
    {:noreply, socket}
  end

  @impl Events.ChatAgent.Subscriber
  def on_released(%Events.ChatAgent.Released{}, socket) do
    # Release clears the quarantine flag; the subsequent Resumed or
    # StatusChanged event is what updates the sidebar.
    {:noreply, socket}
  end

  # --- ChatAgentMessage subscriber callbacks ---

  @impl Events.ChatAgentMessage.Subscriber
  def on_message(%Events.ChatAgentMessage.Message{agent_id: id, msg: msg}, socket) when id == socket.assigns.selected_id do
    # Guard against duplicate messages (mobile reconnect can cause double PubSub subscriptions)
    if msg[:id] && Enum.any?(socket.assigns.messages, &(&1[:id] == msg[:id])) do
      {:noreply, socket}
    else
      socket = if msg.role == :assistant, do: assign(socket, :streaming_text, ""), else: socket

      # If build was running and we get a post-build message, mark build as done
      socket =
        if socket.assigns.building && msg.role in [:system, :error] do
          messages = Enum.map(socket.assigns.messages, fn
            %{role: :build} = m -> %{m | role: :build_done}
            other -> other
          end)
          socket |> assign(:messages, messages) |> assign(:building, false)
        else
          socket
        end

      socket =
        socket
        |> assign(:messages, socket.assigns.messages ++ [msg])
        |> refresh_selected_agent(id)
        |> push_event("scroll_bottom", %{})

      # Update thinking word when a tool message arrives — shows the
      # tool-specific phrase (e.g., "grepping" instead of "pondering")
      socket =
        if msg.role == :tool && socket.assigns.selected_agent && socket.assigns.selected_agent.status == :thinking do
          tool = msg[:tool]
          word = BoomLooperWeb.Components.Sidebar.thinking_word(id, tool)
          assign(socket, :thinking_word, word)
        else
          socket
        end

      {:noreply, socket}
    end
  end

  def on_message(%Events.ChatAgentMessage.Message{}, socket), do: {:noreply, socket}

  @impl Events.ChatAgentMessage.Subscriber
  def on_text_delta(%Events.ChatAgentMessage.TextDelta{agent_id: id, text: text}, socket) when id == socket.assigns.selected_id do
    # Piggyback on delta events to keep :selected_agent fresh even when
    # status transitions don't emit their own broadcast. Costs an ETS
    # lookup per streamed chunk — cheap, and LiveView's assign diffing
    # elides the render when the summary hasn't actually changed.
    {:noreply,
     socket
     |> refresh_selected_agent(id)
     |> assign(:streaming_text, socket.assigns.streaming_text <> text)
     |> push_event("scroll_bottom", %{})}
  end

  def on_text_delta(%Events.ChatAgentMessage.TextDelta{}, socket), do: {:noreply, socket}

  @impl Events.ChatAgentMessage.Subscriber
  def on_stream_output(%Events.ChatAgentMessage.StreamOutput{agent_id: id, data: data, title: title, msg_id: msg_id}, socket) when id == socket.assigns.selected_id do
    upsert_stream_message(socket, data, title, msg_id)
  end

  def on_stream_output(%Events.ChatAgentMessage.StreamOutput{}, socket), do: {:noreply, socket}

  # --- DockerObserver subscriber callbacks ---

  # Docker.Observer broadcasts when container/volume state changes.
  # Re-derive sidebar state from the cache — zero docker calls.
  @impl Events.DockerObserver.Subscriber
  def on_changed(%Events.DockerObserver.Changed{}, socket) do
    ws_id = socket.assigns.workspace_entry && socket.assigns.workspace_entry.id || socket.assigns.workspace.id
    {service_statuses, volumes} = load_sidebar_from_observer(nil, ws_id)
    guarded = guard_service_statuses(socket, service_statuses)
    new_state = derive_workspace_state(ws_id, guarded, socket.assigns.workspace_state)

    {:noreply,
     socket
     |> assign(:service_statuses, guarded)
     |> assign(:volumes, volumes)
     |> transition_workspace_state(new_state)}
  end

  # Observer cache wiped (≥ stale_cache_threshold consecutive fetch
  # failures) or initial bootstrap failure. Re-read from ETS so the
  # sidebar reflects the empty cache; otherwise it'd keep showing
  # services/volumes that are no longer authoritative.
  @impl Events.DockerObserver.Subscriber
  def on_reset(%Events.DockerObserver.Reset{}, socket) do
    ws_id = socket.assigns.workspace_entry && socket.assigns.workspace_entry.id || socket.assigns.workspace.id
    {service_statuses, volumes} = load_sidebar_from_observer(nil, ws_id)
    guarded = guard_service_statuses(socket, service_statuses)

    {:noreply,
     socket
     |> assign(:service_statuses, guarded)
     |> assign(:volumes, volumes)}
  end

  # Event stream to Docker died — cache is retained but now stale.
  # Flip the connectivity flag so the sidebar's "Docker disconnected"
  # badge renders. `derive_workspace_state` holds the previous state
  # during the disconnect window, so the Start/Stop button stays sane.
  @impl Events.DockerObserver.Subscriber
  def on_disconnected(%Events.DockerObserver.Disconnected{}, socket) do
    {:noreply, assign(socket, :docker_connected?, false)}
  end

  # Stream back. Flip the flag and let the next Changed event (which the
  # reconnect bootstrap always emits after its snapshot) refresh the
  # sidebar.
  @impl Events.DockerObserver.Subscriber
  def on_reconnected(%Events.DockerObserver.Reconnected{}, socket) do
    {:noreply, assign(socket, :docker_connected?, true)}
  end

  # --- WorkspaceServices subscriber callbacks ---

  # ServiceManager fires this when a compose up/down attempt has
  # completed — success OR definitive failure. Without this, a compose
  # up that bombed out during build (missing Dockerfile, etc.) would
  # leave the LV pinned at :starting forever: the Changed pathway never
  # flips us to :started (no containers come up) and there's no other
  # signal saying "give up." This is the signal.
  @impl Events.WorkspaceServices.Subscriber
  def on_compose_result(%Events.WorkspaceServices.ComposeResult{workspace_id: workspace_id, result: result}, socket) do
    ws = socket.assigns.workspace
    ws_entry = socket.assigns[:workspace_entry]
    our_id = (ws_entry && ws_entry.id) || ws.id

    if workspace_id == our_id do
      target =
        case {socket.assigns.workspace_state, result} do
          {:starting, :ok} -> :started
          {:starting, {:error, _}} -> :stopped
          {:stopping, :ok} -> :stopped
          {:stopping, {:error, _}} -> :started
          _ -> socket.assigns.workspace_state
        end

      socket =
        case result do
          {:error, reason} ->
            put_flash(socket, :error, "Cluster didn't start: #{truncate(reason, 200)}")

          :ok ->
            socket
        end

      {:noreply, transition_workspace_state(socket, target)}
    else
      {:noreply, socket}
    end
  end

  @impl Events.WorkspaceServices.Subscriber
  def on_services_updated(%Events.WorkspaceServices.ServicesUpdated{path: path}, socket) do
    # ServiceManager broadcasts on canonical_dir (host path) or project_dir
    # (virtual dir). Match either against our workspace's known paths.
    ws = socket.assigns.workspace
    ws_entry = socket.assigns[:workspace_entry]

    matches = path == ws.path or
      (ws_entry && path == ws_entry[:path]) or
      (ws_entry && path == ws_entry[:compose_dir])

    if matches do
      ws_id = ws_entry && ws_entry.id || ws.id
      {service_statuses, _volumes} = load_sidebar_from_observer(path, ws_id)

      {:noreply, assign(socket, :service_statuses, guard_service_statuses(socket, service_statuses))}
    else
      {:noreply, socket}
    end
  end

  # --- SourceSync subscriber callbacks ---

  @impl Events.SourceSync.Subscriber
  def on_updated(%Events.SourceSync.Updated{workspace_id: ws_id, status: status}, socket) do
    if ws_id == socket.assigns.workspace.id do
      {:noreply, assign(socket, :sync_status, status)}
    else
      {:noreply, socket}
    end
  end

  # Never replace a non-empty service list with []. During Observer cache
  # wipes, compose file syncs, or async task races, the new list can be
  # temporarily empty. Showing an empty sidebar and then refilling it a
  # moment later is the "flapping" bug. Keep the last known good state.
  # Compose commands can take tens of seconds (restart/stop) to minutes
  # (start with image build). Running them inline in handle_event used
  # to block this LV — pending PubSub messages, other user events, all
  # queued for the duration. The docker_events stream picks up the
  # container transition and broadcasts :docker_state_changed when the
  # async task completes, so the sidebar updates without us waiting on
  # the Task result here. Fire and forget.
  defp run_compose_async(socket, args, timeout) do
    ws_id = socket.assigns.workspace_entry.id
    effective_dir = BoomLooper.Workspace.compose_dir(ws_id)

    Task.Supervisor.start_child(BoomLooper.TaskSupervisor, fn ->
      BoomLooper.Compose.compose(effective_dir, ws_id, args, timeout: timeout)
    end)

    {:noreply, socket}
  end

  defp guard_service_statuses(socket, new_statuses) do
    if new_statuses == [] and socket.assigns.service_statuses != [] do
      socket.assigns.service_statuses
    else
      new_statuses
    end
  end

  # Explicit bypass for the guard when empty is legitimately the new
  # truth (e.g. :workspace_stopped). Exists as a named function
  # instead of a raw assign so the invariants test recognizes it as
  # an intentional-empty site and doesn't flag it as unguarded drift.
  defp force_assign_service_statuses(socket, new_statuses) do
    assign(socket, :service_statuses, new_statuses)
  end

  # --- Private ---

  defp upsert_stream_message(socket, data, title, msg_id) do
    stream_buffer = socket.assigns.stream_buffer
      |> StreamBuffer.append(data, title: title, msg_id: msg_id)

    messages = StreamBuffer.upsert_message(stream_buffer, socket.assigns.messages)

    {:noreply, socket |> assign(:messages, messages) |> assign(:stream_buffer, stream_buffer) |> assign(:building, true)}
  end

  defp workspace_path(socket), do: socket.assigns.base_path

  defp setup_volume(socket, name, tab) do
    is_code = String.contains?(name, "code")
    adapter = if socket.assigns[:project], do: BoomLooper.Source.for_project(socket.assigns.project)
    supports_git = is_code && adapter && BoomLooper.Source.supports_git?(adapter)

    socket =
      if socket.assigns[:selected_volume] != name do
        socket
        |> assign(:selected_id, nil)
        |> assign(:selected_agent, nil)
        |> assign(:selected_service, nil)
        |> assign(:selected_volume, name)
        |> FileBrowser.reset()
        |> assign(:git_log, [])
        |> assign(:git_status, [])
        |> assign(:diff_content, nil)
        |> assign(:supports_git, supports_git)
      else
        socket
      end

    assign(socket, :volume_tab, tab)
  end



  defp preset_message("setup") do
    "Look at the project in /workspace and set up a development environment. Start by reading `setup_guide.md` with `read_agent_file` — it has the full playbook."
  end

  defp preset_message("debug") do
    "Check `service_status` for all services. For any that are crashed or unhealthy, pull their logs and diagnose the issue. Fix what you can."
  end

  defp preset_message("explore") do
    "Explore the project in /workspace. Use `tree` to see the structure, then read key files (README, package.json/Gemfile/mix.exs, config files) and give me a summary of what this project is and how it's built."
  end

  defp preset_message(_), do: nil

  defp preset_agent_type("setup"), do: "setup"
  defp preset_agent_type(_), do: "coding"

  defp load_git_data(assigns) do
    project = assigns.project
    workspace_entry = assigns.workspace_entry

    if project && workspace_entry do
      adapter = BoomLooper.Source.for_project(project)

      if BoomLooper.Source.supports_git?(adapter) do
        log_result = adapter.git_log(project, workspace_entry, limit: 20)
        status_result = adapter.git_status(project, workspace_entry)
        {log_result, status_result}
      else
        {{:ok, []}, {:ok, []}}
      end
    else
      {{:ok, []}, {:ok, []}}
    end
  end


  # Derive sidebar service + volume state from Docker.Observer's ETS
  # cache. Zero docker calls — microsecond reads. The Observer
  # maintains the cache via the `docker events` stream.
  #
  # Services: read docker-compose.yml (fast local file) for DEFINED
  # services, then merge running state from Observer's container list.
  # Volumes: directly from Observer's volume list for this workspace.
  defp load_sidebar_from_observer(_workspace_path, workspace_id) do
    # Single source of truth: Observer.services_for reads the compose file
    # from Workspace.compose_dir (always correct) and merges with cached
    # container state. No ad-hoc path computation, no direct Docker calls.
    service_statuses =
      BoomLooper.Docker.Observer.services_for(workspace_id)
      |> Enum.map(&annotate_exposure(&1, workspace_id))

    volumes =
      BoomLooper.Docker.Observer.volumes_for(workspace_id)
      |> Enum.map(fn v ->
        %{name: v.name, type: v.type, service: v.service, description: v.description}
      end)

    {service_statuses, volumes}
  end

  # Populate :chat_agents ETS from the workspace's persisted agent log.
  # Idempotent — safe to call multiple times or when ServiceManager has
  # already run replay. Does NOT start ChatAgent GenServers; the log
  # contents are just made visible to `list_agents/0` so the sidebar can
  # render agents as stopped (their status in the log is preserved,
  # typically :idle, which matches "available but not actively thinking").
  defp prime_agents_from_log(workspace_id) do
    log_path = BoomLooper.ChatAgent.Persistence.log_path(workspace_id)

    cond do
      is_nil(log_path) or not File.exists?(log_path) ->
        :ok

      workspace_already_in_ets?(workspace_id) ->
        # ServiceManager already replayed for this workspace. Don't
        # overwrite live agents' runtime status with stale log status.
        :ok

      true ->
        BoomLooper.AgentLog.replay(
          log_path: log_path,
          version: 1,
          ets_table: :chat_agents
        )
    end
  rescue
    e ->
      require Logger
      Logger.warning("[workspace_live] prime_agents_from_log failed: #{Exception.message(e)}")
  end

  defp workspace_already_in_ets?(workspace_id) do
    Enum.any?(BoomLooper.ChatAgent.list_agents(), &(&1[:workspace_id] == workspace_id))
  end

  # Decorate a service entry with port + exposure info for the sidebar.
  #
  # Registry is the source of truth — it's stable across container
  # restarts and observer poll blips. Observer's svc.ports map is
  # transiently empty while a container is transitioning states, which
  # used to cause the "open port" button to flap in and out of the UI.
  #
  # Algorithm:
  #   1. If PortRegistry has an entry for this service, use it. Done.
  #   2. Otherwise bootstrap from observer (pre-registry workspace) —
  #      seed the registry so subsequent renders take path 1.
  #   3. If neither has anything, no button to show.
  defp annotate_exposure(svc, workspace_id) do
    case registry_entry_for_service(workspace_id, svc.name) do
      {:ok, entry} ->
        Map.merge(svc, %{
          exposed: entry.exposed,
          container_port: entry.container_port,
          host_port: entry.host_port
        })

      :none ->
        # No registry entry. Ports are only assigned via compose
        # processing — if this service has a port but no registry
        # entry, it'll get one next time compose runs.
        Map.merge(svc, %{exposed: false, container_port: nil, host_port: nil})
    end
  end

  defp registry_entry_for_service(workspace_id, service_name) do
    case BoomLooper.PortRegistry.list_for_workspace(workspace_id)
         |> Enum.find(&(&1.service == service_name)) do
      nil -> :none
      entry -> {:ok, entry}
    end
  end

  # Kicks off three Docker calls (container_running?, do_logs, do_inspect)
  # in a single Task. Mounted callers (handle_params for the container tab)
  # call this and return immediately; the assigns get filled in once the
  # Task lands via handle_async(:container_data, ...).
  #
  # While loading, we render placeholder assigns so the page paints.
  defp fetch_container_data(socket) do
    case socket.assigns.selected_id do
      nil ->
        socket

      id ->
        agent_state = BoomLooper.ChatAgent.get_state(id)
        workspace_id = agent_state && agent_state[:workspace_id]
        log_service = socket.assigns.container_log_service

        socket
        |> assign(:container_logs, socket.assigns.container_logs || "")
        |> assign(:container_env, socket.assigns.container_env)
        |> assign(:has_container, socket.assigns.has_container || false)
        |> start_async({:container_data, id}, fn ->
          ws_container =
            if workspace_id,
              do: BoomLooper.Workspace.ServiceManager.service_container_name(workspace_id, "workspace")

          has_container = ws_container != nil && BoomLooper.Docker.container_running?(ws_container)

          if has_container do
            log_opts = %{lines: 100}
            log_opts = if log_service, do: Map.put(log_opts, :service, log_service), else: log_opts

            logs =
              case BoomLooper.Tools.Container.Logs.execute(%{agent_id: id, lines: log_opts[:lines], service: log_opts[:service]}, %{}) do
                {:ok, output} -> output
                {:error, err} -> "Error: #{err}"
              end

            env =
              case BoomLooper.Tools.Container.InspectEnv.execute(%{agent_id: id}, %{}) do
                {:ok, output} -> output
                _ -> nil
              end

            %{has_container: true, logs: logs, env: env}
          else
            %{has_container: false, logs: "", env: nil}
          end
        end)
    end
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div id="chat-page" phx-hook="ScrollBottom" class="h-screen flex flex-col bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100">
      <.chat_header workspace={@workspace} project={@project} workspace_entry={@workspace_entry} live_action={@live_action} base_path={@base_path} iex_session={@iex_session} />
      <.flash_banner flash={@flash} kind={:error} class="mx-4 mt-2" />
      <div class="flex-1 flex min-h-0">
        <%!-- Sidebar: always visible on md+, full-screen on mobile when no agent/service selected --%>
        <.sidebar
          agents={@agents} selected_id={@selected_id} workspace_id={@workspace.id}
          project={@project} workspace_entry={@workspace_entry}
          service_statuses={@service_statuses} selected_service={@selected_service}
          services_loaded={@services_loaded} volumes_loaded={@volumes_loaded}
          live_action={@live_action} volumes={@volumes} base_path={@base_path}
          host={@host}
          is_local_source?={@is_local_source?} sync_status={@sync_status}
          workspace_state={@workspace_state}
          workspace_state_since={@workspace_state_since}
          docker_connected?={@docker_connected?}
        />
        <%!-- Main content: hidden on mobile when sidebar is showing (index/new with no selection) --%>
        <main id="main-content" class={"flex-1 flex flex-col min-w-0 #{if @live_action == :index && !@selected_id && !@selected_service, do: "hidden md:flex", else: "flex"}"}>
          <%!-- Stopped-workspace screen only when the user isn't looking
               at a specific agent. Agent history stays readable regardless
               of service state — sending new messages is what the running
               workspace gates. --%>
          <%!-- Cluster is down → show the big "Start workspace" empty
               state, except on views that carry their own empty state
               (service / console / new-agent). Those views render
               their own "this is stopped" screen inside themselves so
               the sidebar context stays consistent while the user is
               exploring. --%>
          <.workspace_not_running
            :if={@workspace_state in [:stopped, :starting] && !@selected_agent && @live_action not in [:new, :service, :console]}
            workspace={@workspace}
            workspace_state={@workspace_state}
          />
          <.new_agent_screen :if={@live_action == :new} workspace={@workspace} base_path={@base_path} />
          <.service_log_view :if={@live_action == :service} service_name={@selected_service} service_statuses={@service_statuses} logs={@service_logs} base_path={@base_path} host={@host} workspace_state={@workspace_state} />
          <.console_view :if={@live_action == :console} service_name={@selected_service} container={@console_container} />
          <.all_services_view :if={@live_action == :services} all_service_logs={@all_service_logs} />
          <.volume_detail :if={@live_action in [:volume, :volume_files_root, :volume_file, :volume_git]} volume_name={@selected_volume} volumes={@volumes} workspace_id={@workspace.id} base_path={@base_path} volume_tab={@volume_tab} file_tree={@file_tree} file_content={@file_content} file_path={@file_path} browse_path={@browse_path} git_log={@git_log} git_status={@git_status} diff_content={@diff_content} supports_git={@supports_git} />
          <%= if @live_action in [:git_diff, :git_staged_diff] && @diff_content && @diff_content != :loading do %>
            <div class="flex flex-col h-full">
              <div class="flex-none px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center gap-2 text-xs">
                <.link patch={"#{@base_path}/volumes/#{@selected_volume}/git"} class="text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300">← Git</.link>
                <span class="text-zinc-300 dark:text-zinc-600">·</span>
                <span class="font-mono text-zinc-600 dark:text-zinc-400">{@diff_path}</span>
                <span :if={@live_action == :git_staged_diff} class="text-green-600 dark:text-green-400 text-[10px] font-semibold uppercase">staged</span>
              </div>
              <BoomLooperWeb.Live.WorkspaceLive.Components.Viewers.GitViewer.diff_viewer diff={@diff_content} path={@diff_path} />
            </div>
          <% end %>
          <%= if @live_action == :git_commit && is_map(@commit_detail) do %>
            <div class="flex flex-col h-full">
              <div class="flex-none px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50 border-b border-zinc-200 dark:border-zinc-700/80 text-xs">
                <.link patch={"#{@base_path}/volumes/#{@selected_volume}/git"} class="text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300">← Git</.link>
              </div>
              <BoomLooperWeb.Live.WorkspaceLive.Components.Viewers.GitViewer.commit_detail commit={@commit_detail} base_path={@base_path} volume_name={@selected_volume} />
            </div>
          <% end %>
          <%= if @live_action == :git_commit_file && @diff_content && @diff_content != :loading do %>
            <div class="flex flex-col h-full">
              <div class="flex-none px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center gap-2 text-xs">
                <.link patch={"#{@base_path}/volumes/#{@selected_volume}/git/commits/#{@commit_sha}"} class="text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300">← {String.slice(@commit_sha || "", 0..6)}</.link>
                <span class="text-zinc-300 dark:text-zinc-600">·</span>
                <span class="font-mono text-zinc-600 dark:text-zinc-400">{@diff_path}</span>
              </div>
              <BoomLooperWeb.Live.WorkspaceLive.Components.Viewers.GitViewer.diff_viewer diff={@diff_content} path={@diff_path} />
            </div>
          <% end %>
          <.sync_detail :if={@live_action == :sync} sync_status={@sync_status} workspace_id={@workspace.id} workspace={@workspace} />
          <.booting_screen :if={@live_action in [:index, :chat, :container] && @booting_agent_id && !@selected_agent} agent_id={@booting_agent_id} status={@boot_status} boot_log={@boot_log} />
          <.empty_state :if={@live_action in [:index, :chat, :container] && !@booting_agent_id && !@selected_agent} />
          <.agent_view :if={@live_action in [:index, :chat, :container, :context_panel] && @selected_agent} {assigns} />
        </main>
      </div>
    </div>
    """
  end
end
