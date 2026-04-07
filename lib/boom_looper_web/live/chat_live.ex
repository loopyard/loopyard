defmodule BoomLooperWeb.ChatLive do
  use BoomLooperWeb, :live_view
  use BoomLooperWeb.IExAware

  alias BoomLooper.ChatAgent
  alias BoomLooper.StreamBuffer
  import BoomLooperWeb.Components.LogViewer
  import BoomLooperWeb.Components.Sidebar, only: [
    status_dot: 1, service_dot: 1, service_detail: 1, first_host_port: 1, thinking_word: 1
  ]

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
    if connected?(socket) do
      ChatAgent.subscribe()
      BoomLooper.Workspace.ServiceManager.subscribe()

      # Start workspace supervisor async — don't block mount
      send(self(), {:start_workspace, workspace.path})
      # Fetch service status async — Docker can be slow, never block mount
      send(self(), :fetch_service_status)
      # Fetch volumes async
      send(self(), :fetch_volumes)
    end

    socket = if connected?(socket), do: subscribe_iex(socket), else: assign(socket, :iex_session, %{level: nil})

    # Mount instantly with agents. Service status loads async (Docker can be slow).
    agents = list_workspace_agents(workspace.path)
    service_statuses = []

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
     |> assign(:services_loaded, false)
     |> assign(:volumes_loaded, false)
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
     |> assign(:service_logs, "")
     |> assign(:all_service_logs, [])
     |> assign(:stream_buffer, StreamBuffer.new())
     |> assign(:building, false)
     |> assign(:console_container, nil)
     |> assign(:volumes, [])}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: action}} = socket) do
    tab = if action == :container, do: :container, else: :chat

    socket =
      if socket.assigns.selected_id != id do
        case select_agent(socket, id) do
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
        {:noreply, kick_compose_check(socket, :new)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_params(%{"service_name" => service_name}, _uri, %{assigns: %{live_action: :service}} = socket) do
    # Fetch logs async so the page loads immediately
    send(self(), {:fetch_service_logs, service_name})
    schedule_log_refresh()

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
      svc && Map.get(svc, :type) == :process ->
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
    schedule_log_refresh()

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
      {:noreply, kick_compose_check(socket, :index)}
    else
      {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, :tab, :chat)}

  # --- Async compose check ---
  #
  # The :index and :new actions need to know whether `docker-compose.yml`
  # exists in the workspace's code volume before deciding what to do
  # (auto-spawn vs push to /new vs auto-launch Setup). Reading from a
  # volume is a docker exec/run — never run it inline in handle_params.
  #
  # `kick_compose_check/2` starts a Task that does the read and tags the
  # result with the originating action. `handle_async(:compose_check, ...)`
  # picks up the result and dispatches the navigation. If the user has
  # navigated elsewhere by the time the result lands, the assigns will
  # have changed and the dispatch is a no-op.

  defp kick_compose_check(socket, origin) do
    workspace = socket.assigns.workspace
    start_async(socket, :compose_check, fn ->
      ws_id = BoomLooper.Workspace.workspace_id(workspace.path)
      volume_name = BoomLooper.Workspace.volume_name_for(ws_id)
      has_compose = match?({:ok, _},
        BoomLooper.VolumeManager.read_file(volume_name, ".boomlooper/workspace/docker-compose.yml"))
      has_workspace_json = match?({:ok, _},
        BoomLooper.Workspace.load_from_volume("code-#{ws_id}"))
      %{origin: origin, has_compose: has_compose, has_config: has_workspace_json}
    end)
  end

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

      true ->
        do_spawn_agent(socket)
    end
  end

  def handle_async(:compose_check, {:ok, %{origin: :new} = result}, socket) do
    cond do
      socket.assigns.live_action != :new ->
        {:noreply, socket}

      socket.assigns.agents != [] ->
        {:noreply, socket}

      not result.has_config ->
        # No workspace.json AND no agents → auto-launch Setup agent.
        spawn_setup_agent(socket)

      true ->
        # Config exists, just show the picker.
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

  defp spawn_setup_agent(socket) do
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
    Task.start(fn -> BoomLooper.AgentBoot.boot(id, agent_opts) end)

    {:noreply, push_navigate(socket, to: "#{workspace_path(socket)}/agents/#{id}")}
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
  def handle_event("spawn_agent", _params, socket) do
    do_spawn_agent(socket)
  end

  @impl true
  def handle_event("spawn_service_agent", %{"service_name" => service_name}, socket) do
    do_spawn_agent(socket, service_name: service_name)
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
    tab = String.to_existing_atom(tab)
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
    socket = assign(socket, :agents, list_workspace_agents(socket.assigns.workspace.path))

    if socket.assigns.booting_agent_id && agent_summary.id == socket.assigns.booting_agent_id do
      socket = assign(socket, :booting_agent_id, nil)

      if socket.assigns.selected_id == agent_summary.id do
        case select_agent(socket, agent_summary.id) do
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
    {:noreply, assign(socket, :agents, list_workspace_agents(socket.assigns.workspace.path))
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
    socket = assign(socket, :agents, list_workspace_agents(socket.assigns.workspace.path))

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
    agents = list_workspace_agents(socket.assigns.workspace.path)

    selected =
      if socket.assigns.selected_id,
        do: Enum.find(agents, &(&1.id == socket.assigns.selected_id))

    {:noreply, socket |> assign(:agents, agents) |> assign(:selected_agent, selected)}
  end

  @impl true
  def handle_info({:chat_agent_removed, id}, socket) do
    socket = assign(socket, :agents, list_workspace_agents(socket.assigns.workspace.path))

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
    Task.start(fn ->
      BoomLooper.WorkspaceSupervisor.start_workspace(workspace_id, path)
      BoomLooper.ProjectRegistry.update_workspace_status(workspace_id, :running)
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:fetch_service_status, socket) do
    # Fetch service status in a Task so Docker slowness doesn't block the LiveView.
    path = socket.assigns.workspace.path
    lv_pid = self()

    Task.start(fn ->
      statuses = BoomLooper.Workspace.ServiceStatus.for_workspace(path)
      send(lv_pid, {:service_status_result, statuses})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:service_status_result, statuses}, socket) do
    {:noreply, socket |> assign(:service_statuses, statuses) |> assign(:services_loaded, true)}
  end

  @impl true
  def handle_info(:fetch_volumes, socket) do
    workspace_id = socket.assigns.workspace_entry.id
    lv_pid = self()

    Task.start(fn ->
      volumes = case BoomLooper.VolumeManager.list_workspace_volumes(workspace_id) do
        {:ok, vols} -> vols
        _ -> []
      end
      send(lv_pid, {:volumes_result, volumes})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:volumes_result, volumes}, socket) do
    {:noreply, socket |> assign(:volumes, volumes) |> assign(:volumes_loaded, true)}
  end

  @impl true
  def handle_info({:services_updated, path, _statuses}, socket) do
    if path == socket.assigns.workspace.path do
      # Re-query actual state via ServiceStatus (reliable, no stale PubSub data)
      service_statuses = BoomLooper.Workspace.ServiceStatus.for_workspace(path)
      {:noreply, assign(socket, :service_statuses, service_statuses)}
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
    # Get fresh service status - don't rely on potentially stale socket assigns
    service_statuses = BoomLooper.Workspace.ServiceStatus.for_workspace(socket.assigns.workspace.path)
    logs = fetch_service_container_logs(service_statuses, service_name)
    # Also update the service_statuses in assigns so sidebar stays current
    {:noreply, socket |> assign(:service_logs, logs) |> assign(:service_statuses, service_statuses)}
  end

  @impl true
  def handle_info(:fetch_all_service_logs, socket) do
    # Get fresh service status
    service_statuses = BoomLooper.Workspace.ServiceStatus.for_workspace(socket.assigns.workspace.path)
    all_logs = fetch_all_service_logs(service_statuses)
    {:noreply, socket |> assign(:all_service_logs, all_logs) |> assign(:service_statuses, service_statuses)}
  end

  @impl true
  def handle_info(:refresh_service_logs, socket) do
    case socket.assigns.live_action do
      :service ->
        logs = fetch_service_container_logs(socket.assigns.service_statuses, socket.assigns.selected_service)
        schedule_log_refresh()
        {:noreply, assign(socket, :service_logs, logs)}

      :services ->
        all_logs = fetch_all_service_logs(socket.assigns.service_statuses)
        schedule_log_refresh()
        {:noreply, assign(socket, :all_service_logs, all_logs)}

      _ ->
        {:noreply, socket}
    end
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

  defp do_spawn_agent(socket, opts \\ []) do
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
    Task.start(fn -> BoomLooper.AgentBoot.boot(id, agent_opts, service_name: service_name) end)

    {:noreply, push_navigate(socket, to: "#{workspace_path(socket)}/agents/#{id}")}
  end

  defp workspace_path(socket), do: socket.assigns.base_path

  defp fetch_service_container_logs(service_statuses, service_name) do
    case Enum.find(service_statuses, &(&1.name == service_name)) do
      %{container: container} = svc ->
        case BoomLooper.Docker.docker(["logs", "--tail", "200", container], timeout: 5_000) do
          {:ok, ""} ->
            if svc.status == :running, do: "(no output yet)", else: "(container exited with no output)"
          {:ok, output} -> output
          {:error, _} -> "(could not fetch logs)"
        end

      nil ->
        "(container not found)"
    end
  catch
    :exit, _ -> "(could not fetch logs)"
  end

  defp fetch_all_service_logs(service_statuses) do
    Enum.map(service_statuses, fn svc ->
      logs =
        case BoomLooper.Docker.docker(["logs", "--tail", "50", svc.container], timeout: 5_000) do
          {:ok, output} -> output
          {:error, _} -> ""
        end

      %{name: svc.name, logs: logs}
    end)
  catch
    :exit, _ -> []
  end

  defp schedule_log_refresh do
    Process.send_after(self(), :refresh_service_logs, 3_000)
  end

  defp list_workspace_agents(workspace_path) do
    ChatAgent.list_agents()
    |> Enum.filter(fn a ->
      a[:bind_mount] == workspace_path || a[:working_dir] == workspace_path
    end)
  end

  defp select_agent(socket, id) do
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
              case BoomLooper.Tools.Container.do_logs(id, log_opts) do
                {:ok, output} -> output
                {:error, err} -> "Error: #{err}"
              end

            env =
              case BoomLooper.Tools.Container.do_inspect(id) do
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


  # boot_agent logic extracted to BoomLooper.AgentBoot

  @adjectives ~w(Swift Bright Calm Deep Quick Sharp Keen Bold Clear True)
  @nouns ~w(Spark Drift Pulse Wave Bloom Forge Sage Fern Tide Mesa)

  defp auto_name do
    adj = Enum.random(@adjectives)
    noun = Enum.random(@nouns)
    "#{adj} #{noun}"
  end

  # These are only used inline in chat_live templates, not in sidebar components
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

  defp msg_url(assigns) do
    msg_id = assigns.msg[:id]
    if msg_id do
      BoomLooperWeb.OutputController.msg_url(assigns.agent_id, msg_id)
    end
  end



  defp hash_content(content) when is_binary(content) do
    :erlang.phash2(content, 0xFFFFFF) |> Integer.to_string(16)
  end

  defp time_ago(nil), do: ""

  defp time_ago(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      true -> "#{div(diff, 3600)}h ago"
    end
  end

  defp tool_summary(tool_name, input) when is_map(input) do
    clean_name = tool_name |> String.replace(~r/^mcp__[\w-]+__/, "")

    case {clean_name, input} do
      {"Read", %{"file_path" => path}} -> "Read #{shorten_path(path)}"
      {"Write", %{"file_path" => path}} -> "Wrote #{shorten_path(path)}"
      {"Edit", %{"file_path" => path}} -> "Edited #{shorten_path(path)}"
      {"Bash", %{"command" => cmd}} -> "$ #{String.slice(cmd, 0..80)}"
      {"Grep", %{"pattern" => pat}} -> "Searched for \"#{pat}\""
      {"Glob", %{"pattern" => pat}} -> "Found files matching #{pat}"
      {"Agent", %{"prompt" => p}} -> "Spawned agent: #{String.slice(p, 0..60)}"
      {"list_agents", _} -> "Listed all agents"
      {"spawn_agent", %{"name" => n}} -> "Spawned agent #{n}"
      {"send_message_to_agent", %{"agent_id" => id}} -> "Sent message to agent #{String.slice(id, 0..8)}"
      {"stop_agent", %{"agent_id" => id}} -> "Stopped agent #{String.slice(id, 0..8)}"
      {"exec", %{"command" => cmd}} -> "container $ #{String.slice(cmd, 0..80)}"
      {"logs", _} -> "Checked container logs"
      {"inspect_env", _} -> "Inspected container environment"
      {"start_service", %{"name" => n, "command" => cmd}} -> "Started service #{n}: #{String.slice(cmd, 0..60)}"
      {"start_service", %{"name" => n}} -> "Started service #{n}"
      {"ports", _} -> "Listed container ports"
      {"set_dockerfile", _} -> "Updated Dockerfile"
      {"set_dev_command", %{"command" => cmd}} -> "Dev command: #{String.slice(cmd, 0..60)}"
      {"set_dev_command", _} -> "Set dev command"
      {"add_service", %{"name" => n}} -> "Added service: #{n}"
      {"remove_service", %{"name" => n}} -> "Removed service: #{n}"
      {"set_env_vars", _} -> "Updated environment variables"
      {"set_workspace_name", %{"name" => n}} -> "Named project: #{n}"
      {"set_system_prompt", _} -> "Updated system prompt"
      {"start_services", _} -> "Started services"
      {"stop_services", _} -> "Stopped services"
      {"rebuild", _} -> "Rebuilding..."
      {"service_status", _} -> "Checked service status"
      {"list_secrets", _} -> "Listed available secrets"
      {"get_secret", %{"key" => k}} -> "Retrieved secret: #{k}"
      {name, _} -> name |> String.replace("_", " ") |> String.capitalize()
    end
  end

  defp tool_summary(tool_name, _input), do: tool_name

  defp format_tool_result(content) do
    case Jason.decode(content) do
      {:ok, parsed} when is_map(parsed) ->
        Jason.encode!(parsed, pretty: true)
      _ ->
        content
    end
  end

  # =============================================
  # Components
  # =============================================

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
        />
        <%!-- Main content: hidden on mobile when sidebar is showing (index/new with no selection) --%>
        <main class={"flex-1 flex flex-col min-w-0 #{if @live_action in [:index, :new] && !@selected_id && !@selected_service, do: "hidden md:flex", else: "flex"}"}>
          <.new_agent_screen :if={@live_action == :new} workspace={@workspace} base_path={@base_path} />
          <.service_log_view :if={@live_action == :service} service_name={@selected_service} service_statuses={@service_statuses} logs={@service_logs} base_path={@base_path} host={@host} />
          <.console_view :if={@live_action == :console} service_name={@selected_service} container={@console_container} />
          <.all_services_view :if={@live_action == :services} all_service_logs={@all_service_logs} />
          <.booting_screen :if={@live_action not in [:new, :service, :services, :console] && @booting_agent_id && !@selected_agent} agent_id={@booting_agent_id} status={@boot_status} boot_log={@boot_log} />
          <.empty_state :if={@live_action not in [:new, :service, :services, :console] && !@booting_agent_id && !@selected_agent} />
          <.agent_view :if={@live_action not in [:new, :service, :services, :console] && @selected_agent} {assigns} />
        </main>
      </div>
    </div>
    """
  end

  defp chat_header(assigns) do
    # Mobile back button has two modes:
    #   - viewing an agent/service → patch back to the sidebar (Menu)
    #   - viewing the sidebar/new screen → navigate up to the project page
    {back_kind, back_target, back_label} =
      cond do
        assigns.live_action in [:chat, :container, :service, :console, :services] ->
          {:patch, assigns.base_path, "Menu"}

        assigns.project ->
          {:navigate, "/projects/#{assigns.project.id}", assigns.project.name}

        true ->
          {:navigate, "/", "Projects"}
      end

    assigns =
      assigns
      |> assign(:back_kind, back_kind)
      |> assign(:back_target, back_target)
      |> assign(:back_label, back_label)

    ~H"""
    <header class="flex-none h-14 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center justify-between px-4 md:px-5">
      <div class="flex items-center gap-3 min-w-0">
        <.link
          :if={@back_kind == :patch}
          patch={@back_target}
          class="md:hidden -ml-1 inline-flex items-center gap-1 px-2 py-1 rounded-md text-sm font-medium text-violet-600 dark:text-violet-400 hover:bg-violet-50 dark:hover:bg-violet-500/10 active:bg-violet-100 dark:active:bg-violet-500/20 transition-colors flex-none min-w-0"
        >
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5 flex-none">
            <path fill-rule="evenodd" d="M17 10a.75.75 0 0 1-.75.75H5.612l4.158 3.96a.75.75 0 1 1-1.04 1.08l-5.5-5.25a.75.75 0 0 1 0-1.08l5.5-5.25a.75.75 0 1 1 1.04 1.08L5.612 9.25H16.25A.75.75 0 0 1 17 10Z" clip-rule="evenodd" />
          </svg>
          <span class="truncate">{@back_label}</span>
        </.link>
        <.link
          :if={@back_kind == :navigate}
          navigate={@back_target}
          class="md:hidden -ml-1 inline-flex items-center gap-1 px-2 py-1 rounded-md text-sm font-medium text-violet-600 dark:text-violet-400 hover:bg-violet-50 dark:hover:bg-violet-500/10 active:bg-violet-100 dark:active:bg-violet-500/20 transition-colors flex-none min-w-0"
        >
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5 flex-none">
            <path fill-rule="evenodd" d="M17 10a.75.75 0 0 1-.75.75H5.612l4.158 3.96a.75.75 0 1 1-1.04 1.08l-5.5-5.25a.75.75 0 0 1 0-1.08l5.5-5.25a.75.75 0 1 1 1.04 1.08L5.612 9.25H16.25A.75.75 0 0 1 17 10Z" clip-rule="evenodd" />
          </svg>
          <span class="truncate">{@back_label}</span>
        </.link>
        <.link navigate="/" class="text-sm font-semibold tracking-tight hover:text-violet-600 dark:hover:text-violet-400 transition-colors hidden md:block">Boom Looper</.link>
        <span class="text-zinc-300 dark:text-zinc-600 hidden md:block">/</span>
        <.link :if={@project} navigate={"/projects/#{@project.id}"} class="text-sm font-medium hover:text-violet-600 dark:hover:text-violet-400 transition-colors truncate">{@workspace.name}</.link>
        <span :if={!@project} class="text-sm font-medium truncate">{@workspace.name}</span>
        <span :if={@workspace_entry && !@workspace_entry[:is_main]} class="text-zinc-300 dark:text-zinc-600 hidden sm:block">/</span>
        <span :if={@workspace_entry && !@workspace_entry[:is_main]} class="text-sm text-zinc-500 dark:text-zinc-400 hidden sm:block truncate">{@workspace_entry.name}</span>
        <span class="text-sm text-zinc-400 dark:text-zinc-500 hidden sm:block flex-none">{@agent_count} agent{if @agent_count != 1, do: "s"}</span>
        <BoomLooperWeb.Components.AppHeader.iex_indicator :if={@iex_session.level} session={@iex_session} />
      </div>
      <div class="flex items-center gap-4 flex-none hidden md:flex">
        <.link navigate="/connect" class="text-xs text-zinc-400 dark:text-zinc-500 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors">Remote</.link>
        <.link navigate="/system" class="text-xs text-zinc-400 dark:text-zinc-500 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors">System</.link>
      </div>
    </header>
    """
  end

  defp sidebar(assigns) do
    base_path = if assigns.project do
      "/projects/#{assigns.project.id}/workspaces/#{assigns.workspace_entry.id}"
    else
      "/projects/#{assigns.workspace_id}/workspaces/#{assigns.workspace_id}"
    end
    assigns = assign(assigns, :base_path, base_path)

    ~H"""
    <%!-- On mobile: full-width when visible (index/new), hidden when agent/service selected.
         On md+: always visible as a fixed-width sidebar. --%>
    <aside class={[
      "flex-none border-r border-zinc-200 dark:border-zinc-700/80 flex flex-col bg-zinc-50 dark:bg-zinc-900/50",
      "w-full md:w-80",
      if(@live_action in [:chat, :container, :service, :console, :services] || @selected_id || @selected_service,
        do: "hidden md:flex",
        else: "flex")
    ]}>
      <div class="flex-none p-3 border-b border-zinc-200 dark:border-zinc-700/80">
        <.link
          navigate={"#{@base_path}/new"}
          class="w-full inline-flex items-center justify-center gap-1.5 rounded-lg border border-zinc-200 dark:border-zinc-700 px-3.5 py-2 text-sm font-medium text-zinc-600 dark:text-zinc-400
                 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors"
        >
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4">
            <path d="M8.75 3.75a.75.75 0 0 0-1.5 0v3.5h-3.5a.75.75 0 0 0 0 1.5h3.5v3.5a.75.75 0 0 0 1.5 0v-3.5h3.5a.75.75 0 0 0 0-1.5h-3.5v-3.5Z" />
          </svg>
          New Agent
        </.link>
      </div>
      <div class="flex-1 overflow-y-auto">
        <%!-- Agents section - always show header --%>
        <div class="px-3 pt-3 pb-1">
          <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 font-semibold mb-1.5">Agents</div>
          <div :if={@agents != []} class="space-y-0.5">
            <.agent_list_item :for={agent <- @agents} agent={agent} selected={@selected_id == agent.id} />
          </div>
          <p :if={@agents == []} class="text-xs text-zinc-400 dark:text-zinc-500 py-1">No agents</p>
        </div>

        <%!-- Services section - only show when services exist or still loading --%>
        <div :if={@service_statuses != [] || !@services_loaded} class="px-3 pt-3 pb-1">
          <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 font-semibold mb-1.5">Services</div>
          <div :if={@service_statuses != []} class="space-y-0.5">
            <.service_item :for={svc <- @service_statuses} svc={svc} base_path={@base_path} selected={@selected_service == svc.name} host={@host} />
          </div>
          <p :if={!@services_loaded} class="text-xs text-zinc-400 dark:text-zinc-500 py-1">Loading...</p>
        </div>

        <%!-- Volumes section - always show header --%>
        <div class="px-3 pt-3 pb-1">
          <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 font-semibold mb-1.5">Volumes</div>
          <div :if={@volumes != []} class="space-y-0.5">
            <.volume_item :for={vol <- @volumes} vol={vol} base_path={@base_path} />
          </div>
          <p :if={!@volumes_loaded} class="text-xs text-zinc-400 dark:text-zinc-500 py-1">Loading...</p>
          <p :if={@volumes_loaded && @volumes == []} class="text-xs text-zinc-400 dark:text-zinc-500 py-1">No volumes</p>
        </div>
      </div>
    </aside>
    """
  end

  # --- New Agent Screen ---

  defp new_agent_screen(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto p-6 md:p-8">
      <div class="max-w-2xl mx-auto">
        <h2 class="text-xl font-semibold text-zinc-900 dark:text-zinc-100 mb-1">New Agent</h2>
        <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-6">Launch a new agent to work on this project.</p>

        <form phx-submit="spawn_agent">
          <button type="submit"
            class="rounded-xl bg-zinc-900 dark:bg-zinc-100 px-6 py-3 text-sm font-medium text-white dark:text-zinc-900
                   hover:bg-zinc-700 dark:hover:bg-zinc-300 transition-colors">
            Launch Agent
          </button>
        </form>

        <div class="mt-6">
          <.link navigate={@base_path} class="text-sm text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 transition-colors">Cancel</.link>
        </div>
      </div>
    </div>
    """
  end

  # --- Sidebar ---

  defp service_item(assigns) do
    first_port = first_host_port(assigns.svc[:ports])
    assigns = assign(assigns, :first_port, first_port)

    ~H"""
    <div class={"flex items-center gap-2 px-2 py-1.5 rounded text-sm transition-colors #{if @selected, do: "bg-white dark:bg-zinc-800 shadow-sm", else: "hover:bg-white/60 dark:hover:bg-zinc-800/40"}"}>
      <.link navigate={"#{@base_path}/services/#{@svc.name}"} class="flex items-center gap-2 min-w-0 flex-1">
        <div class={"w-1.5 h-1.5 rounded-full flex-none #{service_dot(@svc)}"}></div>
        <span class="truncate text-zinc-600 dark:text-zinc-400">{@svc.name}</span>
      </.link>
      <a :if={@first_port && Map.get(@svc, :status) == :running} href={"http://#{@host}:#{@first_port}"} target="_blank"
        class="text-[10px] text-violet-500 hover:text-violet-400 font-mono ml-auto flex-none transition-colors">
        :{@first_port}
      </a>
      <span :if={service_status_text(@svc)} class="text-[10px] text-blue-400 ml-auto flex-none">{service_status_text(@svc)}</span>
      <span :if={!service_status_text(@svc) && !@first_port && @svc.status == :running} class="text-[10px] text-zinc-400 dark:text-zinc-500 ml-auto font-mono truncate max-w-[100px]">{service_detail(@svc)}</span>
      <span :if={@svc.status == :crashed && @svc[:exit_info]} class="text-[10px] text-red-500 ml-auto truncate max-w-[140px]">{exit_reason(@svc.exit_info)}</span>
    </div>
    """
  end

  defp volume_item(assigns) do
    # Use description from volume_info if available, otherwise derive from name
    description = assigns.vol[:description] || derive_volume_description(assigns.vol.name)
    service = assigns.vol[:service]

    assigns = assigns
    |> assign(:description, description)
    |> assign(:service, service)

    ~H"""
    <div class="flex items-center gap-2 px-2 py-1.5 rounded text-sm transition-colors hover:bg-white/60 dark:hover:bg-zinc-800/40">
      <div class="flex items-center gap-2 min-w-0 flex-1">
        <div class="w-1.5 h-1.5 rounded-full flex-none bg-blue-400"></div>
        <div class="min-w-0 flex-1">
          <span class="truncate text-zinc-600 dark:text-zinc-400 block">{@description}</span>
          <span :if={@service && @service != "workspace"} class="text-[10px] text-zinc-400 dark:text-zinc-500">{@service}</span>
        </div>
      </div>
      <span class="text-[10px] text-zinc-400 dark:text-zinc-500 font-mono flex-none">{@vol.size}</span>
    </div>
    """
  end

  defp derive_volume_description(name) do
    # Fallback for volumes without explicit description
    cond do
      String.contains?(name, "code") -> "Source code"
      String.contains?(name, "cache") -> "Build cache"
      String.contains?(name, "deps") -> "Dependencies"
      String.contains?(name, "postgres") -> "PostgreSQL data"
      String.contains?(name, "redis") -> "Redis data"
      String.contains?(name, "minio") -> "MinIO storage"
      true -> name
    end
  end

  defp agent_list_item(assigns) do
    ~H"""
    <button
      phx-click="select_agent"
      phx-value-id={@agent.id}
      class={"w-full text-left px-2 py-1.5 rounded text-sm transition-colors
             #{if @selected, do: "bg-white dark:bg-zinc-800 shadow-sm", else: "hover:bg-white/60 dark:hover:bg-zinc-800/40"}"}
    >
      <div class="flex items-center gap-2">
        <div class={"w-1.5 h-1.5 rounded-full flex-none #{status_dot(@agent.status)}"}></div>
        <span class="truncate text-zinc-600 dark:text-zinc-400">{@agent.name}</span>
        <span :if={@agent.status == :booting} class="text-xs text-violet-400 flex-none">booting</span>
        <span :if={@agent.status == :thinking} class="text-xs text-amber-500 flex-none">{thinking_word(@agent.id)}</span>
        <span :if={@agent.status == :destroying} class="text-xs text-red-400 flex-none">destroying</span>
        <span :if={@agent.status in [:stopped, :crashed]}
          phx-click="remove_agent" phx-value-id={@agent.id}
          class="ml-auto text-xs text-zinc-400 hover:text-red-500 dark:hover:text-red-400 flex-none transition-colors"
          title="Remove agent">
          &times;
        </span>
      </div>
      <div :if={@agent.status == :booting} class="mt-1 ml-[18px] text-xs text-zinc-400 dark:text-zinc-500 truncate">{@agent[:boot_status] || "Initializing..."}</div>
    </button>
    """
  end

  defp booting_screen(assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center">
      <div class="text-center max-w-sm">
        <div class="w-16 h-16 rounded-2xl bg-violet-100 dark:bg-violet-900/30 flex items-center justify-center mx-auto mb-4">
          <svg class="w-7 h-7 text-violet-500 animate-spin" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
            <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
          </svg>
        </div>
        <h3 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100 mb-1">Starting agent</h3>
        <p class="text-xs text-zinc-400 dark:text-zinc-500 font-mono mb-3">{@agent_id}</p>
        <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-4">{@status}</p>
        <details :if={@boot_log != []} class="text-left">
          <summary class="text-xs text-zinc-400 dark:text-zinc-500 cursor-pointer hover:text-zinc-600 dark:hover:text-zinc-300">Boot log</summary>
          <div class="mt-2 bg-zinc-50 dark:bg-zinc-800 rounded-lg p-3 text-xs font-mono text-zinc-500 dark:text-zinc-400 space-y-0.5 max-h-48 overflow-y-auto">
            <p :for={line <- @boot_log}>{line}</p>
          </div>
        </details>
      </div>
    </div>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center">
      <div class="text-center">
        <div class="w-16 h-16 rounded-2xl bg-zinc-100 dark:bg-zinc-800 flex items-center justify-center mx-auto mb-4">
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="w-7 h-7 text-zinc-300 dark:text-zinc-600">
            <path fill-rule="evenodd" d="M4.848 2.771A49.144 49.144 0 0 1 12 2.25c2.43 0 4.817.178 7.152.52 1.978.29 3.348 2.024 3.348 3.97v6.02c0 1.946-1.37 3.68-3.348 3.97a48.901 48.901 0 0 1-3.476.383.39.39 0 0 0-.297.17l-2.755 4.133a.75.75 0 0 1-1.248 0l-2.755-4.133a.39.39 0 0 0-.297-.17 48.9 48.9 0 0 1-3.476-.384c-1.978-.29-3.348-2.024-3.348-3.97V6.741c0-1.946 1.37-3.68 3.348-3.97Z" clip-rule="evenodd" />
          </svg>
        </div>
        <p class="text-sm text-zinc-400 dark:text-zinc-500">Create or select an agent to start chatting</p>
      </div>
    </div>
    """
  end

  # --- Agent View ---

  defp agent_view(assigns) do
    ~H"""
    <div class="flex-1 flex min-h-0">
      <div class="flex-1 flex flex-col min-w-0 min-h-0">
        <.agent_header agent={@selected_agent} tab={@tab} has_container={@has_container} />
        <.chat_panel :if={@tab == :chat} messages={@messages} streaming_text={@streaming_text} agent={@selected_agent} workspace_id={@workspace.id} />
        <.container_panel :if={@tab == :container} env={@container_env} logs={@container_logs} log_service={@container_log_service} has_container={@has_container} />
      </div>
      <.context_panel agent={@selected_agent} has_container={@has_container} container_env={@container_env} container_logs={@container_logs} editing_name={@editing_name} />
    </div>
    """
  end

  defp agent_header(assigns) do
    port = nil  # Ports are now shown per-process in the sidebar, not per-agent
    assigns = assign(assigns, :container_port, port)

    ~H"""
    <div class="flex-none border-b border-zinc-200 dark:border-zinc-700/80">
      <div class="flex items-center justify-between px-3 md:px-5 h-12 gap-2">
        <div class="flex items-center gap-2 md:gap-3 min-w-0">
          <div class={"w-2 h-2 rounded-full flex-none #{status_dot(@agent.status)}"}></div>
          <span class="text-sm font-semibold text-zinc-900 dark:text-zinc-100 truncate">{@agent.name}</span>
          <span :if={@agent[:last_activity_at]} class="text-xs text-zinc-400 dark:text-zinc-500 hidden sm:block flex-none">
            {time_ago(@agent[:last_activity_at])}
          </span>
        </div>
        <div class="flex items-center gap-1 md:gap-2 flex-none">
          <button :if={@agent.status in [:idle, :thinking]} phx-click="restart_session" phx-value-id={@agent.id}
            class="text-xs font-medium text-amber-600 dark:text-amber-400 hover:bg-amber-50 dark:hover:bg-amber-500/10 rounded-md px-2 py-1 hidden sm:block">
            Restart CLI
          </button>
          <button :if={@agent.status in [:idle, :thinking]} phx-click="stop_agent" phx-value-id={@agent.id}
            class="text-xs font-medium text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-500/10 rounded-md px-2 py-1">
            Stop
          </button>
          <button :if={@agent.status in [:stopped, :crashed]} phx-click="start_agent" phx-value-id={@agent.id}
            class="text-xs font-medium text-green-600 dark:text-green-400 hover:bg-green-50 dark:hover:bg-green-500/10 rounded-md px-2 py-1">
            Start
          </button>
          <button :if={@agent.status in [:stopped, :crashed]} phx-click="remove_agent" phx-value-id={@agent.id}
            class="text-xs font-medium text-zinc-500 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-700 rounded-md px-2 py-1">
            Remove
          </button>
          <span :if={@agent.status == :destroying}
            class="text-xs font-medium text-red-400 px-2 py-1">
            Destroying...
          </span>
        </div>
      </div>
      <div :if={@has_container} class="flex gap-0 px-4">
        <button phx-click="switch_tab" phx-value-tab="chat"
          class={"px-3 py-1.5 text-xs font-medium border-b-2 transition-colors #{if @tab == :chat, do: "border-violet-500 text-violet-600 dark:text-violet-400", else: "border-transparent text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300"}"}>
          Chat
        </button>
        <button phx-click="switch_tab" phx-value-tab="container"
          class={"px-3 py-1.5 text-xs font-medium border-b-2 transition-colors #{if @tab == :container, do: "border-violet-500 text-violet-600 dark:text-violet-400", else: "border-transparent text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300"}"}>
          Container
        </button>
      </div>
    </div>
    """
  end

  # --- Chat Panel ---

  defp chat_panel(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col min-h-0">
      <div id="messages" class="flex-1 overflow-y-auto px-4 md:px-6 py-4 space-y-1">
        <div :for={{msg, idx} <- Enum.with_index(@messages)}>
          <.chat_msg msg={msg} idx={idx} agent_id={@agent.id} workspace_id={@workspace_id} />
        </div>
        <.streaming_bubble :if={@streaming_text != ""} text={@streaming_text} />
        <.thinking_indicator :if={@agent.status == :thinking && @streaming_text == ""} messages={@messages} />
      </div>
      <div class="flex-none border-t border-zinc-200 dark:border-zinc-700/80 p-3 md:p-4 safe-area-bottom">
        <form id="chat-form" phx-submit="send_message" phx-hook="ChatForm" class="flex gap-2">
          <textarea
            name="message" id="chat-input" rows="1"
            placeholder={if @agent.status == :thinking, do: "Agent is #{thinking_word(@agent.id)}...", else: "Type a message..."}
            autocomplete="off"
            class="flex-1 rounded-xl border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-4 py-2.5 text-sm
                   text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 resize-none
                   focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400"></textarea>
          <button type="submit"
            class="rounded-xl bg-violet-600 hover:bg-violet-700 px-4 py-2.5 text-sm font-medium text-white transition-colors flex-none">
            Send
          </button>
        </form>
      </div>
    </div>
    """
  end

  defp chat_msg(%{msg: %{role: :user}} = assigns) do
    assigns = assign(assigns, :url, msg_url(assigns))
    ~H"""
    <div class="flex justify-end mt-3 mb-1 group/msg">
      <div class="relative max-w-[85%] rounded-2xl rounded-tr-sm bg-violet-600 text-white px-4 py-2.5" id={"msg-user-#{hash_content(@msg.content)}"} phx-hook="Markdown" data-source={@msg.content}>
        <a :if={@url} href={@url} target="_blank" rel="noopener"
          class="absolute top-2 left-2 p-1 rounded-md text-violet-300 hover:text-white opacity-0 group-hover/msg:opacity-100 transition-opacity"
          title="Open">
          <svg class="w-3 h-3" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor">
            <path d="M6.22 8.72a.75.75 0 0 0 1.06 1.06l5.22-5.22v1.69a.75.75 0 0 0 1.5 0v-3.5a.75.75 0 0 0-.75-.75h-3.5a.75.75 0 0 0 0 1.5h1.69L6.22 8.72Z" />
            <path d="M3.5 6.75c0-.69.56-1.25 1.25-1.25H7A.75.75 0 0 0 7 4H4.75A2.75 2.75 0 0 0 2 6.75v4.5A2.75 2.75 0 0 0 4.75 14h4.5A2.75 2.75 0 0 0 12 11.25V9a.75.75 0 0 0-1.5 0v2.25c0 .69-.56 1.25-1.25 1.25h-4.5c-.69 0-1.25-.56-1.25-1.25v-4.5Z" />
          </svg>
        </a>
        <div class="markdown-body markdown-body-user text-sm"></div>
      </div>
    </div>
    """
  end

  defp chat_msg(%{msg: %{role: :assistant, content: content}} = assigns)
       when content in [nil, ""] do
    ~H"""
    <div></div>
    """
  end

  defp chat_msg(%{msg: %{role: :assistant}} = assigns) do
    assigns = assign(assigns, :url, msg_url(assigns))

    ~H"""
    <div class="flex gap-3 mt-3 mb-1 group/msg">
      <div class="flex-none w-7 h-7 rounded-full bg-violet-100 dark:bg-violet-900/40 flex items-center justify-center mt-0.5">
        <span class="text-xs font-bold text-violet-600 dark:text-violet-400">C</span>
      </div>
      <div class="relative max-w-[85%] rounded-2xl rounded-tl-sm bg-zinc-100 dark:bg-zinc-800 px-4 py-2.5" id={"msg-#{hash_content(@msg.content)}"} phx-hook="Markdown" data-source={@msg.content}>
        <a :if={@url} href={@url} target="_blank" rel="noopener"
          class="absolute top-2 right-2 p-1 rounded-md text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 hover:bg-zinc-200 dark:hover:bg-zinc-700 opacity-0 group-hover/msg:opacity-100 transition-opacity"
          title="Open">
          <svg class="w-3.5 h-3.5" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor">
            <path d="M6.22 8.72a.75.75 0 0 0 1.06 1.06l5.22-5.22v1.69a.75.75 0 0 0 1.5 0v-3.5a.75.75 0 0 0-.75-.75h-3.5a.75.75 0 0 0 0 1.5h1.69L6.22 8.72Z" />
            <path d="M3.5 6.75c0-.69.56-1.25 1.25-1.25H7A.75.75 0 0 0 7 4H4.75A2.75 2.75 0 0 0 2 6.75v4.5A2.75 2.75 0 0 0 4.75 14h4.5A2.75 2.75 0 0 0 12 11.25V9a.75.75 0 0 0-1.5 0v2.25c0 .69-.56 1.25-1.25 1.25h-4.5c-.69 0-1.25-.56-1.25-1.25v-4.5Z" />
          </svg>
        </a>
        <div class="markdown-body text-sm text-zinc-900 dark:text-zinc-100"></div>
      </div>
    </div>
    """
  end

  defp chat_msg(%{msg: %{role: :tool}} = assigns) do
    assigns = assign(assigns, :summary, tool_summary(assigns.msg.tool, assigns.msg.input))

    ~H"""
    <div class="flex items-center gap-2 py-1 pl-10">
      <div class="w-4 h-4 rounded bg-blue-100 dark:bg-blue-900/40 flex items-center justify-center flex-none">
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-2.5 h-2.5 text-blue-500 dark:text-blue-400">
          <path fill-rule="evenodd" d="M6.955 1.45A.5.5 0 0 1 7.452 1h1.096a.5.5 0 0 1 .497.45l.17 1.699c.484.12.94.312 1.356.562l1.321-.916a.5.5 0 0 1 .67.033l.774.775a.5.5 0 0 1 .034.67l-.916 1.32c.25.417.443.873.563 1.357l1.699.17a.5.5 0 0 1 .45.497v1.096a.5.5 0 0 1-.45.497l-1.699.17c-.12.484-.312.94-.562 1.356l.916 1.321a.5.5 0 0 1-.034.67l-.774.774a.5.5 0 0 1-.67.033l-1.32-.916c-.417.25-.874.443-1.357.563l-.17 1.699a.5.5 0 0 1-.497.45H7.452a.5.5 0 0 1-.497-.45l-.17-1.699a4.973 4.973 0 0 1-1.356-.562l-1.321.916a.5.5 0 0 1-.67-.033l-.774-.775a.5.5 0 0 1-.034-.67l.916-1.32a4.971 4.971 0 0 1-.562-1.357l-1.699-.17A.5.5 0 0 1 1 8.548V7.452a.5.5 0 0 1 .45-.497l1.699-.17c.12-.484.312-.94.562-1.356l-.916-1.321a.5.5 0 0 1 .034-.67l.774-.774a.5.5 0 0 1 .67-.033l1.32.916c.417-.25.874-.443 1.357-.563l.17-1.699ZM8 10.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5Z" clip-rule="evenodd" />
        </svg>
      </div>
      <span class="text-sm text-blue-600 dark:text-blue-400">{@summary}</span>
    </div>
    """
  end

  defp chat_msg(%{msg: %{role: :tool_result}} = assigns) do
    content = assigns.msg.content

    if is_binary(content) && String.contains?(content, "completed with no output") do
      ~H"<div></div>"
    else
      chat_msg_tool_result(assigns)
    end
  end

  defp chat_msg(%{msg: %{role: :error}} = assigns) do
    ~H"""
    <div class="flex items-start gap-2 py-1 pl-10">
      <div class="w-4 h-4 rounded bg-red-100 dark:bg-red-900/30 flex items-center justify-center flex-none mt-0.5">
        <span class="text-[10px] font-bold text-red-500">!</span>
      </div>
      <span class="text-xs text-red-600 dark:text-red-400">{@msg.content}</span>
      <span class="text-[10px] text-zinc-300 dark:text-zinc-600 flex-none">{Calendar.strftime(@msg.timestamp, "%H:%M:%S")}</span>
    </div>
    """
  end

  defp chat_msg(%{msg: %{role: :build}} = assigns) do
    assigns = assign(assigns, :link, msg_url(assigns))
    ~H"""
    <.log_inline content={@msg.content} status={:building} raw_url={@link} title={@msg[:title]} />
    """
  end

  defp chat_msg(%{msg: %{role: :build_done}} = assigns) do
    assigns = assign(assigns, :link, msg_url(assigns))
    ~H"""
    <.log_inline content={@msg.content} status={:done} raw_url={@link} title={@msg[:title]} />
    """
  end

  defp chat_msg(%{msg: %{role: :build_failed}} = assigns) do
    assigns = assign(assigns, :link, msg_url(assigns))
    ~H"""
    <.log_inline content={@msg.content} status={:failed} raw_url={@link} title={@msg[:title]} />
    """
  end

  defp chat_msg(%{msg: %{role: :system}} = assigns) do
    ~H"""
    <div class="py-1 pl-10">
      <div
        class="text-xs text-zinc-400 dark:text-zinc-500 italic"
        id={"system-msg-#{@msg[:id] || hash_content(@msg.content)}"}
        phx-hook="Markdown"
        data-source={@msg.content}
      >
        <div class="markdown-body"></div>
      </div>
    </div>
    """
  end

  defp chat_msg(assigns) do
    ~H"""
    <div></div>
    """
  end

  defp chat_msg_tool_result(assigns) do
    content = assigns.msg.content
    display = format_tool_result(content)
    lines = String.split(display, "\n")
    truncated = length(lines) > 40
    display = if truncated, do: Enum.take(lines, 40) |> Enum.join("\n"), else: display
    url = msg_url(assigns)
    assigns = assign(assigns, display: display, truncated: truncated, is_error: assigns.msg.is_error, line_count: length(lines), url: url)

    ~H"""
    <div class="pl-10 py-0.5">
      <pre class={"p-3 rounded-lg text-xs font-mono overflow-x-auto max-h-80 overflow-y-auto whitespace-pre-wrap
                   #{if @is_error, do: "bg-red-50 dark:bg-red-950/30 text-red-700 dark:text-red-300", else: "bg-zinc-100 dark:bg-zinc-950 text-zinc-800 dark:text-green-400"}"}>{@display}</pre>
      <div class="flex items-center gap-2 mt-1">
        <p :if={@truncated} class="text-[10px] text-zinc-400 dark:text-zinc-500">... truncated ({@line_count - 40} more lines)</p>
        <a :if={@url} href={@url} target="_blank" rel="noopener" class="text-[10px] text-zinc-400 hover:text-zinc-300 transition-colors">open</a>
      </div>
    </div>
    """
  end

  defp streaming_bubble(assigns) do
    ~H"""
    <div class="flex gap-3 mt-3">
      <div class="flex-none w-7 h-7 rounded-full bg-violet-100 dark:bg-violet-900/40 flex items-center justify-center mt-0.5">
        <span class="text-xs font-bold text-violet-600 dark:text-violet-400">C</span>
      </div>
      <div class="max-w-[85%] rounded-2xl rounded-tl-sm bg-zinc-100 dark:bg-zinc-800 px-4 py-2.5" id="streaming-msg" phx-hook="Markdown" data-source={@text}>
        <div class="markdown-body text-sm text-zinc-900 dark:text-zinc-100"></div>
        <span class="inline-block w-1.5 h-4 bg-violet-500 animate-pulse ml-0.5 align-middle"></span>
      </div>
    </div>
    """
  end

  defp thinking_indicator(assigns) do
    # Find the last tool call to show what the agent is doing
    last_tool = assigns.messages
      |> Enum.reverse()
      |> Enum.find(&(&1.role == :tool))

    last_action = if last_tool do
      tool_summary(last_tool.tool, last_tool.input)
    else
      nil
    end

    assigns = assign(assigns, :last_action, last_action)

    ~H"""
    <div class="flex gap-3 mt-3">
      <div class="flex-none w-7 h-7 rounded-full bg-violet-100 dark:bg-violet-900/40 flex items-center justify-center mt-0.5">
        <span class="text-xs font-bold text-violet-600 dark:text-violet-400">C</span>
      </div>
      <div class="rounded-2xl rounded-tl-sm bg-zinc-100 dark:bg-zinc-800 px-4 py-3">
        <div class="flex items-center gap-3">
          <div class="flex gap-1">
            <div class="w-2 h-2 rounded-full bg-zinc-400 animate-bounce" style="animation-delay: 0ms"></div>
            <div class="w-2 h-2 rounded-full bg-zinc-400 animate-bounce" style="animation-delay: 150ms"></div>
            <div class="w-2 h-2 rounded-full bg-zinc-400 animate-bounce" style="animation-delay: 300ms"></div>
          </div>
          <span :if={@last_action} class="text-sm text-zinc-500 dark:text-zinc-400">{@last_action}</span>
        </div>
      </div>
    </div>
    """
  end


  # --- Service Log Views ---

  defp service_log_view(assigns) do
    svc = Enum.find(assigns.service_statuses, &(&1.name == assigns.service_name))
    first_port = if svc, do: first_host_port(svc[:ports]), else: nil
    assigns = assign(assigns, svc: svc, first_port: first_port)

    ~H"""
    <div class="flex-1 flex flex-col min-h-0">
      <div class="flex-none border-b border-zinc-200 dark:border-zinc-700/80 px-4 md:px-5 h-12 flex items-center gap-3">
        <div :if={@svc} class={"w-2 h-2 rounded-full flex-none #{service_dot(@svc)}"}></div>
        <span class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">{@service_name}</span>
        <span :if={@svc} class="text-xs text-zinc-400 dark:text-zinc-500 font-mono">{service_detail(@svc)}</span>
        <a :if={@first_port} href={"http://#{@host}:#{@first_port}"} target="_blank"
          class="text-xs font-mono text-violet-500 hover:text-violet-400 transition-colors">
          {@host}:{@first_port}
        </a>
        <div class="ml-auto flex items-center gap-3">
          <.link navigate={"#{@base_path}/services/#{@service_name}/console"}
            class="text-xs font-medium text-zinc-500 dark:text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200 transition-colors">
            Console
          </.link>
          <button phx-click="spawn_service_agent" phx-value-service_name={@service_name}
            class="text-xs font-medium text-violet-600 dark:text-violet-400 hover:text-violet-500 transition-colors">
            + Debug Agent
          </button>
        </div>
      </div>
      <.log_panel id="service-logs" content={@logs} />
    </div>
    """
  end

  defp console_view(assigns) do
    ssh_cmd = if assigns.container do
      "ssh -p #{BoomLooper.SSHServer.port()} #{assigns.container}@localhost"
    end

    assigns = assign(assigns, :ssh_cmd, ssh_cmd)

    ~H"""
    <div class="flex-1 flex flex-col min-h-0">
      <div class="flex-none border-b border-zinc-200 dark:border-zinc-700/80 px-4 md:px-5 h-12 flex items-center gap-3">
        <span class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">{@service_name}</span>
        <span class="text-xs text-zinc-400 dark:text-zinc-500">console</span>
        <div :if={@ssh_cmd} class="ml-auto">
          <button id="copy-ssh" phx-hook="CopySource" data-source={@ssh_cmd}
            class="flex items-center gap-1.5 text-xs text-zinc-400 hover:text-zinc-300 transition-colors font-mono">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5 copy-icon">
              <path d="M5.5 3.5A1.5 1.5 0 0 1 7 2h2.879a1.5 1.5 0 0 1 1.06.44l2.122 2.12a1.5 1.5 0 0 1 .439 1.061V9.5A1.5 1.5 0 0 1 12 11V8.621a3 3 0 0 0-.879-2.121L9 4.379A3 3 0 0 0 6.879 3.5H5.5Z" />
              <path d="M4 5a1.5 1.5 0 0 0-1.5 1.5v6A1.5 1.5 0 0 0 4 14h5a1.5 1.5 0 0 0 1.5-1.5V8.621a1.5 1.5 0 0 0-.44-1.06L7.94 5.439A1.5 1.5 0 0 0 6.878 5H4Z" />
            </svg>
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5 check-icon hidden text-green-400">
              <path fill-rule="evenodd" d="M12.416 3.376a.75.75 0 0 1 .208 1.04l-5 7.5a.75.75 0 0 1-1.154.114l-3-3a.75.75 0 0 1 1.06-1.06l2.353 2.353 4.493-6.74a.75.75 0 0 1 1.04-.207Z" clip-rule="evenodd" />
            </svg>
            SSH
          </button>
        </div>
      </div>
      <div
        :if={@container}
        id={"terminal-#{@container}"}
        phx-hook="Terminal"
        data-container={@container}
        phx-update="ignore"
        class="flex-1 bg-[#18181b] p-3"
      ></div>
      <div :if={!@container} class="flex-1 flex items-center justify-center">
        <p class="text-sm text-zinc-400">Service not running</p>
      </div>
    </div>
    """
  end

  defp all_services_view(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col min-h-0">
      <div class="flex-none border-b border-zinc-200 dark:border-zinc-700/80 px-4 md:px-5 h-12 flex items-center">
        <span class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">All Services</span>
      </div>
      <.log_multi_service logs={@all_service_logs} />
    </div>
    """
  end

  # --- Container Panel ---

  defp container_panel(%{has_container: false} = assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center">
      <p class="text-sm text-zinc-400 dark:text-zinc-500">No container running</p>
    </div>
    """
  end

  defp container_panel(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col min-h-0 overflow-y-auto">
      <div class="flex items-center justify-end px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50 border-b border-zinc-200 dark:border-zinc-700/80">
        <button phx-click="refresh_container" class="text-xs text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors">
          Refresh
        </button>
      </div>
      <div :if={@env} class="border-b border-zinc-200 dark:border-zinc-700/80">
        <div class="px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50">
          <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">Environment</h3>
        </div>
        <pre class="px-4 py-3 text-xs font-mono text-zinc-600 dark:text-zinc-400 overflow-x-auto whitespace-pre-wrap max-h-48 overflow-y-auto">{@env}</pre>
      </div>
      <div class="flex-1 flex flex-col min-h-0">
        <div class="flex items-center justify-between px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50 border-b border-zinc-200 dark:border-zinc-700/80">
          <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">Logs</h3>
          <form phx-change="filter_container_service" class="inline">
            <input type="text" name="service" value={@log_service || ""} placeholder="Filter service..."
              class="text-xs rounded border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-2 py-1 w-28
                     focus:outline-none focus:ring-1 focus:ring-violet-500/30" />
          </form>
        </div>
        <pre class="flex-1 px-4 py-3 text-xs font-mono overflow-auto whitespace-pre-wrap bg-zinc-100 dark:bg-zinc-950 text-zinc-800 dark:text-green-400 min-h-[200px]">{@logs}</pre>
      </div>
    </div>
    """
  end

  # --- Context Panel (right sidebar) ---

  defp context_panel(assigns) do
    ~H"""
    <aside class="hidden lg:flex w-80 flex-none border-l border-zinc-200 dark:border-zinc-700/80 flex-col bg-zinc-50 dark:bg-zinc-900/50 overflow-y-auto">
      <div class="px-4 py-3 border-b border-zinc-200 dark:border-zinc-700/80">
        <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">Agent Context</h3>
      </div>

      <%!-- Name (click to edit) --%>
      <div class="px-4 py-3 border-b border-zinc-200 dark:border-zinc-700/80">
        <form :if={@editing_name} phx-submit="rename_agent" phx-click-away="cancel_rename" class="flex items-center gap-2">
          <input type="text" name="name" value={@agent.name} autofocus phx-mounted={JS.dispatch("focus")}
            class="flex-1 rounded-lg border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-3 py-1.5 text-sm
                   text-zinc-900 dark:text-zinc-100 focus:outline-none focus:ring-1 focus:ring-violet-500/30" />
          <button type="submit" class="text-xs text-violet-600 dark:text-violet-400 hover:underline flex-none">Save</button>
        </form>
        <div :if={!@editing_name} phx-click="start_rename" class="cursor-pointer group flex items-center gap-2">
          <span class="text-sm font-medium text-zinc-900 dark:text-zinc-100">{@agent.name}</span>
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3 h-3 text-zinc-300 dark:text-zinc-600 opacity-0 group-hover:opacity-100 transition-opacity">
            <path d="M13.488 2.513a1.75 1.75 0 0 0-2.475 0L6.75 6.774a2.75 2.75 0 0 0-.596.892l-.848 2.047a.75.75 0 0 0 .98.98l2.047-.848a2.75 2.75 0 0 0 .892-.596l4.261-4.262a1.75 1.75 0 0 0 0-2.474Z" />
            <path d="M4.75 3.5c-.69 0-1.25.56-1.25 1.25v6.5c0 .69.56 1.25 1.25 1.25h6.5c.69 0 1.25-.56 1.25-1.25V9A.75.75 0 0 1 14 9v2.25A2.75 2.75 0 0 1 11.25 14h-6.5A2.75 2.75 0 0 1 2 11.25v-6.5A2.75 2.75 0 0 1 4.75 2H7a.75.75 0 0 1 0 1.5H4.75Z" />
          </svg>
        </div>
      </div>

      <%!-- Agent Info --%>
      <div class="px-4 py-3 space-y-2">
        <h4 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">Info</h4>
        <div class="space-y-1.5 text-xs">
          <div class="flex justify-between">
            <span class="text-zinc-400">Status</span>
            <span class="font-medium text-zinc-700 dark:text-zinc-300">{@agent.status}</span>
          </div>
          <div class="flex justify-between">
            <span class="text-zinc-400">Tool calls</span>
            <span class="font-medium text-zinc-700 dark:text-zinc-300">{@agent.tool_calls}</span>
          </div>
          <div class="flex justify-between">
            <span class="text-zinc-400">Errors</span>
            <span class={"font-medium #{if @agent.errors > 0, do: "text-red-500", else: "text-zinc-700 dark:text-zinc-300"}"}>{@agent.errors}</span>
          </div>
          <div :if={@agent[:started_at]} class="flex justify-between">
            <span class="text-zinc-400">Started</span>
            <span class="text-zinc-700 dark:text-zinc-300">{time_ago(@agent.started_at)}</span>
          </div>
        </div>
      </div>

      <%!-- Container section --%>
      <div :if={@has_container} class="border-t border-zinc-200 dark:border-zinc-700/80">
        <div class="px-4 py-3">
          <div class="flex items-center justify-between mb-2">
            <h4 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">Container</h4>
            <button phx-click="refresh_container" class="text-xs text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors">
              Refresh
            </button>
          </div>
          <div :if={@container_env} class="mb-2">
            <pre class="text-[10px] font-mono text-zinc-500 dark:text-zinc-500 overflow-x-auto whitespace-pre-wrap max-h-32 overflow-y-auto">{@container_env}</pre>
          </div>
          <div :if={@container_logs != ""}>
            <pre class="text-[10px] font-mono bg-zinc-100 dark:bg-zinc-950 text-zinc-800 dark:text-green-400 rounded p-2 overflow-auto whitespace-pre-wrap max-h-40">{@container_logs}</pre>
          </div>
        </div>
      </div>
    </aside>
    """
  end
end
