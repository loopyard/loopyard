defmodule BoomLooperWeb.ChatLiveTest do
  use BoomLooperWeb.ConnCase

  import Phoenix.LiveViewTest

  defp create_workspace do
    tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-chat-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    # Create a minimal workspace config so auto-spawn Setup doesn't trigger on /new
    repo_dir = Path.join(tmp_dir, ".boomlooper/repo")
    File.mkdir_p!(repo_dir)
    File.write!(Path.join(repo_dir, "workspace.json"), Jason.encode!(%{"name" => "test"}))
    {:ok, _project, workspace} = BoomLooper.ProjectRegistry.add(tmp_dir)
    {workspace, tmp_dir}
  end

  setup do
    {ws, tmp_dir} = create_workspace()

    # Create an agent so the branch view doesn't redirect to /new
    setup_agent_id = "setup-#{:rand.uniform(100_000)}"
    {:ok, _pid} = BoomLooper.TestHelpers.start_agent(
      id: setup_agent_id,
      name: "Test Agent",
      working_dir: tmp_dir,
      bind_mount: tmp_dir,
      started_by: "test"
    )

    on_exit(fn ->
      try do
        BoomLooper.ChatAgent.stop_agent(setup_agent_id)
      catch
        :exit, _ -> :ok
      end
      Process.sleep(50)
      File.rm_rf!(tmp_dir)
    end)

    %{workspace: ws, tmp_dir: tmp_dir, setup_agent_id: setup_agent_id}
  end

  defp ws_path(ws), do: "/projects/#{ws.project_id}/workspaces/#{ws.id}"
  defp ws_new_path(ws), do: "/projects/#{ws.project_id}/workspaces/#{ws.id}/new"
  defp ws_chat_path(ws, id), do: "/projects/#{ws.project_id}/workspaces/#{ws.id}/agents/#{id}"

  # Add services to workspace config so ServiceStatus finds them
  # Write docker-compose.yml with given services (ServiceStatus reads from this file)
  defp add_services_to_workspace(ws, services) do
    compose_dir = Path.join([ws.path, ".boomlooper", "workspace"])
    File.mkdir_p!(compose_dir)

    services_yaml = services
    |> Enum.map(fn svc ->
      name = svc["name"]
      image = svc["image"]
      "  #{name}:\n    image: #{image}"
    end)
    |> Enum.join("\n")

    content = "services:\n#{services_yaml}\n"
    File.write!(Path.join(compose_dir, "docker-compose.yml"), content)
  end

  # Flush the LiveView mailbox by rendering, ensuring PubSub messages are processed.
  # We subscribe + drain to confirm delivery, then render the view.
  defp flush_lv(view) do
    # Small yield to let PubSub deliver
    Process.sleep(5)
    render(view)
  end

  describe "mount" do
    test "branch with agent renders chat page", %{conn: conn, workspace: ws, setup_agent_id: setup_agent_id} do
      {:ok, _view, html} = live(conn, ws_chat_path(ws, setup_agent_id))
      # Agent view shows the agent name in header
      assert html =~ "Test Agent"
    end

    test "redirects to / for unknown workspace", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/projects/nonexistent/workspaces/nonexistent")
    end

    test "workspace :index mount returns under 500ms — compose check is async", %{conn: conn, workspace: ws} do
      # Lands on /projects/X/workspaces/Y. Previously this synchronously
      # called VolumeManager.read_file (docker run alpine cat) — could
      # take seconds. Now the read happens in start_async; mount must
      # paint immediately and the navigate (if any) lands later.
      {micros, _result} = :timer.tc(fn ->
        live(conn, "/projects/#{ws.project_id}/workspaces/#{ws.id}")
      end)
      assert micros < 500_000,
        "ChatLive :index mount took #{div(micros, 1000)}ms — sync compose check leaked back in"
    end

    test "workspace :chat mount returns under 500ms", %{conn: conn, workspace: ws, setup_agent_id: setup_agent_id} do
      {micros, _result} = :timer.tc(fn -> live(conn, ws_chat_path(ws, setup_agent_id)) end)
      assert micros < 500_000,
        "ChatLive :chat mount took #{div(micros, 1000)}ms — sync slow call leaked in"
    end

    test "volume-based workspace mounts correctly", %{conn: conn} do
      # Create a volume-based project/workspace directly in ETS
      project_id = "vol-proj-#{:rand.uniform(100_000)}"
      workspace_id = "vol-ws-#{:rand.uniform(100_000)}"

      project = %{
        id: project_id,
        name: "Volume Test",
        git_url: "https://github.com/test/repo.git",
        is_git: true,
        volume_based: true,
        added_at: DateTime.utc_now()
      }
      :ets.insert(:project_registry, {project_id, project})

      workspace = %{
        id: workspace_id,
        project_id: project_id,
        name: "main",
        branch: "main",
        git_url: "https://github.com/test/repo.git",
        volume: "bl-#{workspace_id}-code",
        volume_based: true,
        status: :stopped,
        added_at: DateTime.utc_now()
      }
      :ets.insert(:workspace_registry, {workspace_id, workspace})

      # Create the expected virtual path directory
      expected_path = Path.join([BoomLooper.Workspace.home_dir(), "workspaces", workspace_id])
      File.mkdir_p!(expected_path)

      # Create workspace config so auto-spawn Setup doesn't trigger
      repo_dir = Path.join(expected_path, ".boomlooper/repo")
      File.mkdir_p!(repo_dir)
      File.write!(Path.join(repo_dir, "workspace.json"), Jason.encode!(%{"name" => "test"}))

      # Create an agent for this workspace
      agent_id = "vol-agent-#{:rand.uniform(100_000)}"
      {:ok, _pid} = BoomLooper.TestHelpers.start_agent(
        id: agent_id,
        name: "Volume Agent",
        working_dir: expected_path,
        bind_mount: expected_path,
        started_by: "test",
        workspace_id: workspace_id
      )

      on_exit(fn ->
        try do
          BoomLooper.ChatAgent.stop_agent(agent_id)
        catch
          :exit, _ -> :ok
        end
        :ets.delete(:project_registry, project_id)
        :ets.delete(:workspace_registry, workspace_id)
        File.rm_rf!(expected_path)
      end)

      # Mount the LiveView - should not crash
      {:ok, _view, html} = live(conn, "/projects/#{project_id}/workspaces/#{workspace_id}/agents/#{agent_id}")
      assert html =~ "Volume Agent"
    end
  end

  describe "new agent screen" do
    test "navigating to /new shows agent picker when config exists", %{conn: conn, workspace: ws, setup_agent_id: _setup_agent_id} do
      # Config exists and agents exist → shows the new agent picker form
      {:ok, _view, html} = live(conn, ws_new_path(ws))
      assert html =~ "New Agent"
      assert html =~ "Launch Agent"
    end

    test "launching an agent redirects to chat", %{conn: conn, workspace: ws, setup_agent_id: _setup_agent_id} do
      # Submit the spawn form → redirects to the new agent's chat
      {:ok, view, _html} = live(conn, ws_new_path(ws))

      view
      |> element("form[phx-submit='spawn_agent']")
      |> render_submit(%{})

      {path, _flash} = assert_redirect(view)
      assert path =~ "/projects/#{ws.project_id}/workspaces/#{ws.id}/agents/"
    end

    @tag :docker
    test "launching an agent shows booting then transitions to chat", %{conn: conn, workspace: ws, setup_agent_id: _setup_agent_id} do
      {:ok, view, _html} = live(conn, ws_new_path(ws))

      view
      |> element("form[phx-submit='spawn_agent']")
      |> render_submit(%{})

      {path, _flash} = assert_redirect(view)
      assert path =~ "/projects/#{ws.project_id}/workspaces/#{ws.id}/agents/"

      {:ok, view2, html} = live(conn, path)
      assert html =~ "Starting agent" or html =~ "Send"

      agent_id = path |> String.split("/") |> List.last()

      Enum.reduce_while(1..30, nil, fn _, _ ->
        Process.sleep(200)
        html = render(view2)

        if html =~ "Send" do
          {:halt, html}
        else
          {:cont, nil}
        end
      end)

      html = render(view2)
      assert html =~ "Send", "Agent never transitioned to chat view"

      try do
        BoomLooper.ChatAgent.stop_agent(agent_id)
      catch
        :exit, _ -> :ok
      end
    end
  end

  describe "empty state" do
    test "branch with agent shows chat view", %{conn: conn, workspace: ws, setup_agent_id: agent_id} do
      {:ok, _view, html} = live(conn, ws_chat_path(ws, agent_id))
      # Shows the agent name header when viewing a single agent
      assert html =~ "Test Agent"
    end
  end

  describe "booting state" do
    test "unknown agent id redirects to workspace home with error", %{conn: conn, workspace: ws, setup_agent_id: _setup_agent_id} do
      assert {:error, {:live_redirect, %{to: path, flash: %{"error" => "Agent not found"}}}} =
               live(conn, ws_chat_path(ws, "nonexistent123"))

      assert path == ws_path(ws)
    end

    test "booting agent shows booting screen", %{conn: conn, workspace: ws, setup_agent_id: _setup_agent_id} do
      id = "boot-test-#{:rand.uniform(100_000)}"
      BoomLooper.ChatAgent.register_booting(id, "My Agent", ws.path)

      on_exit(fn ->
        BoomLooper.ChatAgent.ensure_ets_table()
        :ets.delete(:chat_agents, id)
      end)

      {:ok, view, html} = live(conn, ws_chat_path(ws, id))
      assert html =~ "Starting agent"
      assert html =~ "My Agent"
      assert has_element?(view, "div.animate-pulse")
    end

    test "boot_status updates are shown to all viewers", %{conn: conn, workspace: ws, setup_agent_id: _setup_agent_id} do
      id = "boot-test-#{:rand.uniform(100_000)}"
      BoomLooper.ChatAgent.register_booting(id, "My Agent", ws.path)

      on_exit(fn ->
        BoomLooper.ChatAgent.ensure_ets_table()
        :ets.delete(:chat_agents, id)
      end)

      {:ok, view, _html} = live(conn, ws_chat_path(ws, id))

      BoomLooper.ChatAgent.update_boot_status(id, "Building container image...")

      html = flush_lv(view)
      assert html =~ "Building container image..."
    end

    test "booting transitions to chat when agent starts", %{conn: conn, workspace: ws, setup_agent_id: _setup_agent_id} do
      id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      BoomLooper.ChatAgent.register_booting(id, "Boot Transition Test", ws.path)
      BoomLooper.ChatAgent.subscribe()

      {:ok, view, html} = live(conn, ws_chat_path(ws, id))
      assert html =~ "Starting agent"

      {:ok, _pid} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "Boot Transition Test",
          working_dir: ws.path,
          bind_mount: ws.path,
          started_by: "test"
        )

      assert_receive {:chat_agent_started, _}, 500

      html = render(view)
      assert html =~ "Send"
      assert html =~ "Boot Transition Test"
      refute html =~ "Starting agent"

      try do
        BoomLooper.ChatAgent.stop_agent(id)
      catch
        :exit, _ -> :ok
      end
    end

    test "boot failure removes agent and shows error", %{conn: conn, workspace: ws, setup_agent_id: _setup_agent_id} do
      id = "fail-test-#{:rand.uniform(100_000)}"
      BoomLooper.ChatAgent.register_booting(id, "Fail Agent", ws.path)

      {:ok, view, _html} = live(conn, ws_chat_path(ws, id))

      BoomLooper.ChatAgent.boot_failed(id, "container exploded")

      assert_redirect(view, ws_path(ws))
    end
  end

  describe "agent lifecycle states" do
    setup %{workspace: ws} do
      id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

      {:ok, _pid} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "Lifecycle Test",
          working_dir: ws.path,
          bind_mount: ws.path,
          started_by: "test"
        )

      on_exit(fn ->
        try do
          BoomLooper.ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        BoomLooper.ChatAgent.ensure_ets_table()
        :ets.delete(:chat_agents, id)
      end)

      %{agent_id: id}
    end

    test "idle agent shows green dot and stop button", %{conn: conn, agent_id: id, workspace: ws} do
      {:ok, view, _html} = live(conn, ws_chat_path(ws, id))
      assert has_element?(view, "div.bg-green-500")
      assert has_element?(view, "button[phx-click='stop_agent']")
    end

    test "stopped agent shows remove button", %{conn: conn, agent_id: id, workspace: ws} do
      BoomLooper.ChatAgent.subscribe()
      BoomLooper.ChatAgent.stop_agent(id)
      assert_receive {:chat_agent_stopped, _}, 500

      {:ok, view, _html} = live(conn, ws_chat_path(ws, id))
      assert has_element?(view, "button[phx-click='remove_agent']")
    end

    test "destroying state is broadcast to all viewers", %{conn: conn, agent_id: id, workspace: ws} do
      BoomLooper.ChatAgent.subscribe()
      BoomLooper.ChatAgent.stop_agent(id)
      assert_receive {:chat_agent_stopped, _}, 500

      {:ok, _view, _html} = live(conn, ws_chat_path(ws, id))

      BoomLooper.ChatAgent.remove_agent(id)
      assert_receive {:chat_agent_status_changed, ^id, :destroying}, 1000
      assert_receive {:chat_agent_removed, ^id}, 1000
    end

    @tag :docker
    test "destroying agent is eventually removed after cleanup", %{agent_id: id} do
      BoomLooper.ChatAgent.subscribe()
      BoomLooper.ChatAgent.stop_agent(id)
      assert_receive {:chat_agent_stopped, _}, 500

      BoomLooper.ChatAgent.remove_agent(id)
      assert_receive {:chat_agent_status_changed, ^id, :destroying}, 1000
      assert_receive {:chat_agent_removed, ^id}, 5000
    end
  end

  describe "tabs" do
    setup %{workspace: ws} do
      id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

      {:ok, _pid} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "Tab Test",
          working_dir: ws.path,
          bind_mount: ws.path,
          started_by: "test"
        )

      on_exit(fn ->
        try do
          BoomLooper.ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end
      end)

      %{agent_id: id}
    end

    test "shows unified chat feed with message input", %{conn: conn, agent_id: id, workspace: ws} do
      {:ok, _view, html} = live(conn, ws_chat_path(ws, id))

      assert html =~ "Send"
      assert html =~ "chat-form"
    end

    test "shows agent name and stop button", %{conn: conn, agent_id: id, workspace: ws} do
      {:ok, view, html} = live(conn, ws_chat_path(ws, id))

      assert html =~ "Tab Test"
      assert has_element?(view, "button[phx-click='stop_agent']")
    end
  end

  describe "workspace-aware boot" do
    test "agent includes workspace tools", %{workspace: ws} do
      id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

      {:ok, _pid} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "WS Tools Test",
          working_dir: ws.path,
          bind_mount: ws.path,
          started_by: "test"
        )

      on_exit(fn ->
        try do
          BoomLooper.ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end
      end)

      state = BoomLooper.ChatAgent.get_state(id)
      assert state.bind_mount == ws.path
    end
  end

  describe "service statuses in sidebar" do
    test "sidebar renders service indicators when services defined in workspace", %{conn: conn, workspace: ws, setup_agent_id: setup_agent_id} do
      # Add services to workspace config - ServiceStatus reads from config, not PubSub
      add_services_to_workspace(ws, [%{"name" => "postgres", "image" => "postgres:16"}])

      {:ok, _view, html} = live(conn, ws_chat_path(ws, setup_agent_id))
      assert html =~ "Services"
      assert html =~ "postgres"
    end

    test "sidebar shows no services section when no services configured", %{conn: conn, workspace: ws, setup_agent_id: setup_agent_id} do
      {:ok, _view, html} = live(conn, ws_chat_path(ws, setup_agent_id))
      refute html =~ "Services"
    end

    test "sidebar shows Agents section header when agents exist", %{conn: conn, workspace: ws, setup_agent_id: setup_agent_id} do
      id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

      {:ok, _pid} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "Section Test",
          working_dir: ws.path,
          bind_mount: ws.path,
          started_by: "test"
        )

      on_exit(fn ->
        try do
          BoomLooper.ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, _view, html} = live(conn, ws_chat_path(ws, setup_agent_id))
      assert html =~ "Agents"
    end

    test "service items link to service log view", %{conn: conn, workspace: ws, setup_agent_id: setup_agent_id} do
      add_services_to_workspace(ws, [%{"name" => "redis", "image" => "redis:7"}])

      {:ok, _view, html} = live(conn, ws_chat_path(ws, setup_agent_id))
      assert html =~ "/projects/#{ws.project_id}/workspaces/#{ws.id}/services/redis"
    end

    test "stock services appear in sidebar", %{conn: conn, workspace: ws, setup_agent_id: setup_agent_id} do
      add_services_to_workspace(ws, [%{"name" => "postgres", "image" => "postgres:16"}])

      {:ok, _view, html} = live(conn, ws_chat_path(ws, setup_agent_id))
      assert html =~ "Services"
      assert html =~ "postgres"
    end

    test "process services appear in sidebar", %{conn: conn, workspace: ws, setup_agent_id: setup_agent_id} do
      # Add a process service (not a stock service like postgres/redis)
      compose_dir = Path.join([ws.path, ".boomlooper", "workspace"])
      File.mkdir_p!(compose_dir)
      content = """
      services:
        dev:
          build: .
          command: bin/rails server
      """
      File.write!(Path.join(compose_dir, "docker-compose.yml"), content)

      {:ok, _view, html} = live(conn, ws_chat_path(ws, setup_agent_id))
      assert html =~ "Services"
      assert html =~ "dev"
    end
  end

  describe "service log views" do
    test "services view renders All Services heading", %{conn: conn, workspace: ws, setup_agent_id: _setup_agent_id} do
      {:ok, _view, html} = live(conn, "/projects/#{ws.project_id}/workspaces/#{ws.id}/services")
      assert html =~ "All Services"
    end

    test "service view renders service name in header", %{conn: conn, workspace: ws, setup_agent_id: _setup_agent_id} do
      {:ok, view, _html} = live(conn, "/projects/#{ws.project_id}/workspaces/#{ws.id}/services/postgres")

      # Broadcast service statuses so the view has data
      statuses = [%{name: "postgres", image: "postgres:16", running: true, container: "boom-looper-svc-test-pg", ports: %{}}]
      Phoenix.PubSub.broadcast(BoomLooper.PubSub, "workspace_services", {:services_updated, ws.path, statuses})

      html = flush_lv(view)
      assert html =~ "postgres"
    end
  end

  describe "restart CLI" do
    setup %{workspace: ws} do
      id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

      {:ok, _pid} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "Restart CLI Test",
          working_dir: ws.path,
          bind_mount: ws.path,
          started_by: "test"
        )

      on_exit(fn ->
        try do
          BoomLooper.ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end
      end)

      %{agent_id: id}
    end

    test "shows restart CLI button for active agents", %{conn: conn, agent_id: id, workspace: ws} do
      {:ok, view, _html} = live(conn, ws_chat_path(ws, id))
      assert has_element?(view, "button[phx-click='restart_session']")
    end

    test "restart_session event triggers agent restart", %{conn: conn, agent_id: id, workspace: ws} do
      {:ok, view, _html} = live(conn, ws_chat_path(ws, id))

      view
      |> element("button[phx-click='restart_session']")
      |> render_click()

      # Agent should still be accessible after restart
      Process.sleep(100)
      state = BoomLooper.ChatAgent.get_state(id)
      assert state.status == :idle
    end
  end

  describe "context panel" do
    setup %{workspace: ws} do
      id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

      {:ok, _pid} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "Context Test",
          working_dir: ws.path,
          bind_mount: ws.path,
          started_by: "test"
        )

      on_exit(fn ->
        try do
          BoomLooper.ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end
      end)

      %{agent_id: id}
    end

    test "context panel always shows agent info", %{conn: conn, agent_id: id, workspace: ws} do
      {:ok, _view, html} = live(conn, ws_chat_path(ws, id))

      assert html =~ "Agent Context"
      assert html =~ "Context Test"
    end
  end
end
