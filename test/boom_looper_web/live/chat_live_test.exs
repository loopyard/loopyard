defmodule BoomLooperWeb.ChatLiveTest do
  use BoomLooperWeb.ConnCase

  import Phoenix.LiveViewTest

  defp create_workspace do
    tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-chat-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    # Create a minimal workspace config so auto-spawn Setup doesn't trigger on /new
    hive_dir = Path.join(tmp_dir, ".hive")
    File.mkdir_p!(hive_dir)
    File.write!(Path.join(hive_dir, "workspace.json"), Jason.encode!(%{"name" => "test"}))
    {:ok, _project, branch} = BoomLooper.ProjectRegistry.add(tmp_dir)
    # Return branch as workspace-compatible map
    {branch, tmp_dir}
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

  defp ws_path(ws), do: "/p/#{ws.project_id}/b/#{ws.id}"
  defp ws_new_path(ws), do: "/p/#{ws.project_id}/b/#{ws.id}/new"
  defp ws_chat_path(ws, id), do: "/p/#{ws.project_id}/b/#{ws.id}/chat/#{id}"

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
      assert html =~ "New Agent"
    end

    test "redirects to / for unknown branch", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/p/nonexistent/b/nonexistent")
    end
  end

  describe "new agent screen" do
    test "navigating to /new shows checklist picker", %{conn: conn, workspace: ws, setup_agent_id: setup_agent_id} do
      {:ok, _view, html} = live(conn, ws_new_path(ws))

      assert html =~ "Setup"
      assert html =~ "Feature Development"
    end

    test "launching an agent redirects to chat", %{conn: conn, workspace: ws, setup_agent_id: setup_agent_id} do
      {:ok, view, _html} = live(conn, ws_new_path(ws))

      view
      |> element("form[phx-submit='spawn_agent']")
      |> render_submit(%{})

      {path, _flash} = assert_redirect(view)
      assert path =~ "/p/#{ws.project_id}/b/#{ws.id}/chat/"
    end

    @tag :docker
    test "launching an agent shows booting then transitions to chat", %{conn: conn, workspace: ws, setup_agent_id: setup_agent_id} do
      {:ok, view, _html} = live(conn, ws_new_path(ws))

      view
      |> element("form[phx-submit='spawn_agent']")
      |> render_submit(%{})

      {path, _flash} = assert_redirect(view)
      assert path =~ "/p/#{ws.project_id}/b/#{ws.id}/chat/"

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
    test "branch with agent shows agents section", %{conn: conn, workspace: ws, setup_agent_id: agent_id} do
      {:ok, _view, html} = live(conn, ws_chat_path(ws, agent_id))
      assert html =~ "Agents"
    end
  end

  describe "booting state" do
    test "unknown agent id redirects to workspace home with error", %{conn: conn, workspace: ws, setup_agent_id: setup_agent_id} do
      assert {:error, {:live_redirect, %{to: path, flash: %{"error" => "Agent not found"}}}} =
               live(conn, ws_chat_path(ws, "nonexistent123"))

      assert path == ws_path(ws)
    end

    test "booting agent shows booting screen", %{conn: conn, workspace: ws, setup_agent_id: setup_agent_id} do
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

    test "boot_status updates are shown to all viewers", %{conn: conn, workspace: ws, setup_agent_id: setup_agent_id} do
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

    test "booting transitions to chat when agent starts", %{conn: conn, workspace: ws, setup_agent_id: setup_agent_id} do
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

    test "boot failure removes agent and shows error", %{conn: conn, workspace: ws, setup_agent_id: setup_agent_id} do
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

      {:ok, view, _html} = live(conn, ws_chat_path(ws, id))

      BoomLooper.ChatAgent.remove_agent(id)
      assert_receive {:chat_agent_status_changed, ^id, :destroying}, 1000

      html = render(view)
      assert html =~ "Destroying"
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
    test "sidebar renders service indicators when services_updated PubSub arrives", %{conn: conn, workspace: ws, setup_agent_id: setup_agent_id} do
      {:ok, view, html} = live(conn, ws_chat_path(ws, setup_agent_id))
      refute html =~ "Services"

      # Simulate services_updated PubSub broadcast
      statuses = [%{name: "postgres", image: "postgres:16", running: true, container: "boom-looper-svc-test-postgres", ports: %{}}]
      Phoenix.PubSub.broadcast(BoomLooper.PubSub, "workspace_services", {:services_updated, ws.path, statuses})

      html = flush_lv(view)
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
      {:ok, view, _html} = live(conn, ws_chat_path(ws, setup_agent_id))

      statuses = [%{name: "redis", image: "redis:7", running: true, container: "boom-looper-svc-test-redis", ports: %{}}]
      Phoenix.PubSub.broadcast(BoomLooper.PubSub, "workspace_services", {:services_updated, ws.path, statuses})

      html = flush_lv(view)
      assert html =~ "/p/#{ws.project_id}/b/#{ws.id}/service/redis"
    end

    test "services with ports show port URL", %{conn: conn, workspace: ws, setup_agent_id: setup_agent_id} do
      {:ok, view, _html} = live(conn, ws_chat_path(ws, setup_agent_id))

      statuses = [%{name: "web", command: "mix phx.server", running: true, container: "boom-looper-svc-test-web", ports: %{4000 => 4000}}]
      Phoenix.PubSub.broadcast(BoomLooper.PubSub, "workspace_services", {:services_updated, ws.path, statuses})

      html = flush_lv(view)
      assert html =~ ":4000"
      assert html =~ "localhost:4000"
    end

    test "services without ports show image or command instead", %{conn: conn, workspace: ws, setup_agent_id: setup_agent_id} do
      {:ok, view, _html} = live(conn, ws_chat_path(ws, setup_agent_id))

      statuses = [%{name: "postgres", image: "postgres:16", running: true, container: "boom-looper-svc-test-pg", ports: %{}}]
      Phoenix.PubSub.broadcast(BoomLooper.PubSub, "workspace_services", {:services_updated, ws.path, statuses})

      html = flush_lv(view)
      assert html =~ "postgres:16"
      refute html =~ "localhost:"
    end
  end

  describe "service log views" do
    test "/w/:id/services renders All Services heading", %{conn: conn, workspace: ws, setup_agent_id: setup_agent_id} do
      {:ok, _view, html} = live(conn, "/p/#{ws.project_id}/b/#{ws.id}/services")
      assert html =~ "All Services"
    end

    test "/w/:id/service/:name renders service name in header", %{conn: conn, workspace: ws, setup_agent_id: setup_agent_id} do
      {:ok, view, _html} = live(conn, "/p/#{ws.project_id}/b/#{ws.id}/service/postgres")

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

    test "checklist_updated PubSub updates progress in context panel", %{conn: conn, agent_id: id, workspace: ws} do
      {:ok, view, _html} = live(conn, ws_chat_path(ws, id))

      progress = %{checked: 3, total: 7, items: [
        %{text: "Step 1", checked: true, line: 3},
        %{text: "Step 2", checked: true, line: 4},
        %{text: "Step 3", checked: true, line: 5},
        %{text: "Step 4", checked: false, line: 6},
        %{text: "Step 5", checked: false, line: 7},
        %{text: "Step 6", checked: false, line: 8},
        %{text: "Step 7", checked: false, line: 9}
      ]}

      Phoenix.PubSub.broadcast(BoomLooper.PubSub, "chat_agents", {:checklist_updated, id, progress})

      html = flush_lv(view)
      assert html =~ "3/7"
      assert html =~ "Step 1"
      assert html =~ "Step 7"
    end
  end
end
