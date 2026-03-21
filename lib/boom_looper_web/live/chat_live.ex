defmodule BoomLooperWeb.ChatLive do
  use BoomLooperWeb, :live_view

  alias BoomLooper.ChatAgent

  @impl true
  def mount(%{"project_id" => project_id, "branch_id" => branch_id}, _session, socket) do
    project = BoomLooper.ProjectRegistry.get_project(project_id)
    branch = BoomLooper.ProjectRegistry.get_branch(branch_id)

    unless project && branch do
      {:ok, push_navigate(socket, to: "/")}
    else
      # Build workspace-compatible shape for the rest of ChatLive
      workspace = %{id: branch.id, path: branch.path, name: project.name}
      mount_with_workspace(socket, workspace, %{project: project, branch: branch})
    end
  end


  defp mount_with_workspace(socket, workspace, extra_assigns) do
    if connected?(socket) do
      # Ensure the branch supervisor subtree is running
      branch_id = BoomLooper.ProjectRegistry.branch_id(workspace.path)
      BoomLooper.BranchSupervisor.start_branch(branch_id, workspace.path)
      BoomLooper.ProjectRegistry.update_branch_status(branch_id, :running)

      ChatAgent.subscribe()
      BoomLooper.Workspace.ServiceManager.subscribe()
    end

    agents = list_workspace_agents(workspace.path)
    service_statuses = fetch_service_statuses(workspace.path)

    base_path = if extra_assigns[:project] do
      "/p/#{extra_assigns[:project].id}/b/#{extra_assigns[:branch].id}"
    else
      "/p/#{workspace.id}/b/#{workspace.id}"
    end

    {:ok,
     socket
     |> assign(:workspace, workspace)
     |> assign(:project, extra_assigns[:project])
     |> assign(:branch, extra_assigns[:branch])
     |> assign(:base_path, base_path)
     |> assign(:agents, agents)
     |> assign(:service_statuses, service_statuses)
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
     |> assign(:available_checklists, [])
     |> assign(:checklist_progress, nil)
     |> assign(:selected_checklist, nil)
     |> assign(:editing_name, false)
     |> assign(:selected_service, nil)
     |> assign(:service_logs, "")
     |> assign(:all_service_logs, [])
     |> assign(:build_log, "")
     |> assign(:building, false)
     |> assign(:console_container, nil)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: action}} = socket) do
    tab = if action == :container, do: :container, else: :chat

    socket =
      if socket.assigns.selected_id != id do
        case select_agent(socket, id) do
          {:noreply, s} ->
            s

          :not_found ->
            socket
            |> put_flash(:error, "Agent not found")
            |> push_navigate(to: branch_path(socket))
        end
      else
        socket
      end

    socket = assign(socket, :tab, tab)
    socket = if tab == :container, do: fetch_container_data(socket), else: socket
    {:noreply, socket}
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :new}} = socket) do
    workspace = socket.assigns.workspace

    # Auto-spawn Setup if no config and no agents running
    has_config = match?({:ok, _}, BoomLooper.Workspace.load(workspace.path))
    has_agents = socket.assigns.agents != []

    if !has_config && !has_agents do
      # Auto-launch Setup checklist
      id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      setup = BoomLooper.Checklist.available(workspace.path) |> Enum.find(&(&1.id == "setup"))
      name = if setup, do: setup.name, else: "Setup"

      agent_opts = [
        id: id,
        name: name,
        working_dir: workspace.path,
        started_by: "browser",
        bind_mount: workspace.path
      ]

      ChatAgent.register_booting(id, name, workspace.path)
      Task.start(fn -> boot_agent(id, agent_opts, nil, workspace.path, if(setup, do: "setup")) end)

      {:noreply, push_navigate(socket, to: "#{branch_path(socket)}/chat/#{id}")}
    else
      checklists = BoomLooper.Checklist.available(workspace.path)
      {:noreply, assign(socket, available_checklists: checklists, selected_checklist: nil)}
    end
  end

  def handle_params(%{"service_name" => service_name}, _uri, %{assigns: %{live_action: :service}} = socket) do
    logs = fetch_service_container_logs(socket.assigns.service_statuses, service_name)
    schedule_log_refresh()

    {:noreply,
     socket
     |> assign(:selected_id, nil)
     |> assign(:selected_agent, nil)
     |> assign(:selected_service, service_name)
     |> assign(:service_logs, logs)
     |> assign(:all_service_logs, [])}
  end

  def handle_params(%{"service_name" => service_name}, _uri, %{assigns: %{live_action: :console}} = socket) do
    svc = Enum.find(socket.assigns.service_statuses, &(&1.name == service_name))

    # Process containers exec into workspace service (has shell + tools)
    # Stock services exec into their own container
    workspace_id = BoomLooper.ProjectRegistry.branch_id(socket.assigns.workspace.path)
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
    all_logs = fetch_all_service_logs(socket.assigns.service_statuses)
    schedule_log_refresh()

    {:noreply,
     socket
     |> assign(:selected_id, nil)
     |> assign(:selected_agent, nil)
     |> assign(:selected_service, nil)
     |> assign(:all_service_logs, all_logs)
     |> assign(:service_logs, "")}
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :index}} = socket) do
    workspace = socket.assigns.workspace
    has_config = match?({:ok, %{dockerfile: d}} when d != nil, BoomLooper.Workspace.load(workspace.path))

    cond do
      # No config at all → needs setup
      !has_config && socket.assigns.agents == [] ->
        {:noreply, push_navigate(socket, to: "#{branch_path(socket)}/new")}

      # Config exists but no agents → auto-spawn a default agent
      has_config && socket.assigns.agents == [] ->
        do_spawn_agent(socket, nil)

      # One agent and none selected → auto-select it
      length(socket.assigns.agents) == 1 && is_nil(socket.assigns.selected_id) ->
        agent = hd(socket.assigns.agents)
        {:noreply, push_navigate(socket, to: "#{branch_path(socket)}/chat/#{agent.id}")}

      true ->
        {:noreply, assign(socket, :tab, :chat)}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, :tab, :chat)}

  # --- Events ---

  @impl true
  def handle_event("select_agent", %{"id" => id}, socket) do
    tab = socket.assigns.tab
    bp = branch_path(socket)
    path = if tab == :container, do: "#{bp}/chat/#{id}/container", else: "#{bp}/chat/#{id}"
    {:noreply, push_patch(socket, to: path) |> push_event("focus_input", %{})}
  end

  @impl true
  def handle_event("select_checklist", %{"id" => id}, socket) do
    checklist = Enum.find(socket.assigns.available_checklists, &(&1.id == id))
    {:noreply, assign(socket, :selected_checklist, checklist)}
  end

  @impl true
  def handle_event("back_to_checklists", _params, socket) do
    {:noreply, assign(socket, :selected_checklist, nil)}
  end

  @impl true
  def handle_event("spawn_agent", params, socket) do
    do_spawn_agent(socket, Map.get(params, "checklist_id"))
  end

  @impl true
  def handle_event("spawn_service_agent", %{"service_name" => service_name}, socket) do
    do_spawn_agent(socket, nil, service_name: service_name)
  end

  @impl true
  def handle_event("send_message", %{"message" => message}, socket) do
    message = String.trim(message)

    if message != "" && socket.assigns.selected_id do
      # Optimistically add user message so it renders immediately
      user_msg = %{role: :user, content: message, timestamp: DateTime.utc_now()}

      socket =
        socket
        |> assign(:messages, socket.assigns.messages ++ [user_msg])
        |> push_event("scroll_bottom", %{})

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
    bp = branch_path(socket)

    path =
      case {socket.assigns.selected_id, tab} do
        {nil, _} -> bp
        {id, :container} -> "#{bp}/chat/#{id}/container"
        {id, _} -> "#{bp}/chat/#{id}"
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
        |> push_navigate(to: branch_path(socket))
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
  def handle_info({:chat_message, id, %{role: :user}}, socket) when id == socket.assigns.selected_id do
    # User messages are rendered optimistically in handle_event("send_message") — skip the PubSub echo
    {:noreply, socket}
  end

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
  def handle_info({:checklist_updated, id, progress}, socket) do
    socket =
      if id == socket.assigns.selected_id do
        assign(socket, :checklist_progress, progress)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:services_updated, path, statuses}, socket) do
    if path == socket.assigns.workspace.path do
      # Workspace container is infrastructure — never show in sidebar
      visible = Enum.reject(statuses, &(Map.get(&1, :type) == :workspace))
      {:noreply, assign(socket, :service_statuses, visible)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:build_output, id, data}, socket) when id == socket.assigns.selected_id do
    upsert_stream_message(socket, data, "Building Docker image...")
  end

  @impl true
  def handle_info({:stream_output, id, data, title}, socket) when id == socket.assigns.selected_id do
    upsert_stream_message(socket, data, title)
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

  defp upsert_stream_message(socket, data, title) do
    build_log = socket.assigns.build_log <> data
    build_log = if byte_size(build_log) > 8000, do: String.slice(build_log, -8000..-1//1), else: build_log

    messages = socket.assigns.messages
    build_msg = %{role: :build, content: build_log, title: title, timestamp: DateTime.utc_now()}

    messages =
      if Enum.any?(messages, &(&1.role == :build)) do
        Enum.map(messages, fn
          %{role: :build} -> build_msg
          other -> other
        end)
      else
        messages ++ [build_msg]
      end

    {:noreply, socket |> assign(:messages, messages) |> assign(:build_log, build_log) |> assign(:building, true)}
  end

  defp do_spawn_agent(socket, checklist_id, opts \\ []) do
    workspace = socket.assigns.workspace
    working_dir = workspace.path
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    service_name = Keyword.get(opts, :service_name)

    ws_config =
      case BoomLooper.Workspace.load(working_dir) do
        {:ok, ws} -> ws
        _ -> nil
      end

    name =
      cond do
        service_name -> "#{service_name}-agent"
        checklist_id ->
          checklist = Enum.find(socket.assigns[:available_checklists] || [], &(&1.id == checklist_id))
          if checklist && checklist.name, do: checklist.name, else: auto_name()
        ws_config && ws_config.name -> ws_config.name
        true -> auto_name()
      end

    agent_opts = [
      id: id,
      name: name,
      working_dir: working_dir,
      started_by: "browser",
      bind_mount: working_dir
    ]

    agent_opts = if service_name, do: agent_opts ++ [service_name: service_name], else: agent_opts
    boot_opts = if service_name, do: [service_name: service_name], else: []

    ChatAgent.register_booting(id, name, working_dir, boot_opts)
    Task.start(fn -> boot_agent(id, agent_opts, ws_config, working_dir, checklist_id) end)

    {:noreply, push_navigate(socket, to: "#{branch_path(socket)}/chat/#{id}")}
  end

  defp fetch_service_statuses(workspace_path) do
    case BoomLooper.Workspace.ServiceManager.service_status(workspace_path) do
      {:ok, statuses} ->
        Enum.reject(statuses, &(Map.get(&1, :type) == :workspace))
      _ -> []
    end
  catch
    :exit, _ -> []
  end

  defp branch_path(socket), do: socket.assigns.base_path

  defp fetch_service_container_logs(service_statuses, service_name) do
    case Enum.find(service_statuses, &(&1.name == service_name)) do
      %{container: container} ->
        case BoomLooper.Docker.docker(["logs", "--tail", "200", container], timeout: 5_000) do
          {:ok, output} -> output
          {:error, _} -> ""
        end

      nil ->
        ""
    end
  catch
    :exit, _ -> ""
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
        checklist_progress = load_checklist_progress(id)

        socket =
          socket
          |> assign(:agents, agents)
          |> assign(:selected_id, id)
          |> assign(:selected_agent, agent)
          |> assign(:messages, agent.messages)
          |> assign(:streaming_text, "")
          |> assign(:booting_agent_id, nil)
          |> assign(:checklist_progress, checklist_progress)

        {:noreply, socket}
    end
  end

  defp fetch_container_data(socket) do
    case socket.assigns.selected_id do
      nil ->
        socket

      id ->
        # Check workspace container instead of per-agent container
        agent_state = BoomLooper.ChatAgent.get_state(id)
        workspace_id = agent_state && agent_state[:workspace_id]
        ws_container = if workspace_id, do: BoomLooper.Workspace.ServiceManager.service_container_name(workspace_id, "workspace")
        has_container = ws_container != nil && BoomLooper.Docker.container_running?(ws_container)

        if has_container do
          log_opts = %{lines: 100}
          log_opts = if socket.assigns.container_log_service, do: Map.put(log_opts, :service, socket.assigns.container_log_service), else: log_opts

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

          socket
          |> assign(:container_logs, logs)
          |> assign(:container_env, env)
          |> assign(:has_container, true)
        else
          socket
          |> assign(:container_logs, "")
          |> assign(:container_env, nil)
          |> assign(:has_container, false)
        end
    end
  end

  defp boot_agent(id, agent_opts, workspace, working_dir, checklist_id) do
    require Logger
    workspace_id = BoomLooper.Workspace.workspace_id(working_dir)

    ws_container = BoomLooper.Workspace.ServiceManager.service_container_name(workspace_id, "workspace")

    unless BoomLooper.Docker.container_running?(ws_container) do
      # Services not running — start them via compose
      ChatAgent.update_boot_status(id, "Starting services...")
      case BoomLooper.Workspace.ServiceManager.start_services(working_dir) do
        {:ok, _} -> :ok
        {:error, :service_manager_not_running} -> :ok  # No config yet, Setup will create it
        {:error, reason} ->
          ChatAgent.boot_failed(id, reason)
          raise "Service start failed: #{inspect(reason)}"
      end
    end

    ChatAgent.update_boot_status(id, "Starting Claude session...")

    checklist_path =
      if checklist_id do
        ChatAgent.update_boot_status(id, "Setting up checklist...")
        case BoomLooper.Checklist.instantiate_by_id(checklist_id, id, working_dir) do
          {:ok, checklist} -> checklist.active_path
          {:error, _} -> nil
        end
      end

    final_opts = if checklist_path, do: agent_opts ++ [checklist_path: checklist_path], else: agent_opts

    ChatAgent.update_boot_status(id, "Starting Claude session...")
    Logger.info("[boot_agent] #{id} starting Claude session")
    branch_id = BoomLooper.ProjectRegistry.branch_id(working_dir)
    case BoomLooper.Branch.start_agent(branch_id, final_opts) do
      {:ok, _pid} ->
        Logger.info("[boot_agent] #{id} Claude session started successfully")
        service_name = Keyword.get(final_opts, :service_name)

        cond do
          checklist_path ->
            ChatAgent.send_message(id, "Follow the checklist at /workspace/.hive/active/#{Path.basename(checklist_path)}. Work through each item in order, using the check_item tool to mark items done as you complete them.")

          service_name ->
            ChatAgent.send_message(id, "Check the logs for the #{service_name} service and help me debug any issues.")

          !workspace ->
            ChatAgent.send_message(id, "Look at the project in /workspace and help me set up a development environment. Examine the project files to understand what language, framework, and tools are needed.")

          true ->
            :ok
        end

      {:error, reason} ->
        Logger.error("[boot_agent] #{id} start_agent failed: #{inspect(reason)}")
        ChatAgent.boot_failed(id, reason)
    end
  rescue
    e ->
      require Logger
      Logger.error("[boot_agent] #{id} crashed: #{Exception.message(e)}")
      ChatAgent.boot_failed(id, Exception.message(e))
  catch
    :exit, reason ->
      require Logger
      Logger.error("[boot_agent] #{id} exited: #{inspect(reason)}")
      ChatAgent.boot_failed(id, "Boot process exited: #{inspect(reason)}")
  end

  defp load_checklist_progress(agent_id) do
    case BoomLooper.Tools.Checklist.find_active_checklist(agent_id) do
      {:ok, path} ->
        case BoomLooper.Checklist.load_file(path) do
          {:ok, checklist} ->
            {checked, total} = BoomLooper.Checklist.progress(checklist)
            %{checked: checked, total: total, items: checklist.items}

          _ ->
            nil
        end

      :not_found ->
        nil
    end
  end

  @adjectives ~w(Swift Bright Calm Deep Quick Sharp Keen Bold Clear True)
  @nouns ~w(Spark Drift Pulse Wave Bloom Forge Sage Fern Tide Mesa)

  defp auto_name do
    adj = Enum.random(@adjectives)
    noun = Enum.random(@nouns)
    "#{adj} #{noun}"
  end

  # Ports come from Docker.container_ports as %{"container_port" => "host_port"}
  defp first_host_port(ports) when is_map(ports) and map_size(ports) > 0 do
    case Enum.at(ports, 0) do
      {_container_port, host_port} -> to_string(host_port)
      _ -> nil
    end
  end

  defp first_host_port(_), do: nil

  defp service_dot(%{health: :healthy}), do: "bg-green-500"
  defp service_dot(%{health: :started}), do: "bg-blue-400"
  defp service_dot(%{health: :booting}), do: "bg-yellow-400 animate-pulse"
  defp service_dot(%{health: :crashed}), do: "bg-red-500"
  defp service_dot(%{running: true}), do: "bg-blue-400"
  defp service_dot(_), do: "bg-zinc-400"

  defp service_status_text(%{health: :healthy}), do: nil
  defp service_status_text(%{health: :started}), do: "starting"
  defp service_status_text(%{health: :booting}), do: "booting"
  defp service_status_text(%{health: :crashed}), do: nil  # exit_reason handles this
  defp service_status_text(_), do: nil

  defp exit_reason(%{oom_killed: true}), do: "OOM killed"
  defp exit_reason(%{error: error}) when is_binary(error), do: error
  defp exit_reason(%{exit_code: 0}), do: "exited cleanly"
  defp exit_reason(%{exit_code: 137}), do: "killed (SIGKILL)"
  defp exit_reason(%{exit_code: 143}), do: "stopped (SIGTERM)"
  defp exit_reason(%{exit_code: code}), do: "exit code #{code}"
  defp exit_reason(_), do: "stopped"

  defp service_detail(%{image: image}) when is_binary(image), do: image
  defp service_detail(%{processes: procs}) when is_list(procs), do: Enum.join(procs, ", ")
  defp service_detail(%{command: cmd}) when is_binary(cmd), do: String.slice(cmd, 0..30)
  defp service_detail(_), do: ""

  defp status_dot(:booting), do: "bg-violet-400 animate-pulse"
  defp status_dot(:idle), do: "bg-green-500"
  defp status_dot(:thinking), do: "bg-amber-400 animate-pulse"
  defp status_dot(:stopped), do: "bg-zinc-400"
  defp status_dot(:crashed), do: "bg-red-500"
  defp status_dot(:destroying), do: "bg-red-400 animate-pulse"
  defp status_dot(_), do: "bg-zinc-400"

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
  defp msg_url(assigns) do
    msg_id = assigns.msg[:id]
    if msg_id do
      BoomLooperWeb.OutputController.signed_url(assigns.workspace_id, assigns.agent_id, msg_id)
    end
  end


  defp thinking_word(agent_id) do
    idx = :erlang.phash2({agent_id, div(System.system_time(:second), 3)}, length(@thinking_words))
    Enum.at(@thinking_words, idx)
  end

  defp hash_content(content) when is_binary(content) do
    :erlang.phash2(content, 0xFFFFFF) |> Integer.to_string(16)
  end

  defp shorten_path(path) do
    home = System.user_home!()
    String.replace_prefix(path, home, "~")
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
      {"list_checklists", _} -> "Listed available checklists"
      {"start_checklist", %{"checklist_id" => cl}} -> "Started checklist: #{cl}"
      {"get_progress", _} -> "Checked checklist progress"
      {"check_item", %{"line" => l}} -> "Checked item at line #{l}"
      {"uncheck_item", %{"line" => l}} -> "Unchecked item at line #{l}"
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
      <.header workspace={@workspace} project={@project} branch={@branch} agent_count={length(@agents)} />
      <p :if={@flash["error"]} class="mx-4 mt-2 rounded-lg bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 px-4 py-3 text-sm text-red-700 dark:text-red-300">
        {@flash["error"]}
      </p>
      <div class="flex-1 flex min-h-0">
        <.sidebar agents={@agents} selected_id={@selected_id} workspace_id={@workspace.id} project={@project} branch={@branch} service_statuses={@service_statuses} selected_service={@selected_service} />
        <main class="flex-1 flex flex-col min-w-0">
          <.new_agent_screen :if={@live_action == :new} available_checklists={@available_checklists} selected_checklist={@selected_checklist} workspace={@workspace} base_path={@base_path} />
          <.service_log_view :if={@live_action == :service} service_name={@selected_service} service_statuses={@service_statuses} logs={@service_logs} base_path={@base_path} />
          <.console_view :if={@live_action == :console} service_name={@selected_service} container={@console_container} />
          <.all_services_view :if={@live_action == :services} all_service_logs={@all_service_logs} />
          <.booting_screen :if={@live_action not in [:new, :service, :services] && @booting_agent_id && !@selected_agent} agent_id={@booting_agent_id} status={@boot_status} boot_log={@boot_log} />
          <.empty_state :if={@live_action not in [:new, :service, :services] && !@booting_agent_id && !@selected_agent} />
          <.agent_view :if={@live_action not in [:new, :service, :services] && @selected_agent} {assigns} />
        </main>
      </div>
    </div>
    """
  end

  defp header(assigns) do
    ~H"""
    <header class="flex-none h-14 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center justify-between px-4 md:px-5">
      <div class="flex items-center gap-3">
        <.link navigate="/" class="text-lg font-semibold tracking-tight hover:text-violet-600 dark:hover:text-violet-400 transition-colors">Boom Looper</.link>
        <span class="text-zinc-300 dark:text-zinc-600">/</span>
        <.link :if={@project} navigate={"/p/#{@project.id}"} class="text-sm font-medium hover:text-violet-600 dark:hover:text-violet-400 transition-colors">{@workspace.name}</.link>
        <span :if={!@project} class="text-sm font-medium">{@workspace.name}</span>
        <span :if={@branch && !@branch.is_main} class="text-zinc-300 dark:text-zinc-600">/</span>
        <span :if={@branch && !@branch.is_main} class="text-sm text-zinc-500 dark:text-zinc-400">{@branch.name}</span>
        <span class="text-sm text-zinc-400 dark:text-zinc-500">{@agent_count} agent{if @agent_count != 1, do: "s"}</span>
      </div>
    </header>
    """
  end

  defp sidebar(assigns) do
    base_path = if assigns.project do
      "/p/#{assigns.project.id}/b/#{assigns.branch.id}"
    else
      "/p/#{assigns.workspace_id}/b/#{assigns.workspace_id}"
    end
    assigns = assign(assigns, :base_path, base_path)

    ~H"""
    <aside class="w-72 md:w-80 flex-none border-r border-zinc-200 dark:border-zinc-700/80 flex flex-col bg-zinc-50 dark:bg-zinc-900/50">
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
        <div :if={@agents != []} class="px-3 pt-3 pb-1">
          <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 font-semibold mb-1.5">Agents</div>
          <div class="space-y-0.5">
            <.agent_list_item :for={agent <- @agents} agent={agent} selected={@selected_id == agent.id} />
          </div>
        </div>

        <div :if={@service_statuses != []} class="px-3 pt-3 pb-1">
          <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 font-semibold mb-1.5">Services</div>
          <div class="space-y-0.5">
            <.service_item :for={svc <- @service_statuses} svc={svc} base_path={@base_path} selected={@selected_service == svc.name} />
          </div>
        </div>

        <div :if={@agents == [] && @service_statuses == []} class="flex flex-col items-center justify-center h-full px-6 text-center">
          <p class="text-sm text-zinc-400 dark:text-zinc-500">No agents yet</p>
        </div>
      </div>
    </aside>
    """
  end

  # --- New Agent Screen (Checklist Card Picker) ---

  defp new_agent_screen(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto p-6 md:p-8">
      <div class="max-w-2xl mx-auto">
        <div :if={!@selected_checklist}>
          <h2 class="text-xl font-semibold text-zinc-900 dark:text-zinc-100 mb-1">New Agent</h2>
          <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-6">Choose a checklist to guide the agent, or launch freeform.</p>

          <div class="space-y-3">
            <%!-- Freeform card --%>
            <form phx-submit="spawn_agent">
              <button type="submit"
                class="w-full text-left rounded-xl border border-zinc-200 dark:border-zinc-700 p-4
                       hover:border-violet-400 dark:hover:border-violet-500 hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors">
                <div class="flex items-center justify-between">
                  <div>
                    <h3 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">Freeform</h3>
                    <p class="text-xs text-zinc-500 dark:text-zinc-400 mt-0.5">Launch an agent with no checklist. You'll chat directly.</p>
                  </div>
                  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4 text-zinc-300 dark:text-zinc-600">
                    <path fill-rule="evenodd" d="M6.22 4.22a.75.75 0 0 1 1.06 0l3.25 3.25a.75.75 0 0 1 0 1.06l-3.25 3.25a.75.75 0 0 1-1.06-1.06L8.94 8 6.22 5.28a.75.75 0 0 1 0-1.06Z" clip-rule="evenodd" />
                  </svg>
                </div>
              </button>
            </form>

            <%!-- Checklist cards --%>
            <button :for={cl <- @available_checklists}
              phx-click="select_checklist" phx-value-id={cl.id}
              class="w-full text-left rounded-xl border border-zinc-200 dark:border-zinc-700 p-4
                     hover:border-violet-400 dark:hover:border-violet-500 hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors">
              <div class="flex items-center justify-between">
                <div class="min-w-0">
                  <h3 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">{cl.name || cl.id}</h3>
                  <p :if={cl.description} class="text-xs text-zinc-500 dark:text-zinc-400 mt-0.5">{cl.description}</p>
                  <p class="text-xs text-zinc-400 dark:text-zinc-500 mt-1">{length(cl.items)} steps</p>
                </div>
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4 text-zinc-300 dark:text-zinc-600 flex-none">
                  <path fill-rule="evenodd" d="M6.22 4.22a.75.75 0 0 1 1.06 0l3.25 3.25a.75.75 0 0 1 0 1.06l-3.25 3.25a.75.75 0 0 1-1.06-1.06L8.94 8 6.22 5.28a.75.75 0 0 1 0-1.06Z" clip-rule="evenodd" />
                </svg>
              </div>
            </button>
          </div>

          <div class="mt-6">
            <.link navigate={@base_path} class="text-sm text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 transition-colors">Cancel</.link>
          </div>
        </div>

        <%!-- Checklist detail view --%>
        <div :if={@selected_checklist}>
          <button phx-click="back_to_checklists" class="flex items-center gap-1 text-sm text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 mb-4 transition-colors">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4">
              <path fill-rule="evenodd" d="M9.78 4.22a.75.75 0 0 1 0 1.06L7.06 8l2.72 2.72a.75.75 0 1 1-1.06 1.06L5.47 8.53a.75.75 0 0 1 0-1.06l3.25-3.25a.75.75 0 0 1 1.06 0Z" clip-rule="evenodd" />
            </svg>
            Back
          </button>

          <h2 class="text-xl font-semibold text-zinc-900 dark:text-zinc-100 mb-1">{@selected_checklist.name || @selected_checklist.id}</h2>
          <p :if={@selected_checklist.description} class="text-sm text-zinc-500 dark:text-zinc-400 mb-5">{@selected_checklist.description}</p>

          <div class="rounded-xl border border-zinc-200 dark:border-zinc-700 p-4 mb-5">
            <div class="space-y-2">
              <div :for={item <- @selected_checklist.items} class="flex items-start gap-2.5">
                <div class="flex-none w-4 h-4 rounded border border-zinc-300 dark:border-zinc-600 mt-0.5"></div>
                <span class="text-sm text-zinc-700 dark:text-zinc-300">{item.text}</span>
              </div>
            </div>
          </div>

          <form phx-submit="spawn_agent">
            <input type="hidden" name="checklist_id" value={@selected_checklist.id} />
            <button type="submit"
              class="rounded-xl bg-zinc-900 dark:bg-zinc-100 px-6 py-3 text-sm font-medium text-white dark:text-zinc-900
                     hover:bg-zinc-700 dark:hover:bg-zinc-300 transition-colors">
              Launch Agent
            </button>
          </form>
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
      <.link navigate={"#{@base_path}/service/#{@svc.name}"} class="flex items-center gap-2 min-w-0 flex-1">
        <div class={"w-1.5 h-1.5 rounded-full flex-none #{service_dot(@svc)}"}></div>
        <span class="truncate text-zinc-600 dark:text-zinc-400">{@svc.name}</span>
      </.link>
      <a :if={@first_port && Map.get(@svc, :health) == :healthy} href={"http://localhost:#{@first_port}"} target="_blank"
        class="text-[10px] text-violet-500 hover:text-violet-400 font-mono ml-auto flex-none transition-colors">
        :{@first_port}
      </a>
      <span :if={service_status_text(@svc)} class="text-[10px] text-blue-400 ml-auto flex-none">{service_status_text(@svc)}</span>
      <span :if={!service_status_text(@svc) && !@first_port && @svc.running} class="text-[10px] text-zinc-400 dark:text-zinc-500 ml-auto font-mono truncate max-w-[100px]">{service_detail(@svc)}</span>
      <span :if={!@svc.running && @svc[:exit_info]} class="text-[10px] text-red-500 ml-auto truncate max-w-[140px]">{exit_reason(@svc.exit_info)}</span>
    </div>
    """
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

  defp build_log_inline(assigns) do
    title = Map.get(assigns, :title) || assigns[:msg_title]

    {label, dot_class} = case assigns.status do
      :building -> {title || "Running...", "bg-amber-400 animate-pulse"}
      :done -> {(title || "Command") <> " — done", "bg-green-500"}
      :failed -> {(title || "Command") <> " — failed", "bg-red-500"}
    end

    assigns = assign(assigns, label: label, dot_class: dot_class)

    ~H"""
    <div class="mt-2 mb-1 ml-10 rounded-lg border border-zinc-200 dark:border-zinc-700/80 overflow-hidden">
      <div class="flex items-center gap-2 px-3 py-1.5 bg-zinc-50 dark:bg-zinc-800/50 border-b border-zinc-200 dark:border-zinc-700/80">
        <div class={"w-1.5 h-1.5 rounded-full flex-none #{@dot_class}"}></div>
        <span class="text-xs font-medium text-zinc-500 dark:text-zinc-400">{@label}</span>
        <a :if={@msg_raw_url} href={@msg_raw_url} target="_blank"
          class="ml-auto text-[10px] text-zinc-400 hover:text-zinc-300 transition-colors">
          open
        </a>
      </div>
      <pre class={"px-3 py-2 text-xs font-mono text-zinc-800 dark:text-green-400 bg-zinc-100 dark:bg-zinc-950 whitespace-pre-wrap overflow-y-auto #{if @status == :building, do: "max-h-64", else: "max-h-32"}"}>{@content}</pre>
    </div>
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
        <.agent_header agent={@selected_agent} tab={@tab} has_container={@has_container} checklist_progress={@checklist_progress} />
        <.chat_panel :if={@tab == :chat} messages={@messages} streaming_text={@streaming_text} agent={@selected_agent} workspace_id={@workspace.id} />
        <.container_panel :if={@tab == :container} env={@container_env} logs={@container_logs} log_service={@container_log_service} has_container={@has_container} />
      </div>
      <.context_panel agent={@selected_agent} checklist_progress={@checklist_progress} has_container={@has_container} container_env={@container_env} container_logs={@container_logs} editing_name={@editing_name} />
    </div>
    """
  end

  defp agent_header(assigns) do
    port = nil  # Ports are now shown per-process in the sidebar, not per-agent
    assigns = assign(assigns, :container_port, port)

    ~H"""
    <div class="flex-none border-b border-zinc-200 dark:border-zinc-700/80">
      <div class="flex items-center justify-between px-4 md:px-5 h-12">
        <div class="flex items-center gap-3">
          <div class={"w-2 h-2 rounded-full #{status_dot(@agent.status)}"}></div>
          <span class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">{@agent.name}</span>
          <a :if={@container_port} href={"http://localhost:#{@container_port}"} target="_blank"
            class="text-xs font-mono text-violet-500 hover:text-violet-400 transition-colors">
            localhost:{@container_port}
          </a>
          <.checklist_badge :if={@checklist_progress} progress={@checklist_progress} />
          <span :if={@agent[:last_activity_at]} class="text-xs text-zinc-400 dark:text-zinc-500">
            {time_ago(@agent[:last_activity_at])}
          </span>
        </div>
        <div class="flex items-center gap-2">
          <button :if={@agent.status in [:idle, :thinking]} phx-click="restart_session" phx-value-id={@agent.id}
            class="text-xs font-medium text-amber-600 dark:text-amber-400 hover:bg-amber-50 dark:hover:bg-amber-500/10 rounded-md px-2 py-1">
            Restart CLI
          </button>
          <button :if={@agent.status in [:idle, :thinking]} phx-click="stop_agent" phx-value-id={@agent.id}
            class="text-xs font-medium text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-500/10 rounded-md px-2 py-1">
            Stop
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
        <.thinking_indicator :if={@agent.status == :thinking && @streaming_text == "" && @messages != [] && List.last(@messages).role != :assistant} />
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
    ~H"""
    <div class="flex justify-end mt-3 mb-1">
      <div class="max-w-[85%] rounded-2xl rounded-tr-sm bg-violet-600 text-white px-4 py-2.5">
        <p class="text-sm whitespace-pre-wrap">{@msg.content}</p>
      </div>
    </div>
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
        <a href={@url} target="_blank"
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
    <div class="flex items-center gap-2 py-0.5 pl-10">
      <div class="w-4 h-4 rounded bg-blue-100 dark:bg-blue-900/30 flex items-center justify-center flex-none">
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-2.5 h-2.5 text-blue-500 dark:text-blue-400">
          <path fill-rule="evenodd" d="M6.955 1.45A.5.5 0 0 1 7.452 1h1.096a.5.5 0 0 1 .497.45l.17 1.699c.484.12.94.312 1.356.562l1.321-.916a.5.5 0 0 1 .67.033l.774.775a.5.5 0 0 1 .034.67l-.916 1.32c.25.417.443.873.563 1.357l1.699.17a.5.5 0 0 1 .45.497v1.096a.5.5 0 0 1-.45.497l-1.699.17c-.12.484-.312.94-.562 1.356l.916 1.321a.5.5 0 0 1-.034.67l-.774.774a.5.5 0 0 1-.67.033l-1.32-.916c-.417.25-.874.443-1.357.563l-.17 1.699a.5.5 0 0 1-.497.45H7.452a.5.5 0 0 1-.497-.45l-.17-1.699a4.973 4.973 0 0 1-1.356-.562l-1.321.916a.5.5 0 0 1-.67-.033l-.774-.775a.5.5 0 0 1-.034-.67l.916-1.32a4.971 4.971 0 0 1-.562-1.357l-1.699-.17A.5.5 0 0 1 1 8.548V7.452a.5.5 0 0 1 .45-.497l1.699-.17c.12-.484.312-.94.562-1.356l-.916-1.321a.5.5 0 0 1 .034-.67l.774-.774a.5.5 0 0 1 .67-.033l1.32.916c.417-.25.874-.443 1.357-.563l.17-1.699ZM8 10.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5Z" clip-rule="evenodd" />
        </svg>
      </div>
      <span class="text-xs text-zinc-500 dark:text-zinc-400">{@summary}</span>
      <span class="text-[10px] text-zinc-300 dark:text-zinc-600">{Calendar.strftime(@msg.timestamp, "%H:%M:%S")}</span>
    </div>
    """
  end

  defp chat_msg(%{msg: %{role: :tool_result}} = assigns) do
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
        <a :if={@url} href={@url} target="_blank" class="text-[10px] text-zinc-400 hover:text-zinc-300 transition-colors">open</a>
      </div>
    </div>
    """
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
    <.build_log_inline content={@msg.content} status={:building} msg_raw_url={@link} title={@msg[:title]} />
    """
  end

  defp chat_msg(%{msg: %{role: :build_done}} = assigns) do
    assigns = assign(assigns, :link, msg_url(assigns))
    ~H"""
    <.build_log_inline content={@msg.content} status={:done} msg_raw_url={@link} title={@msg[:title]} />
    """
  end

  defp chat_msg(%{msg: %{role: :build_failed}} = assigns) do
    assigns = assign(assigns, :link, msg_url(assigns))
    ~H"""
    <.build_log_inline content={@msg.content} status={:failed} msg_raw_url={@link} title={@msg[:title]} />
    """
  end

  defp chat_msg(%{msg: %{role: :system}} = assigns) do
    ~H"""
    <div class="flex items-center gap-2 py-1 pl-10">
      <span class="text-xs text-zinc-400 dark:text-zinc-500 italic">{@msg.content}</span>
    </div>
    """
  end

  defp chat_msg(assigns) do
    ~H"""
    <div></div>
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
    ~H"""
    <div class="flex gap-3 mt-3">
      <div class="flex-none w-7 h-7 rounded-full bg-violet-100 dark:bg-violet-900/40 flex items-center justify-center mt-0.5">
        <span class="text-xs font-bold text-violet-600 dark:text-violet-400">C</span>
      </div>
      <div class="rounded-2xl rounded-tl-sm bg-zinc-100 dark:bg-zinc-800 px-4 py-3">
        <div class="flex gap-1">
          <div class="w-2 h-2 rounded-full bg-zinc-400 animate-bounce" style="animation-delay: 0ms"></div>
          <div class="w-2 h-2 rounded-full bg-zinc-400 animate-bounce" style="animation-delay: 150ms"></div>
          <div class="w-2 h-2 rounded-full bg-zinc-400 animate-bounce" style="animation-delay: 300ms"></div>
        </div>
      </div>
    </div>
    """
  end

  # --- Service Log Views ---

  @service_colors ~w(text-blue-400 text-green-400 text-yellow-400 text-pink-400 text-cyan-400 text-orange-400 text-violet-400 text-emerald-400)

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
        <a :if={@first_port} href={"http://localhost:#{@first_port}"} target="_blank"
          class="text-xs font-mono text-violet-500 hover:text-violet-400 transition-colors">
          localhost:{@first_port}
        </a>
        <div class="ml-auto flex items-center gap-3">
          <.link navigate={"#{@base_path}/service/#{@service_name}/console"}
            class="text-xs font-medium text-zinc-500 dark:text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200 transition-colors">
            Console
          </.link>
          <button phx-click="spawn_service_agent" phx-value-service_name={@service_name}
            class="text-xs font-medium text-violet-600 dark:text-violet-400 hover:text-violet-500 transition-colors">
            + Debug Agent
          </button>
        </div>
      </div>
      <pre class="flex-1 px-4 py-3 text-xs font-mono overflow-auto whitespace-pre-wrap bg-zinc-100 dark:bg-zinc-950 text-zinc-800 dark:text-green-400">{@logs}</pre>
    </div>
    """
  end

  defp console_view(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col min-h-0">
      <div class="flex-none border-b border-zinc-200 dark:border-zinc-700/80 px-4 md:px-5 h-12 flex items-center gap-3">
        <span class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">{@service_name}</span>
        <span class="text-xs text-zinc-400 dark:text-zinc-500">console</span>
      </div>
      <div
        :if={@container}
        id={"terminal-#{@container}"}
        phx-hook="Terminal"
        data-container={@container}
        phx-update="ignore"
        class="flex-1 bg-zinc-950 p-2"
      ></div>
      <div :if={!@container} class="flex-1 flex items-center justify-center">
        <p class="text-sm text-zinc-400">Service not running</p>
      </div>
    </div>
    """
  end

  defp all_services_view(assigns) do
    colors = @service_colors
    indexed_logs =
      Enum.with_index(assigns.all_service_logs)
      |> Enum.map(fn {svc_log, idx} ->
        Map.put(svc_log, :color, Enum.at(colors, rem(idx, length(colors))))
      end)

    assigns = assign(assigns, :indexed_logs, indexed_logs)

    ~H"""
    <div class="flex-1 flex flex-col min-h-0">
      <div class="flex-none border-b border-zinc-200 dark:border-zinc-700/80 px-4 md:px-5 h-12 flex items-center">
        <span class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">All Services</span>
      </div>
      <div class="flex-1 overflow-auto bg-zinc-950 px-4 py-3">
        <.service_log_block :for={svc_log <- @indexed_logs}
          name={svc_log.name} logs={svc_log.logs} color={svc_log.color} />
      </div>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :logs, :string, required: true
  attr :color, :string, required: true

  defp service_log_block(assigns) do
    lines = String.split(assigns.logs, "\n", trim: true)
    padded_name = String.pad_leading(assigns.name, 12)
    assigns = assign(assigns, lines: lines, padded_name: padded_name)

    ~H"""
    <div :for={line <- @lines} class="flex text-xs font-mono leading-relaxed">
      <span class={"#{@color} w-36 text-right flex-none select-none"}>{@padded_name} |</span>
      <span class="text-zinc-300 ml-2 whitespace-pre-wrap break-all">{line}</span>
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

  # --- Checklist Badge ---

  defp checklist_badge(assigns) do
    progress = assigns.progress
    pct = if progress.total > 0, do: round(progress.checked / progress.total * 100), else: 0

    color =
      cond do
        pct == 100 -> "text-green-600 dark:text-green-400 bg-green-100 dark:bg-green-900/30"
        pct > 0 -> "text-amber-600 dark:text-amber-400 bg-amber-100 dark:bg-amber-900/30"
        true -> "text-zinc-500 dark:text-zinc-400 bg-zinc-100 dark:bg-zinc-800"
      end

    assigns = assign(assigns, pct: pct, color: color)

    ~H"""
    <span class={"text-xs font-medium rounded-full px-2 py-0.5 #{@color}"}>
      {@progress.checked}/{@progress.total}
    </span>
    """
  end

  # --- Context Panel (right sidebar) ---

  defp context_panel(assigns) do
    ~H"""
    <aside class="w-72 md:w-80 flex-none border-l border-zinc-200 dark:border-zinc-700/80 flex flex-col bg-zinc-50 dark:bg-zinc-900/50 overflow-y-auto">
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

      <%!-- Checklist Progress --%>
      <div :if={@checklist_progress} class="border-b border-zinc-200 dark:border-zinc-700/80">
        <div class="px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50">
          <div class="flex items-center justify-between">
            <h4 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">Checklist</h4>
            <span class="text-xs text-zinc-400">{@checklist_progress.checked}/{@checklist_progress.total}</span>
          </div>
          <div class="mt-2 h-1.5 rounded-full bg-zinc-200 dark:bg-zinc-700 overflow-hidden">
            <div
              class={"h-full rounded-full transition-all duration-300 #{if @checklist_progress.checked == @checklist_progress.total && @checklist_progress.total > 0, do: "bg-green-500", else: "bg-violet-500"}"}
              style={"width: #{if @checklist_progress.total > 0, do: round(@checklist_progress.checked / @checklist_progress.total * 100), else: 0}%"}
            />
          </div>
        </div>
        <div class="px-4 py-2 space-y-1">
          <div :for={item <- @checklist_progress.items} class="flex items-start gap-2">
            <div class={"flex-none w-4 h-4 rounded border mt-0.5 flex items-center justify-center #{if item.checked, do: "bg-violet-600 border-violet-600", else: "border-zinc-300 dark:border-zinc-600"}"}>
              <svg :if={item.checked} xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3 h-3 text-white">
                <path fill-rule="evenodd" d="M12.416 3.376a.75.75 0 0 1 .208 1.04l-5 7.5a.75.75 0 0 1-1.154.114l-3-3a.75.75 0 0 1 1.06-1.06l2.353 2.353 4.493-6.74a.75.75 0 0 1 1.04-.207Z" clip-rule="evenodd" />
              </svg>
            </div>
            <span class={"text-xs #{if item.checked, do: "text-zinc-400 dark:text-zinc-500 line-through", else: "text-zinc-700 dark:text-zinc-300"}"}>{item.text}</span>
          </div>
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
