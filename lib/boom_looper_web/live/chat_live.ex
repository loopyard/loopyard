defmodule BoomLooperWeb.ChatLive do
  use BoomLooperWeb, :live_view
  use BoomLooperWeb.IExAware

  alias BoomLooper.ChatAgent
  alias BoomLooper.StreamBuffer

  use BoomLooperWeb.Live.ChatLive.Components
  alias BoomLooperWeb.Live.ChatLive.{AgentLifecycle, ServiceLogs, ComposeCheck}

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

      # Start workspace supervisor async — don't block mount
      send(self(), {:start_workspace, workspace.path})
    end

    socket = if connected?(socket), do: subscribe_iex(socket), else: assign(socket, :iex_session, %{level: nil})

    # Services + volumes come from Docker.Observer's ETS cache (instant,
    # zero docker calls). The sidebar renders immediately with real data.
    agents = AgentLifecycle.list_workspace_agents(workspace.path)
    ws_id = extra_assigns[:workspace_entry] && extra_assigns[:workspace_entry].id || workspace.id
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
     |> assign(:service_logs, "")
     |> assign(:all_service_logs, [])
     |> assign(:stream_buffer, StreamBuffer.new())
     |> assign(:building, false)
     |> assign(:console_container, nil)
     |> assign(:is_local_source?, is_local?)
     |> assign(:sync_status, initial_sync_status(workspace.id, is_local?))}
  end

  defp initial_sync_status(_workspace_id, false), do: nil

  defp initial_sync_status(workspace_id, true) do
    BoomLooper.Source.Local.SyncMonitor.status(workspace_id)
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: action}} = socket) do
    tab = if action == :container, do: :container, else: :chat

    socket =
      if socket.assigns.selected_id != id do
        case AgentLifecycle.select_agent(socket, id) do
          {:noreply, s} ->
            clear_flash(s)

          :not_found ->
            socket
            |> put_flash(:error, "Agent not found")
            |> push_navigate(to: workspace_path(socket))
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
        {:noreply, push_navigate(socket, to: "#{workspace_path(socket)}/agents/#{existing_setup.id}")}

      # Decision between "auto-launch setup" and "show new-agent picker"
      # depends on whether workspace.json exists in the code volume —
      # that's a docker exec/run. Defer it via start_async so the page
      # paints immediately. Picker renders by default; the auto-launch
      # branch fires from handle_async if has_config turns out false.
      socket.assigns.agents == [] ->
        {:noreply, ComposeCheck.kick_compose_check(socket, :new)}

      true ->
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

    if socket.assigns.agents == [] do
      # Empty workspace: we need to know whether docker-compose.yml exists
      # before deciding between auto-spawn and /new. Reading the volume is
      # a docker shell-out — DO NOT block handle_params on it. Kick it off
      # via start_async; the navigate happens from handle_async.
      {:noreply, ComposeCheck.kick_compose_check(socket, :index)}
    else
      {:noreply, socket}
    end
  end

  def handle_params(%{"volume_name" => name}, _uri, %{assigns: %{live_action: :volume}} = socket) do
    {:noreply,
     socket
     |> assign(:selected_id, nil)
     |> assign(:selected_agent, nil)
     |> assign(:selected_service, nil)
     |> assign(:selected_volume, name)}
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :sync}} = socket) do
    {:noreply,
     socket
     |> assign(:selected_id, nil)
     |> assign(:selected_agent, nil)
     |> assign(:selected_service, nil)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, :tab, :chat)}

  # --- Async compose check ---

  @impl true
  def handle_async(:compose_check, {:ok, %{origin: :index} = result}, socket) do
    cond do
      # Raced — agents arrived while we were waiting; just stay put.
      socket.assigns.agents != [] ->
        {:noreply, socket}

      socket.assigns.live_action != :index ->
        {:noreply, socket}

      !result.has_compose ->
        {:noreply, push_navigate(socket, to: "#{workspace_path(socket)}/new")}

      result.has_config ->
        # Compose file AND workspace.json exist but agents list is empty.
        # This means the workspace was set up before — agents just haven't
        # been restored from the ETF log yet (server restart). Do NOT
        # auto-spawn a new agent. Just stay on index and wait for restore.
        {:noreply, socket}

      true ->
        AgentLifecycle.do_spawn_agent(socket)
    end
  end

  def handle_async(:compose_check, {:ok, %{origin: :new} = result}, socket) do
    cond do
      socket.assigns.live_action != :new ->
        {:noreply, socket}

      socket.assigns.agents != [] ->
        {:noreply, socket}

      not result.has_config ->
        # No workspace.json AND no agents → truly fresh workspace, auto-launch Setup.
        AgentLifecycle.spawn_setup_agent(socket)

      true ->
        # Config exists — workspace was set up before. Don't auto-spawn.
        {:noreply, socket}
    end
  end

  def handle_async(:compose_check, {:exit, _reason}, socket) do
    # Failed to read the volume (docker hung, volume gone, etc.). Don't
    # block the user — let them stay on whatever page they're on.
    {:noreply, socket}
  end

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

  # --- Events ---

  @impl true
  def handle_event("select_agent", %{"id" => id}, socket) do
    tab = socket.assigns.tab
    bp = workspace_path(socket)
    path = if tab == :container, do: "#{bp}/agents/#{id}/container", else: "#{bp}/agents/#{id}"
    {:noreply, push_patch(socket, to: path) |> push_event("focus_input", %{})}
  end

  @impl true
  def handle_event("spawn_agent", %{"type" => "setup"}, socket) do
    AgentLifecycle.spawn_setup_agent(socket)
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
    ChatAgent.start_agent(id)
    {:noreply, socket}
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

  def handle_event("restart_service", %{"service_name" => name}, socket) do
    ws_id = socket.assigns.workspace_entry.id
    effective_dir = Path.join([BoomLooper.Workspace.home_dir(), "workspaces", ws_id])
    BoomLooper.Compose.compose(effective_dir, ws_id, ["restart", name], timeout: 30_000)
    {:noreply, socket}
  end

  def handle_event("delete_volume", %{"volume_name" => name}, socket) do
    BoomLooper.Docker.docker(["volume", "rm", name])
    BoomLooper.Docker.Observer.poll_now()
    {:noreply, push_navigate(socket, to: workspace_path(socket))}
  end

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

  @impl true
  def handle_info({:chat_agent_started, agent_summary}, socket) do
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

  @impl true
  def handle_info({:chat_agent_booting, summary}, socket) do
    {:noreply, assign(socket, :agents, AgentLifecycle.list_workspace_agents(socket.assigns.workspace.path))
     |> then(fn s ->
       if s.assigns.selected_id == summary.id do
         assign(s, booting_agent_id: summary.id, booting_agent_name: summary.name, boot_status: summary[:boot_status] || "Initializing...", boot_log: [])
       else
         s
       end
     end)}
  end

  @impl true
  def handle_info({:chat_agent_boot_status, id, status_text}, socket) do
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

  @impl true
  def handle_info({:chat_agent_boot_failed, id, reason}, socket) do
    socket = assign(socket, :agents, AgentLifecycle.list_workspace_agents(socket.assigns.workspace.path))

    socket =
      if socket.assigns.booting_agent_id == id || socket.assigns.selected_id == id do
        socket
        |> assign(:booting_agent_id, nil)
        |> put_flash(:error, "Failed to start agent: #{inspect(reason)}")
        |> push_navigate(to: workspace_path(socket))
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:chat_agent_stopped, _}, socket) do
    agents = AgentLifecycle.list_workspace_agents(socket.assigns.workspace.path)

    selected =
      if socket.assigns.selected_id,
        do: Enum.find(agents, &(&1.id == socket.assigns.selected_id))

    {:noreply, socket |> assign(:agents, agents) |> assign(:selected_agent, selected)}
  end

  @impl true
  def handle_info({:chat_agent_removed, id}, socket) do
    socket = assign(socket, :agents, AgentLifecycle.list_workspace_agents(socket.assigns.workspace.path))

    socket =
      if socket.assigns.selected_id == id do
        assign(socket, selected_id: nil, selected_agent: nil, messages: [])
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:chat_agent_renamed, id, new_name}, socket) do
    agents =
      Enum.map(socket.assigns.agents, fn a ->
        if a.id == id, do: %{a | name: new_name}, else: a
      end)

    socket = assign(socket, :agents, agents)

    socket =
      if id == socket.assigns.selected_id do
        selected = Enum.find(agents, &(&1.id == id))
        assign(socket, :selected_agent, selected)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:chat_agent_status_changed, id, status}, socket) do
    agents =
      Enum.map(socket.assigns.agents, fn a ->
        if a.id == id, do: %{a | status: status}, else: a
      end)

    socket = assign(socket, :agents, agents)

    socket =
      if id == socket.assigns.selected_id do
        selected = Enum.find(agents, &(&1.id == id))
        assign(socket, :selected_agent, selected)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:chat_message, id, msg}, socket) when id == socket.assigns.selected_id do
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

      {:noreply,
       socket
       |> assign(:messages, socket.assigns.messages ++ [msg])
       |> push_event("scroll_bottom", %{})}
    end
  end

  @impl true
  def handle_info({:chat_text_delta, id, text}, socket) when id == socket.assigns.selected_id do
    {:noreply,
     socket
     |> assign(:streaming_text, socket.assigns.streaming_text <> text)
     |> push_event("scroll_bottom", %{})}
  end


  @impl true
  def handle_info({:start_workspace, path}, socket) do
    workspace_id = BoomLooper.ProjectRegistry.workspace_id(path)

    # Start workspace in a Task so it doesn't block the LiveView process.
    # Service statuses will arrive via PubSub when ServiceManager starts.
    Task.Supervisor.start_child(BoomLooper.TaskSupervisor, fn ->
      BoomLooper.WorkspaceSupervisor.start_workspace(workspace_id, path)
      BoomLooper.ProjectRegistry.update_workspace_status(workspace_id, :running)
    end)

    {:noreply, socket}
  end

  # Docker.Observer broadcasts when container/volume state changes.
  # Re-derive sidebar state from the cache — zero docker calls.
  @impl true
  def handle_info({:docker_state_changed, _snapshot}, socket) do
    ws_id = socket.assigns.workspace_entry && socket.assigns.workspace_entry.id || socket.assigns.workspace.id
    {service_statuses, volumes} = load_sidebar_from_observer(socket.assigns.workspace.path, ws_id)

    {:noreply,
     socket
     |> assign(:service_statuses, service_statuses)
     |> assign(:volumes, volumes)}
  end

  def handle_info({:docker_state_reset}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:services_updated, path, _statuses}, socket) do
    if path == socket.assigns.workspace.path do
      ws_id = socket.assigns.workspace_entry && socket.assigns.workspace_entry.id || socket.assigns.workspace.id
      {service_statuses, _volumes} = load_sidebar_from_observer(path, ws_id)
      {:noreply, assign(socket, :service_statuses, service_statuses)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:source_sync, ws_id, status}, socket) do
    if ws_id == socket.assigns.workspace.id do
      {:noreply, assign(socket, :sync_status, status)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:build_output, id, data}, socket) when id == socket.assigns.selected_id do
    upsert_stream_message(socket, data, "Building Docker image...", nil)
  end

  @impl true
  def handle_info({:stream_output, id, data, title, msg_id}, socket) when id == socket.assigns.selected_id do
    upsert_stream_message(socket, data, title, msg_id)
  end

  @impl true
  def handle_info({:fetch_service_logs, service_name}, socket) do
    path = socket.assigns.workspace.path
    {:noreply, ServiceLogs.start_service_logs_fetch(socket, path, service_name)}
  end

  @impl true
  def handle_info(:fetch_all_service_logs, socket) do
    path = socket.assigns.workspace.path
    {:noreply, ServiceLogs.start_all_service_logs_fetch(socket, path)}
  end

  @impl true
  def handle_info(:refresh_service_logs, socket) do
    case socket.assigns.live_action do
      :service ->
        path = socket.assigns.workspace.path
        ServiceLogs.schedule_log_refresh()
        {:noreply, ServiceLogs.start_service_logs_fetch(socket, path, socket.assigns.selected_service)}

      :services ->
        path = socket.assigns.workspace.path
        ServiceLogs.schedule_log_refresh()
        {:noreply, ServiceLogs.start_all_service_logs_fetch(socket, path)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:service_logs_fetched, service_name, service_statuses, logs}, socket) do
    socket =
      socket
      |> assign(:service_statuses, service_statuses)
      |> then(fn s ->
        if s.assigns[:selected_service] == service_name, do: assign(s, :service_logs, logs), else: s
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:all_service_logs_fetched, service_statuses, all_logs}, socket) do
    {:noreply,
     socket
     |> assign(:service_statuses, service_statuses)
     |> assign(:all_service_logs, all_logs)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Private ---

  defp upsert_stream_message(socket, data, title, msg_id) do
    stream_buffer = socket.assigns.stream_buffer
      |> StreamBuffer.append(data, title: title, msg_id: msg_id)

    messages = StreamBuffer.upsert_message(stream_buffer, socket.assigns.messages)

    {:noreply, socket |> assign(:messages, messages) |> assign(:stream_buffer, stream_buffer) |> assign(:building, true)}
  end

  defp workspace_path(socket), do: socket.assigns.base_path

  # Derive sidebar service + volume state from Docker.Observer's ETS
  # cache. Zero docker calls — microsecond reads. The Observer
  # maintains the cache via the `docker events` stream.
  #
  # Services: read docker-compose.yml (fast local file) for DEFINED
  # services, then merge running state from Observer's container list.
  # Volumes: directly from Observer's volume list for this workspace.
  defp load_sidebar_from_observer(workspace_path, workspace_id) do
    # Defined services from the compose file (fast — local file read)
    defined = BoomLooper.Workspace.ServiceStatus.list_defined_services(workspace_path)

    # Running state from Observer's cached container list
    project_name = BoomLooper.Compose.project_name(workspace_id)
    observer_containers = BoomLooper.Docker.Observer.containers_for(workspace_id)

    service_statuses =
      if defined != [] do
        Enum.map(defined, fn svc ->
          container_name = "#{project_name}-#{svc.name}-1"
          container = Enum.find(observer_containers, &(&1.name == container_name))

          if container && container.running do
            struct!(svc, %{
              status: :running,
              container: container_name,
              ports: container.host_ports || %{}
            })
          else
            struct!(svc, %{status: :stopped, container: container_name})
          end
        end)
      else
        # No compose file yet — derive from Observer containers directly
        observer_containers
        |> Enum.reject(&(String.ends_with?(&1.name, "-workspace-1")))
        |> Enum.map(fn c ->
          service_name = c.name
            |> String.replace_prefix("#{project_name}-", "")
            |> String.replace_suffix("-1", "")

          %BoomLooper.Workspace.ServiceStatus.Service{
            name: service_name,
            type: :process,
            status: if(c.running, do: :running, else: :stopped),
            container: c.name,
            ports: c.host_ports || %{}
          }
        end)
      end

    volumes =
      BoomLooper.Docker.Observer.volumes_for(workspace_id)
      |> Enum.map(fn v ->
        %{name: v.name, type: v.type, service: v.service, description: v.description}
      end)

    {service_statuses, volumes}
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
      <.chat_header workspace={@workspace} project={@project} workspace_entry={@workspace_entry} agent_count={length(@agents)} live_action={@live_action} base_path={@base_path} iex_session={@iex_session} />
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
        />
        <%!-- Main content: hidden on mobile when sidebar is showing (index/new with no selection) --%>
        <main class={"flex-1 flex flex-col min-w-0 #{if @live_action in [:index, :new] && !@selected_id && !@selected_service, do: "hidden md:flex", else: "flex"}"}>
          <.new_agent_screen :if={@live_action == :new} workspace={@workspace} base_path={@base_path} />
          <.service_log_view :if={@live_action == :service} service_name={@selected_service} service_statuses={@service_statuses} logs={@service_logs} base_path={@base_path} host={@host} />
          <.console_view :if={@live_action == :console} service_name={@selected_service} container={@console_container} />
          <.all_services_view :if={@live_action == :services} all_service_logs={@all_service_logs} />
          <.volume_detail :if={@live_action == :volume} volume_name={@selected_volume} volumes={@volumes} workspace_id={@workspace.id} base_path={@base_path} />
          <.sync_detail :if={@live_action == :sync} sync_status={@sync_status} workspace_id={@workspace.id} workspace={@workspace} />
          <.booting_screen :if={@live_action not in [:new, :service, :services, :console, :volume, :sync] && @booting_agent_id && !@selected_agent} agent_id={@booting_agent_id} status={@boot_status} boot_log={@boot_log} />
          <.empty_state :if={@live_action not in [:new, :service, :services, :console, :volume, :sync] && !@booting_agent_id && !@selected_agent} />
          <.agent_view :if={@live_action not in [:new, :service, :services, :console, :volume, :sync] && @selected_agent} {assigns} />
        </main>
      </div>
    </div>
    """
  end
end
