defmodule LoopyardWeb.WorkspaceLive do
  use LoopyardWeb, :live_view
  use LoopyardWeb.IExAware

  alias Loopyard.ChatAgent
  alias Loopyard.Events
  alias Loopyard.StreamBuffer

  use LoopyardWeb.Live.WorkspaceLive.Components
  import LoopyardWeb.Live.WorkspaceLive.MainContent

  alias LoopyardWeb.Live.WorkspaceLive.{
    AgentLifecycle,
    DataLoader,
    DiffLoader,
    DockerEvents,
    FileBrowser,
    Navigation,
    ServiceLogs,
    Switcher
  }

  # Move #3 strict subscriber behaviours — compile-time enforcement that
  # every event published on these topics has a matching callback here.
  # A new event added to any of the publishers shows up as a Dialyzer /
  # `@impl` warning until we wire it in.
  @behaviour Loopyard.Events.ChatAgent.Subscriber
  @behaviour Loopyard.Events.ChatAgentMessage.Subscriber
  @behaviour Loopyard.Events.DockerObserver.Subscriber
  @behaviour Loopyard.Events.WorkspaceServices.Subscriber
  @behaviour Loopyard.Events.SourceSync.Subscriber
  @behaviour Loopyard.Events.WorkspaceSetup.Subscriber
  @behaviour Loopyard.Events.Workspaces.Subscriber

  @impl true
  def mount(%{"project_id" => project_id, "workspace_id" => workspace_id}, _session, socket) do
    project = Loopyard.ProjectRegistry.get_project(project_id)
    workspace_entry = Loopyard.ProjectRegistry.get_workspace(workspace_id)

    unless project && workspace_entry do
      {:ok, push_navigate(socket, to: "/")}
    else
      # workspace_entry is normalized by ProjectRegistry - always has :path
      workspace = %{id: workspace_entry.id, path: workspace_entry.path, name: project.name}

      mount_with_workspace(socket, workspace, %{
        project: project,
        workspace_entry: workspace_entry
      })
    end
  end

  defp mount_with_workspace(socket, workspace, extra_assigns) do
    is_local? = extra_assigns[:project] && extra_assigns[:project][:source_type] == :local

    if connected?(socket) do
      ChatAgent.subscribe()
      # God-mode sidebar (#55): the global + per-project activity stream keeps
      # the cross-project tree live no matter the view.
      Loopyard.Events.Activity.subscribe_global()
      Loopyard.Workspace.ServiceManager.subscribe()
      Loopyard.Docker.Observer.subscribe()
      Loopyard.Events.WorkspaceSetup.subscribe(workspace.id)

      # A workspace added/removed/status-changed in this project → refresh the
      # left switcher live (a fork someone makes appears without a reload).
      if project = extra_assigns[:project],
        do: Loopyard.Events.Workspaces.subscribe(project.id)

      # Local workspaces broadcast sync-session state changes on their own
      # PubSub topic; the sidebar shows them in a small "Sync" card.
      if is_local? do
        Phoenix.PubSub.subscribe(
          Loopyard.PubSub,
          Loopyard.Source.Local.SyncMonitor.topic(workspace.id)
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
      supervisor_up? = Loopyard.WorkspaceSupervisor.workspace_healthy?(workspace.id)
      containers_up? = any_running_containers?(workspace.id)

      if supervisor_up? or containers_up? do
        send(self(), {:start_workspace, workspace.path})
      end
    end

    socket =
      if connected?(socket),
        do: subscribe_iex(socket),
        else: assign(socket, :iex_session, %{level: nil})

    # Agents survive server restarts via an append-only ETF log. On a
    # fresh boot the :chat_agents ETS table is empty and list_agents
    # returns []. Pre-populate from the log so the sidebar shows the
    # agent list even before the workspace is started. ChatAgent
    # processes start later (when ServiceManager runs).
    ws_id =
      (extra_assigns[:workspace_entry] && extra_assigns[:workspace_entry].id) || workspace.id

    DataLoader.prime_agents_from_log(ws_id)

    # Services + volumes come from Docker.Observer's ETS cache (instant,
    # zero docker calls). The sidebar renders immediately with real data.
    agents = AgentLifecycle.list_workspace_agents(workspace.path)
    {service_statuses, volumes} = DockerEvents.load_sidebar_from_observer(workspace.path, ws_id)

    base_path =
      if extra_assigns[:project] do
        "/projects/#{extra_assigns[:project].id}/workspaces/#{extra_assigns[:workspace_entry].id}"
      else
        "/projects/#{workspace.id}/workspaces/#{workspace.id}"
      end

    host =
      case socket.host_uri do
        %URI{host: h} when is_binary(h) and h != "" -> h
        _ -> "localhost"
      end

    {:ok,
     socket
     |> assign(:workspace, workspace)
     |> assign(:project, extra_assigns[:project])
     |> assign(:workspace_entry, extra_assigns[:workspace_entry])
     |> assign(:base_path, base_path)
     |> assign(:global_tree, Loopyard.WorkspaceTree.global(host))
     # Expandable-tree sidebar. Restore THIS window's saved collapse state
     # (per-window via transport_pid, survives the navigate-remount, independent
     # across windows). Nothing saved yet → land with the current project open.
     |> assign(
       :expanded,
       restore_expanded(socket, extra_assigns[:project] && extra_assigns[:project].id)
     )
     |> Switcher.attach_view_tracker()
     |> assign(:host, host)
     |> assign(:agents, agents)
     |> assign(:service_statuses, service_statuses)
     |> assign(:services_loaded, true)
     |> assign(:volumes_loaded, true)
     |> assign(:volumes, volumes)
     |> assign(:selected_id, nil)
     |> assign(:selected_agent, nil)
     |> assign(:messages, [])
     |> assign(:has_more_messages, false)
     |> assign(:streaming_text, "")
     |> assign(:streaming_thinking, "")
     |> assign(:thinking_word, nil)
     |> assign(:tab, :chat)
     # Activity disclosure level. Starts at :trace (everything visible) for
     # maximum trust; the DetailLevel JS hook restores the user's saved
     # preference from localStorage on connect.
     |> assign(:detail_level, :trace)
     |> assign(:container_logs, "")
     |> assign(:container_env, nil)
     |> assign(:container_log_service, nil)
     |> assign(:has_container, false)
     |> assign(:booting_agent_id, nil)
     |> assign(:boot_status, "Initializing...")
     |> assign(:boot_log, [])
     |> assign(:editing_name, false)
     |> assign(:editing_agent_id, nil)
     |> assign(:selected_service, nil)
     |> assign(:selected_volume, nil)
     |> assign(:volume_tab, :info)
     |> assign(:file_tree, nil)
     |> assign(:file_content, nil)
     |> assign(:file_path, nil)
     |> assign(:browse_path, ".")
     |> assign(:git_log, [])
     |> assign(:git_status, [])
     # Live working-tree changes for the right-pane "Changes" hero (#58).
     |> assign(:changes, %{staged: [], unstaged: []})
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
     |> assign(
       :workspace_state,
       DockerEvents.derive_workspace_state(workspace.id, service_statuses, nil)
     )
     |> assign(:workspace_state_since, DateTime.utc_now())
     |> assign(:docker_connected?, DockerEvents.docker_connected?())}
  end

  # Refresh the :selected_agent assign with the agent's latest summary
  # (model, token counts, cost, turns). The context-panel template reads
  # those fields from :selected_agent, but select_agent/2 only runs on
  # mount / click — without this, the panel stays pinned at "awaiting
  # first response" / 0 tokens even as the agent streams through turns.
  defp any_running_containers?(workspace_id) do
    Loopyard.Docker.Observer.containers_for(workspace_id)
    |> Enum.any?(&Map.get(&1, :running, false))
  rescue
    _ -> false
  end

  defp initial_sync_status(_workspace_id, false), do: nil

  defp initial_sync_status(workspace_id, true) do
    Loopyard.Source.Local.SyncMonitor.status(workspace_id)
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: action}} = socket)
      when action in [:chat, :container, :context_panel] do
    tab =
      case action do
        :container -> :container
        :context_panel -> :context_panel
        _ -> :chat
      end

    # Clear service selection when viewing an agent
    socket = assign(socket, :selected_service, nil)

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
    socket = if tab == :container, do: DataLoader.fetch_container_data(socket), else: socket
    # Load the agent's working-tree changes for the right-pane hero (#58).
    socket = refresh_changes(socket)
    {:noreply, socket}
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :new}} = socket) do
    # If a Setup agent is already running we just hop to it — this branch
    # is fast (in-memory list scan).
    existing_setup =
      socket.assigns.agents
      |> Enum.find(fn a -> a[:name] == "Setup" && a[:status] not in [:stopped, :crashed] end)

    cond do
      existing_setup ->
        {:noreply,
         push_patch(socket, to: "#{workspace_path(socket)}/agents/#{existing_setup.id}")}

      true ->
        # Show the New Agent screen. Setup only runs when the user picks
        # the Setup preset explicitly — no auto-launch on blank workspaces.
        {:noreply, socket}
    end
  end

  def handle_params(
        %{"service_name" => service_name},
        _uri,
        %{assigns: %{live_action: :service}} = socket
      ) do
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

  def handle_params(
        %{"service_name" => service_name},
        _uri,
        %{assigns: %{live_action: :console}} = socket
      ) do
    svc = Enum.find(socket.assigns.service_statuses, &(&1.name == service_name))

    # Process containers exec into workspace service (has shell + tools)
    # Stock services exec into their own container
    workspace_id = Loopyard.ProjectRegistry.workspace_id(socket.assigns.workspace.path)

    container =
      cond do
        svc && svc.type == :process ->
          Loopyard.Workspace.ServiceManager.service_container_name(workspace_id, "workspace")

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

    # Working is the default: landing on a bare workspace URL should NEVER dump
    # you on a blank "select an agent" screen. Resolve a real landing target:
    #   1. no agents yet → auto-spawn one (you land in a fresh live chat),
    #   2. agents exist → resume this window's last view here (WindowViews), or
    #      fall back to the latest agent's chat.
    #
    # CRITICAL: read the LIVE agent list here, not socket.assigns.agents — that's
    # a mount-time snapshot, stale across the remounts a reconnect/live-reload
    # causes. A fresh fork plus a couple of reconnects each saw the stale empty
    # snapshot and auto-spawned, piling up 3 agents. register_booting/4 lands the
    # agent in ETS synchronously before we navigate, so a re-fetch sees it.
    live_agents =
      if connected?(socket),
        do: AgentLifecycle.list_workspace_agents(socket.assigns.workspace.path),
        else: socket.assigns.agents

    socket = assign(socket, :agents, live_agents)

    cond do
      live_agents != [] ->
        case Navigation.landing_target(socket) do
          nil -> {:noreply, socket}
          path -> {:noreply, push_patch(socket, to: path)}
        end

      connected?(socket) and !socket.assigns[:auto_spawned] ->
        AgentLifecycle.do_spawn_agent(assign(socket, :auto_spawned, true))

      true ->
        {:noreply, socket}
    end
  end

  # Volume info page
  def handle_params(%{"volume_name" => name}, _uri, %{assigns: %{live_action: :volume}} = socket) do
    # Default to files view — more useful than info
    {:noreply, push_patch(socket, to: "#{socket.assigns.base_path}/volumes/#{name}/files")}
  end

  # File browser root: /volumes/:name/files
  def handle_params(
        %{"volume_name" => name},
        _uri,
        %{assigns: %{live_action: :volume_files_root}} = socket
      ) do
    socket = setup_volume(socket, name, :files)
    {:noreply, FileBrowser.enter_root(socket, name)}
  end

  # File browser: /volumes/:name/files/path/to/thing
  # Could be a file or a directory — FileBrowser probes both and the
  # :file_content handle_async dispatches on the returned shape.
  def handle_params(
        %{"volume_name" => name, "path" => path_parts},
        _uri,
        %{assigns: %{live_action: :volume_file}} = socket
      ) do
    file_path = Path.join(path_parts)
    socket = setup_volume(socket, name, :files)
    {:noreply, FileBrowser.enter_path(socket, name, file_path)}
  end

  # Git view
  def handle_params(
        %{"volume_name" => name},
        _uri,
        %{assigns: %{live_action: :volume_git}} = socket
      ) do
    socket = setup_volume(socket, name, :git)

    socket =
      if socket.assigns.git_log == [] do
        git_assigns = Map.take(socket.assigns, [:project, :workspace_entry])
        start_async(socket, :git_data, fn -> DataLoader.load_git_data(git_assigns) end)
      else
        socket
      end

    {:noreply, socket}
  end

  # Git diff for unstaged file
  def handle_params(
        %{"volume_name" => name, "path" => path_parts},
        _uri,
        %{assigns: %{live_action: :git_diff}} = socket
      ) do
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
  def handle_params(
        %{"volume_name" => name, "path" => path_parts},
        _uri,
        %{assigns: %{live_action: :git_staged_diff}} = socket
      ) do
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
  def handle_params(
        %{"volume_name" => name, "sha" => sha},
        _uri,
        %{assigns: %{live_action: :git_commit}} = socket
      ) do
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
  def handle_params(
        %{"volume_name" => name, "sha" => sha, "path" => path_parts},
        _uri,
        %{assigns: %{live_action: :git_commit_file}} = socket
      ) do
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
  def handle_async(:file_content, {:ok, %{content: content, path: path}}, socket)
      when is_binary(content) do
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
    {:noreply,
     socket |> assign(:file_content, "File not found: #{path}") |> assign(:file_path, path)}
  end

  def handle_async(:file_content, {:exit, _reason}, socket) do
    {:noreply, assign(socket, :file_content, nil)}
  end

  def handle_async(:git_data, {:ok, {log_result, status_result}}, socket) do
    git_log =
      case log_result do
        {:ok, entries} -> entries
        _ -> []
      end

    git_status =
      case status_result do
        {:ok, entries} -> entries
        _ -> []
      end

    {:noreply, socket |> assign(:git_log, git_log) |> assign(:git_status, git_status)}
  end

  # Right-pane "Changes" hero (#58). git_status returns %{staged, unstaged};
  # anything else (error / no git) resets to empty ("working tree clean").
  def handle_async(:changes, {:ok, {:ok, status}}, socket) when is_map(status),
    do: {:noreply, assign(socket, :changes, status)}

  def handle_async(:changes, _other, socket),
    do: {:noreply, assign(socket, :changes, %{staged: [], unstaged: []})}

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
  def handle_event("retry_setup", %{"workspace-id" => workspace_id}, socket) do
    case Loopyard.Workspace.Setup.retry(workspace_id) do
      :ok ->
        {:noreply, socket}

      {:error, :already_running} ->
        {:noreply, put_flash(socket, :info, "Setup is already in progress.")}

      {:error, {:not_failed, phase}} ->
        {:noreply, put_flash(socket, :info, "Setup is at #{phase}; nothing to retry.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't retry setup: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("remove_workspace_setup_failed", %{"workspace-id" => workspace_id}, socket) do
    case Loopyard.WorkspaceRegistry.remove_workspace(workspace_id) do
      :ok ->
        project_id = socket.assigns.project && socket.assigns.project.id
        path = if project_id, do: "/projects/#{project_id}", else: "/"
        {:noreply, push_navigate(socket, to: path)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't remove workspace: #{inspect(reason)}")}
    end
  end

  # --- God-mode sidebar: expandable tree (#55) ---

  # Open/close a project branch. Several can be open at once; collapse the ones
  # you care less about. Persisted per-window so it survives navigation.
  def handle_event("sidebar_toggle", %{"node" => key}, socket) do
    expanded = LoopyardWeb.Components.GlobalSidebar.toggle(socket.assigns.expanded, key)
    Loopyard.WindowViews.put_expanded(socket.transport_pid, MapSet.to_list(expanded))
    {:noreply, assign(socket, :expanded, expanded)}
  end

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
      initial_message: Navigation.preset_message(preset)
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
      # Reply so the client's ChatForm hook knows the send LANDED and can clear
      # the input. Without an ack, a send fired into a momentarily-disconnected
      # socket (live-reload, reconnect, flaky link) clears the box and vanishes
      # silently. The hook keeps the text until this reply arrives.
      {:reply, %{ok: true}, socket}
    else
      {:reply, %{ok: false}, socket}
    end
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more_messages && socket.assigns.selected_id do
      oldest = List.first(socket.assigns.messages)

      {older, total} =
        ChatAgent.get_messages(
          socket.assigns.selected_id,
          limit: 50,
          before_id: oldest && oldest[:id],
          snap_to_prompt: true
        )

      if older != [] do
        combined = older ++ socket.assigns.messages

        {:noreply,
         socket
         |> assign(:messages, combined)
         |> assign(:has_more_messages, length(combined) < total)
         |> push_event("messages_prepended", %{})}
      else
        {:noreply, assign(socket, :has_more_messages, false)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open_port_from_chat", %{"service" => svc, "container_port" => cport}, socket) do
    ws_id = socket.assigns.workspace.id
    cport = String.to_integer(cport)

    case Loopyard.PortRegistry.set_exposure(ws_id, svc, cport, true) do
      :ok ->
        service_statuses =
          Enum.map(socket.assigns.service_statuses, fn s ->
            if s.name == svc, do: Map.put(s, :exposed, true), else: s
          end)

        {:noreply,
         socket
         |> assign(:service_statuses, service_statuses)
         |> put_flash(:info, "Port opened — link is now accessible")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not open port: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event(
        "answer_question",
        %{"question_id" => qid, "q" => q_id, "option" => option},
        socket
      ) do
    # Deliver the human's choice to the blocked harness question (multiplayer:
    # the broker flips the message to :answered for every viewer).
    case Loopyard.Harness.Questions.answer(qid, %{q_id => [option]}) do
      :ok ->
        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :info, "That question was already answered.")}
    end
  end

  @impl true
  def handle_event("submit_secret", %{"request_id" => rid, "secret" => value}, socket) do
    # The masked value goes straight to the on-disk store (scoped to this
    # workspace) and the broker signals the blocked agent with only the KEY — the
    # value is never assigned, broadcast, or returned here, so it stays out of the
    # transcript. `value` is dropped immediately after this call.
    ws_id = socket.assigns.workspace.id

    case Loopyard.Harness.SecretRequests.submit(rid, value, ws_id, nil) do
      {:ok, _key} ->
        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :info, "That secret request is no longer waiting.")}
    end
  end

  @impl true
  def handle_event("cancel_secret", %{"request_id" => rid}, socket) do
    # The human declined — flip the card to :declined for everyone and let the
    # agent's turn resume so it stops asking.
    Loopyard.Harness.SecretRequests.cancel(rid, nil)
    {:noreply, socket}
  end

  @impl true
  def handle_event("decide_approval", %{"approval_id" => id, "decision" => decision}, socket) do
    decision = if decision == "approve", do: :approve, else: :deny
    agent_id = socket.assigns.selected_id

    # The approval card message carries both the action and its msg id.
    card =
      Enum.find(socket.assigns.messages, fn m -> m[:approval_id] == id end)

    action = card && card[:action]

    # Optimistically flip the card to its working state the instant the human
    # clicks — fork/integrate can take a few seconds, and we don't want the
    # buttons to sit there looking unclicked. Persisted + broadcast, so every
    # viewer sees "Creating…/Merging…" immediately. The tool's own resolve/3
    # calls that follow are idempotent.
    if decision == :approve && agent_id && card && action[:verb] != :delete_workspace do
      transient = if action[:verb] == :integrate, do: :integrating, else: :creating
      ChatAgent.update_message(agent_id, card.id, fn m -> Map.put(m, :status, transient) end)
    end

    # Deliver to the blocked propose_* tool. For fork/integrate the tool runs the
    # action; for delete_workspace the agent would be killed by its own
    # deletion, so the LiveView runs the destroy + navigates away.
    case Loopyard.Harness.Approvals.decide(id, decision) do
      :ok ->
        :ok

      {:error, :not_found} ->
        # The propose_* tool that posted this card is gone (session restart,
        # crash, or the 30-min timeout) — nothing is listening, so the decision
        # would vanish and the card (already flipped to :creating above) would
        # spin forever. Flip it to a terminal state so the human isn't stuck.
        if agent_id && card do
          ChatAgent.update_message(agent_id, card.id, fn m ->
            Map.merge(m, %{
              status: :failed,
              error: "this proposal expired — ask the agent to create the branch again"
            })
          end)
        end
    end

    cond do
      decision == :approve && action && action[:verb] == :delete_workspace ->
        ws_id = action.workspace_id

        Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
          Loopyard.Workspace.Destructor.destroy(ws_id)
        end)

        {:noreply,
         socket
         |> put_flash(:info, "Workspace deleted.")
         |> push_navigate(to: "/projects/#{action.project_id}")}

      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("restart_session", %{"id" => id}, socket) do
    ChatAgent.restart_session(id)
    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_pending", %{"id" => id}, socket) do
    ChatAgent.clear_pending(id)
    {:noreply, socket}
  end

  @impl true
  def handle_event("remove_pending", %{"id" => id, "index" => index}, socket) do
    ChatAgent.remove_pending(id, String.to_integer(index))
    {:noreply, socket}
  end

  @impl true
  def handle_event("edit_pending", %{"id" => id, "index" => index}, socket) do
    # Pull a queued message back into the box to edit it: remove it from the
    # queue and fill the input with its text. You can always edit the queue.
    index = String.to_integer(index)
    text = Enum.at(socket.assigns.selected_agent[:pending_messages] || [], index)
    ChatAgent.remove_pending(id, index)

    if is_binary(text) do
      {:noreply, push_event(socket, "fill_input", %{text: text})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("interrupt_agent", %{"id" => id}, socket) do
    ChatAgent.interrupt(id)
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
  def handle_event(
        "toggle_port_exposure",
        %{"service" => svc_name, "container_port" => cport, "expose" => expose},
        socket
      ) do
    workspace_id = socket.assigns.workspace.id
    cport = String.to_integer(cport)
    exposed? = expose == "true"

    host_port =
      Enum.find_value(socket.assigns.service_statuses, fn s ->
        if s.name == svc_name, do: Map.get(s, :host_port)
      end)

    case Loopyard.PortRegistry.set_exposure(workspace_id, svc_name, cport, exposed?) do
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

        # Feedback so open/close is never a silent no-op — and on OPEN,
        # surface the actual shareable LAN URL (what you'd send to demo it).
        flash =
          if exposed? do
            url = if host_port, do: "http://#{lan_ip()}:#{host_port}", else: "your machine's IP"
            "Port opened — '#{svc_name}' is now reachable on your network at #{url}"
          else
            "Port closed — '#{svc_name}' is local-only again (not reachable from other devices)."
          end

        {:noreply,
         socket
         |> assign(:service_statuses, DockerEvents.guard_service_statuses(socket, updated))
         |> put_flash(:info, flash)}

      {:error, reason} ->
        require Logger
        Logger.warning("[workspace_live] toggle_port_exposure failed: #{inspect(reason)}")

        msg =
          case reason do
            :no_docker_port ->
              "Can't open the port yet — the service's container port isn't mapped. Is '#{svc_name}' running?"

            :not_registered ->
              "Can't open the port — '#{svc_name}' (#{cport}) isn't registered. Restart the service and try again."

            other ->
              "Couldn't toggle the port: #{inspect(other)}"
          end

        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  @impl true
  def handle_event("set_detail_level", %{"level" => level}, socket)
      when level in ~w(trace actions chat) do
    {:noreply, assign(socket, :detail_level, String.to_existing_atom(level))}
  end

  def handle_event("set_detail_level", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("start_rename", _params, socket) do
    {:noreply, assign(socket, :editing_name, true)}
  end

  @impl true
  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, :editing_name, false)}
  end

  # Sidebar inline rename — double-click on agent name
  @impl true
  def handle_event("start_rename_sidebar", %{"id" => id}, socket) do
    {:noreply, assign(socket, :editing_agent_id, id)}
  end

  @impl true
  def handle_event("cancel_rename_sidebar", _params, socket) do
    {:noreply, assign(socket, :editing_agent_id, nil)}
  end

  @impl true
  def handle_event("rename_agent", %{"name" => name} = params, socket) do
    # Sidebar rename passes agent id explicitly; context panel uses selected_id
    agent_id = params["id"] || socket.assigns.selected_id

    if agent_id && String.trim(name) != "" do
      ChatAgent.rename(agent_id, String.trim(name))
    end

    {:noreply,
     socket
     |> assign(:editing_name, false)
     |> assign(:editing_agent_id, nil)}
  end

  @impl true
  # --- UI state events ---

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab =
      case tab do
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
    case Loopyard.Source.Local.SyncMonitor.whereis(ws_id) do
      nil ->
        # No SyncMonitor running — update the card to show the real state
        {:noreply,
         assign(socket, :sync_status, %{
           status: :stopped,
           last_error: "No sync process — workspace container may not be running",
           last_checked_at: DateTime.utc_now()
         })}

      _pid ->
        Loopyard.Source.Local.SyncMonitor.restart(ws_id)
        # Immediately show "starting" so the button feels responsive
        {:noreply,
         assign(socket, :sync_status, %{
           status: :starting,
           last_error: nil,
           last_checked_at: DateTime.utc_now()
         })}
    end
  end

  def handle_event("sync_pause", %{"workspace-id" => ws_id}, socket) do
    Loopyard.Source.Local.SyncMonitor.pause(ws_id)
    {:noreply, socket}
  end

  def handle_event("sync_resume", %{"workspace-id" => ws_id}, socket) do
    Loopyard.Source.Local.SyncMonitor.resume(ws_id)
    {:noreply, socket}
  end

  # --- Cluster events (Docker Compose + volumes) ---

  def handle_event("restart_service", %{"service_name" => name}, socket) do
    service_statuses =
      Enum.map(socket.assigns.service_statuses, fn svc ->
        if svc.name == name, do: %{svc | status: :starting}, else: svc
      end)

    socket =
      assign(
        socket,
        :service_statuses,
        DockerEvents.guard_service_statuses(socket, service_statuses)
      )

    run_compose_async(socket, ["restart", name], 30_000)
  end

  def handle_event("start_service", %{"service_name" => name}, socket) do
    # `up -d <service>` brings a stopped/crashed service back without
    # touching the rest of the compose project. `restart` is a no-op
    # on a non-running container, which is why the single-button
    # "Restart" was the wrong call to show in the log view when the
    # service isn't running.
    #
    # Optimistically flip the service to :starting so the UI shows
    # feedback immediately. Docker Observer will correct it to :running
    # or :crashed once the container state changes.
    service_statuses =
      Enum.map(socket.assigns.service_statuses, fn svc ->
        if svc.name == name and svc.status in [:stopped, :crashed] do
          %{svc | status: :starting}
        else
          svc
        end
      end)

    socket =
      assign(
        socket,
        :service_statuses,
        DockerEvents.guard_service_statuses(socket, service_statuses)
      )

    run_compose_async(socket, ["up", "-d", name], 60_000)
  end

  def handle_event("stop_service", %{"service_name" => name}, socket) do
    run_compose_async(socket, ["stop", name], 30_000)
  end

  def handle_event("boot_workspace", _params, socket) do
    # Don't let the cluster start while setup is still seeding the volume.
    # Mutagen and our seed rsync would race for writes on the same volume.
    if Loopyard.Workspace.ready?(socket.assigns.workspace_entry) do
      # Flip to :starting immediately so the UI shows the transitional
      # state. The actual start runs async — observer events will flip
      # us to :started when containers come up.
      send(self(), {:start_workspace, socket.assigns.workspace.path})
      {:noreply, DockerEvents.transition_workspace_state(socket, :starting)}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "Workspace is still being set up — wait for the volume seed to finish before starting the cluster."
       )}
    end
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
    Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
      effective_dir = Loopyard.Workspace.compose_dir(ws_id)
      Loopyard.Compose.down(effective_dir, ws_id)
      Loopyard.WorkspaceSupervisor.stop_workspace(ws_id)
      Loopyard.ProjectRegistry.update_workspace_status(ws_id, :stopped)
      Loopyard.Docker.Observer.poll_now()
      send(parent, :workspace_stopped)
    end)

    {:noreply, DockerEvents.transition_workspace_state(socket, :stopping)}
  end

  @impl true

  def handle_event("delete_volume", %{"volume_name" => name}, socket) do
    Loopyard.Docker.docker(["volume", "rm", name])
    Loopyard.Docker.Observer.poll_now()
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
    {:noreply, DataLoader.fetch_container_data(socket)}
  end

  @impl true
  def handle_event("filter_container_service", %{"service" => service}, socket) do
    service = if service == "", do: nil, else: service
    socket = assign(socket, :container_log_service, service)
    {:noreply, DataLoader.fetch_container_data(socket)}
  end

  # First non-loopback, non-link-local IPv4 — the address another device on
  # the LAN uses to reach an exposed port (for demos).
  defp lan_ip do
    case :inet.getifaddrs() do
      {:ok, ifaces} ->
        ifaces
        |> Enum.flat_map(fn {_name, opts} ->
          for {:addr, {a, b, c, d}} <- opts, a != 127, a != 169, do: "#{a}.#{b}.#{c}.#{d}"
        end)
        |> List.first() || "localhost"

      _ ->
        "localhost"
    end
  end

  # --- PubSub ---
  #
  # Every PubSub broadcast we subscribe to arrives as a typed struct from
  # Loopyard.Events.*. The handle_info clauses below are two-line
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

  # God-mode sidebar (#55): any agent's status/tool activity, anywhere, rebuilds
  # the cross-project tree so the left rail stays live across all projects.
  def handle_info(%Loopyard.Events.Activity.Event{}, socket),
    do:
      {:noreply, assign(socket, :global_tree, Loopyard.WorkspaceTree.global(socket.assigns.host))}

  def handle_info(%Events.ChatAgentMessage.Message{} = e, socket), do: on_message(e, socket)
  def handle_info(%Events.ChatAgentMessage.TextDelta{} = e, socket), do: on_text_delta(e, socket)

  def handle_info(%Events.ChatAgentMessage.StreamOutput{} = e, socket),
    do: on_stream_output(e, socket)

  def handle_info(%Events.DockerObserver.Changed{} = e, socket), do: on_changed(e, socket)
  def handle_info(%Events.DockerObserver.Reset{} = e, socket), do: on_reset(e, socket)

  def handle_info(%Events.DockerObserver.Disconnected{} = e, socket),
    do: on_disconnected(e, socket)

  def handle_info(%Events.DockerObserver.Reconnected{} = e, socket), do: on_reconnected(e, socket)

  def handle_info(%Events.WorkspaceServices.ServicesUpdated{} = e, socket),
    do: on_services_updated(e, socket)

  def handle_info(%Events.WorkspaceServices.ComposeResult{} = e, socket),
    do: on_compose_result(e, socket)

  def handle_info(%Events.SourceSync.Updated{} = e, socket), do: on_updated(e, socket)

  def handle_info(%Events.WorkspaceSetup.Started{} = e, socket), do: on_setup_started(e, socket)

  def handle_info(%Events.WorkspaceSetup.PhaseStarted{} = e, socket),
    do: on_setup_phase_started(e, socket)

  def handle_info(%Events.WorkspaceSetup.PhaseCompleted{} = e, socket),
    do: on_setup_phase_completed(e, socket)

  def handle_info(%Events.WorkspaceSetup.PhaseProgress{} = e, socket),
    do: on_setup_phase_progress(e, socket)

  def handle_info(%Events.WorkspaceSetup.Completed{} = e, socket),
    do: on_setup_completed(e, socket)

  def handle_info(%Events.WorkspaceSetup.Failed{} = e, socket), do: on_setup_failed(e, socket)

  def handle_info(%Events.WorkspaceSetup.RetryScheduled{} = e, socket),
    do: on_setup_retry_scheduled(e, socket)

  def handle_info(%Events.Workspaces.Changed{} = e, socket), do: on_workspaces_changed(e, socket)

  # Non-PubSub internal messages (send/2 self-dispatches, async task
  # replies). These aren't subject to the publisher-module boundary
  # because they never leave this process.

  def handle_info(:workspace_stopped, socket) do
    ws_id =
      (socket.assigns.workspace_entry && socket.assigns.workspace_entry.id) ||
        socket.assigns.workspace.id

    {service_statuses, volumes} = DockerEvents.load_sidebar_from_observer(nil, ws_id)

    # Intentional empty replacement on :workspace_stopped — workspace
    # stopped, no services. The guard_service_statuses guard exists to
    # prevent ACCIDENTAL flapping from non-empty to empty. This is
    # deliberate, so we bypass the guard with force_assign_service_statuses.
    {:noreply,
     socket
     |> DockerEvents.transition_workspace_state(:stopped)
     |> DockerEvents.force_assign_service_statuses(service_statuses)
     |> assign(:volumes, volumes)
     |> assign(:agents, [])}
  end

  def handle_info({:start_workspace, path}, socket) do
    workspace_id = Loopyard.ProjectRegistry.workspace_id(path)
    workspace = Loopyard.WorkspaceRegistry.get_workspace(workspace_id)

    # Same gate as boot_workspace handle_event — never start the cluster
    # while setup is still seeding the volume. The handle_info path is
    # reached both from the user-clicked button (already gated) and from
    # the mount-time silent reconnect when supervisor / containers are
    # alive. For reconnect: if containers are up and ready? returns true
    # (which it will for any pre-feature workspace), we proceed normally.
    if workspace && Loopyard.Workspace.ready?(workspace) do
      # Start workspace in a Task so it doesn't block the LiveView. The
      # supervisor start triggers compose up inside ServiceManager.
      # Subsequent DockerObserver.Changed events flip us from :starting → :running.
      Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
        Loopyard.WorkspaceSupervisor.start_workspace(workspace_id, path)
        Loopyard.ProjectRegistry.update_workspace_status(workspace_id, :running)
        Loopyard.Docker.Observer.poll_now()
      end)
    end

    {:noreply, socket}
  end

  def handle_info({:build_output, id, data}, socket) when id == socket.assigns.selected_id do
    upsert_stream_message(socket, data, "Building Docker image...", nil)
  end

  def handle_info({:fetch_service_logs, service_name}, socket) do
    ws_id =
      (socket.assigns.workspace_entry && socket.assigns.workspace_entry.id) ||
        socket.assigns.workspace.id

    {:noreply, ServiceLogs.start_service_logs_fetch(socket, ws_id, service_name)}
  end

  def handle_info(:fetch_all_service_logs, socket) do
    ws_id =
      (socket.assigns.workspace_entry && socket.assigns.workspace_entry.id) ||
        socket.assigns.workspace.id

    {:noreply, ServiceLogs.start_all_service_logs_fetch(socket, ws_id)}
  end

  def handle_info(:refresh_service_logs, socket) do
    ws_id =
      (socket.assigns.workspace_entry && socket.assigns.workspace_entry.id) ||
        socket.assigns.workspace.id

    case socket.assigns.live_action do
      :service ->
        ServiceLogs.schedule_log_refresh()

        {:noreply,
         ServiceLogs.start_service_logs_fetch(socket, ws_id, socket.assigns.selected_service)}

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
  # Logic extracted to AgentEvents — callbacks delegate there.

  alias LoopyardWeb.Live.WorkspaceLive.AgentEvents

  @impl Events.ChatAgent.Subscriber
  def on_started(event, socket), do: AgentEvents.handle_started(event, socket)

  @impl Events.ChatAgent.Subscriber
  def on_resumed(event, socket), do: AgentEvents.handle_resumed(event, socket)

  @impl Events.ChatAgent.Subscriber
  def on_booting(event, socket), do: AgentEvents.handle_booting(event, socket)

  @impl Events.ChatAgent.Subscriber
  def on_boot_status(event, socket), do: AgentEvents.handle_boot_status(event, socket)

  @impl Events.ChatAgent.Subscriber
  def on_boot_failed(event, socket),
    do: AgentEvents.handle_boot_failed(event, socket, &workspace_path/1)

  @impl Events.ChatAgent.Subscriber
  def on_stopped(_event, socket), do: AgentEvents.handle_stopped(socket)

  @impl Events.ChatAgent.Subscriber
  def on_removed(event, socket), do: AgentEvents.handle_removed(event, socket)

  @impl Events.ChatAgent.Subscriber
  def on_renamed(event, socket), do: AgentEvents.handle_renamed(event, socket)

  @impl Events.ChatAgent.Subscriber
  def on_status_changed(event, socket) do
    {:noreply, socket} = AgentEvents.handle_status_changed(event, socket)

    # Keep the god-mode rail LIVE off the SAME authoritative transition the
    # right pane uses — patch the tree agent's status straight from the event
    # (no stale ETS re-read). Without this the rail freezes on an old frame:
    # the right pane goes green while the rail still shows red/gray.
    socket = update(socket, :global_tree, &patch_tree_agent_status(&1, event.id, event.status))

    # When the selected agent finishes a turn (→ :idle), its working-tree
    # changes have settled — refresh the right-pane "Changes" hero (#58).
    socket =
      if event.id == socket.assigns.selected_id and event.status == :idle,
        do: refresh_changes(socket),
        else: socket

    {:noreply, socket}
  end

  # Patch one agent's `:status` in the global tree from a StatusChanged event.
  # The dot is computed at render time from this status + live liveness, so the
  # rail reflects reality the instant the transition fires.
  defp patch_tree_agent_status(tree, agent_id, status) when is_list(tree) do
    Enum.map(tree, fn project ->
      workspaces =
        Enum.map(project.workspaces, fn ws ->
          agents =
            Enum.map(ws.agents, fn a ->
              if a.id == agent_id, do: %{a | status: status}, else: a
            end)

          %{ws | agents: agents}
        end)

      %{project | workspaces: workspaces}
    end)
  end

  defp patch_tree_agent_status(tree, _id, _status), do: tree

  # This window's saved sidebar collapse state, or the default (current project
  # open) when nothing's saved yet / on the dead render.
  defp restore_expanded(socket, project_id) do
    saved = connected?(socket) && Loopyard.WindowViews.get_expanded(socket.transport_pid)

    case saved do
      keys when is_list(keys) -> MapSet.new(keys)
      _ -> LoopyardWeb.Components.GlobalSidebar.initial_expanded(project_id)
    end
  end

  # Async-fetch the selected agent's workspace working-tree changes for the
  # right-pane "Changes" hero (#58). No-op without a selected agent / project,
  # or when the source doesn't support git. Dispatches through the source
  # adapter (same path DataLoader uses).
  defp refresh_changes(socket) do
    project = socket.assigns[:project]
    ws = socket.assigns[:workspace_entry]

    with true <- socket.assigns[:selected_id] != nil,
         proj when not is_nil(proj) <- project,
         adapter <- Loopyard.Source.for_project(proj),
         true <- Loopyard.Source.supports_git?(adapter) do
      start_async(socket, :changes, fn -> adapter.git_status(proj, ws) end)
    else
      _ -> socket
    end
  end

  @impl Events.ChatAgent.Subscriber
  def on_quarantined(_event, socket), do: {:noreply, socket}

  @impl Events.ChatAgent.Subscriber
  def on_released(_event, socket), do: {:noreply, socket}

  # --- ChatAgentMessage subscriber callbacks ---

  @impl Events.ChatAgentMessage.Subscriber
  def on_message(%Events.ChatAgentMessage.Message{agent_id: id, msg: msg}, socket)
      when id == socket.assigns.selected_id do
    # Guard against duplicate messages (mobile reconnect can cause double PubSub subscriptions)
    if msg[:id] && Enum.any?(socket.assigns.messages, &(&1[:id] == msg[:id])) do
      {:noreply, socket}
    else
      socket =
        if msg.role == :assistant,
          do: socket |> assign(:streaming_text, "") |> assign(:streaming_thinking, ""),
          else: socket

      # If build was running and we get a post-build message, mark build as done
      socket =
        if socket.assigns.building && msg.role in [:system, :error] do
          messages =
            Enum.map(socket.assigns.messages, fn
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
        |> AgentEvents.refresh_selected_from_agents(id, socket.assigns.agents)
        |> push_event("scroll_bottom", %{})

      # Update thinking word when a tool message arrives — shows the
      # tool-specific phrase (e.g., "grepping" instead of "pondering")
      socket =
        if msg.role == :tool && socket.assigns.selected_agent &&
             socket.assigns.selected_agent.status == :thinking do
          tool = msg[:tool]
          word = LoopyardWeb.Components.Sidebar.thinking_word(id, tool)
          assign(socket, :thinking_word, word)
        else
          socket
        end

      {:noreply, socket}
    end
  end

  def on_message(%Events.ChatAgentMessage.Message{}, socket), do: {:noreply, socket}

  @impl Events.ChatAgentMessage.Subscriber
  def on_text_delta(%Events.ChatAgentMessage.TextDelta{agent_id: id, text: text}, socket)
      when id == socket.assigns.selected_id do
    {:noreply,
     socket
     |> AgentEvents.refresh_selected_from_agents(id, socket.assigns.agents)
     |> assign(:streaming_text, socket.assigns.streaming_text <> text)
     |> assign(:streaming_thinking, "")
     |> push_event("scroll_bottom", %{})}
  end

  def on_text_delta(%Events.ChatAgentMessage.TextDelta{}, socket), do: {:noreply, socket}

  @impl Events.ChatAgentMessage.Subscriber
  def on_stream_output(
        %Events.ChatAgentMessage.StreamOutput{
          agent_id: id,
          data: data,
          title: "__thinking__"
        },
        socket
      )
      when id == socket.assigns.selected_id do
    {:noreply,
     socket
     |> assign(:streaming_thinking, (socket.assigns[:streaming_thinking] || "") <> data)
     |> push_event("scroll_bottom", %{})}
  end

  def on_stream_output(
        %Events.ChatAgentMessage.StreamOutput{
          agent_id: id,
          data: data,
          title: title,
          msg_id: msg_id
        },
        socket
      )
      when id == socket.assigns.selected_id do
    upsert_stream_message(socket, data, title, msg_id)
  end

  def on_stream_output(%Events.ChatAgentMessage.StreamOutput{}, socket), do: {:noreply, socket}

  # --- DockerObserver subscriber callbacks ---
  # Logic extracted to DockerEvents — callbacks delegate there.

  @impl Events.DockerObserver.Subscriber
  def on_changed(event, socket), do: DockerEvents.handle_docker_changed(event, socket)

  @impl Events.DockerObserver.Subscriber
  def on_reset(event, socket), do: DockerEvents.handle_docker_reset(event, socket)

  @impl Events.DockerObserver.Subscriber
  def on_disconnected(event, socket), do: DockerEvents.handle_docker_disconnected(event, socket)

  @impl Events.DockerObserver.Subscriber
  def on_reconnected(event, socket), do: DockerEvents.handle_docker_reconnected(event, socket)

  # --- WorkspaceServices subscriber callbacks ---
  # Logic extracted to DockerEvents — callbacks delegate there.

  @impl Events.WorkspaceServices.Subscriber
  def on_compose_result(event, socket), do: DockerEvents.handle_compose_result(event, socket)

  @impl Events.WorkspaceServices.Subscriber
  def on_services_updated(event, socket), do: DockerEvents.handle_services_updated(event, socket)

  # --- Workspaces subscriber callback ---

  # A workspace added/removed/renamed → rebuild the god-mode sidebar tree so it
  # reflects the change live (a fork someone makes appears without a reload).
  @impl Events.Workspaces.Subscriber
  def on_workspaces_changed(_event, socket) do
    {:noreply, assign(socket, :global_tree, Loopyard.WorkspaceTree.global(socket.assigns.host))}
  end

  # --- SourceSync subscriber callbacks ---
  # Logic extracted to DockerEvents — callbacks delegate there.

  @impl Events.SourceSync.Subscriber
  def on_updated(event, socket), do: DockerEvents.handle_source_sync(event, socket)

  # --- WorkspaceSetup subscriber callbacks ---
  # Logic extracted to DockerEvents ��� callbacks delegate there.

  @impl Events.WorkspaceSetup.Subscriber
  def on_setup_started(event, socket), do: DockerEvents.handle_setup_started(event, socket)

  @impl Events.WorkspaceSetup.Subscriber
  def on_setup_phase_started(event, socket),
    do: DockerEvents.handle_setup_phase_started(event, socket)

  @impl Events.WorkspaceSetup.Subscriber
  def on_setup_phase_completed(event, socket),
    do: DockerEvents.handle_setup_phase_completed(event, socket)

  @impl Events.WorkspaceSetup.Subscriber
  def on_setup_phase_progress(event, socket),
    do: DockerEvents.handle_setup_phase_progress(event, socket)

  @impl Events.WorkspaceSetup.Subscriber
  def on_setup_completed(event, socket), do: DockerEvents.handle_setup_completed(event, socket)

  @impl Events.WorkspaceSetup.Subscriber
  def on_setup_failed(event, socket), do: DockerEvents.handle_setup_failed(event, socket)

  @impl Events.WorkspaceSetup.Subscriber
  def on_setup_retry_scheduled(event, socket),
    do: DockerEvents.handle_setup_retry_scheduled(event, socket)

  # Compose commands can take tens of seconds (restart/stop) to minutes
  # (start with image build). Running them inline in handle_event used
  # to block this LV — pending PubSub messages, other user events, all
  # queued for the duration. The docker_events stream picks up the
  # container transition and broadcasts :docker_state_changed when the
  # async task completes, so the sidebar updates without us waiting on
  # the Task result here. Fire and forget.
  defp run_compose_async(socket, args, timeout) do
    ws_id = socket.assigns.workspace_entry.id
    effective_dir = Loopyard.Workspace.compose_dir(ws_id)

    Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
      Loopyard.Compose.compose(effective_dir, ws_id, args, timeout: timeout)
    end)

    {:noreply, socket}
  end

  # --- Private ---

  defp upsert_stream_message(socket, data, title, msg_id) do
    stream_buffer =
      socket.assigns.stream_buffer
      |> StreamBuffer.append(data, title: title, msg_id: msg_id)

    messages = StreamBuffer.upsert_message(stream_buffer, socket.assigns.messages)

    {:noreply,
     socket
     |> assign(:messages, messages)
     |> assign(:stream_buffer, stream_buffer)
     |> assign(:building, true)}
  end

  defp workspace_path(socket), do: socket.assigns.base_path

  defp setup_volume(socket, name, tab) do
    is_code = String.contains?(name, "code")

    adapter =
      if socket.assigns[:project], do: Loopyard.Source.for_project(socket.assigns.project)

    supports_git = is_code && adapter && Loopyard.Source.supports_git?(adapter)

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

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="chat-page"
      phx-hook="ScrollBottom"
      class="h-screen flex flex-col bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
    >
      <.chat_header
        workspace={@workspace}
        project={@project}
        workspace_entry={@workspace_entry}
        live_action={@live_action}
        base_path={@base_path}
        iex_session={@iex_session}
      />
      <.flash_banner flash={@flash} kind={:error} class="mx-4 mt-2" />
      <div class="flex-1 flex min-h-0">
        <%!-- LEFT rail: god-mode tree — every project → workspace → agent, live
             across all projects (#55). Desktop-only. --%>
        <LoopyardWeb.Components.GlobalSidebar.global_sidebar
          tree={@global_tree}
          expanded={@expanded}
          current_workspace_id={@workspace.id}
          class="hidden md:flex w-72 flex-none border-r border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-900/50"
        />
        <%!-- Main content: hidden on mobile when the rail is showing (index/new with no selection) --%>
        <main
          id="main-content"
          class={"flex-1 flex flex-col min-w-0 #{if @live_action == :index && !@selected_id && !@selected_service, do: "hidden md:flex", else: "flex"}"}
        >
          <.main_content {assigns} />
        </main>
        <%!-- RIGHT rail: Agents/Services/Volumes nav + the selected agent's
             context (model, tokens, cost). The old left sidebar, flipped. --%>
        <.sidebar
          agents={@agents}
          selected_id={@selected_id}
          selected_agent={@selected_agent}
          changes={@changes}
          editing_name={@editing_name}
          container_env={@container_env}
          container_logs={@container_logs}
          workspace_id={@workspace.id}
          project={@project}
          workspace_entry={@workspace_entry}
          service_statuses={@service_statuses}
          selected_service={@selected_service}
          services_loaded={@services_loaded}
          volumes_loaded={@volumes_loaded}
          live_action={@live_action}
          volumes={@volumes}
          base_path={@base_path}
          host={@host}
          is_local_source?={@is_local_source?}
          sync_status={@sync_status}
          workspace_state={@workspace_state}
          workspace_state_since={@workspace_state_since}
          docker_connected?={@docker_connected?}
        />
      </div>
    </div>
    """
  end
end
