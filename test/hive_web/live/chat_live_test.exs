defmodule HiveWeb.ChatLiveTest do
  use HiveWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders the chat page at /", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Boom Looper"
      assert html =~ "New Agent"
    end
  end

  describe "new agent screen" do
    test "navigating to /new shows launch form", %{conn: conn} do
      {:ok, view, html} = live(conn, "/new")

      assert html =~ "New Agent"
      assert has_element?(view, "form[phx-submit='spawn_agent']")
    end

    test "launching an agent redirects to chat", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/new")

      view
      |> element("form[phx-submit='spawn_agent']")
      |> render_submit(%{"name" => "Test Agent", "working_dir" => File.cwd!()})

      assert_redirect(view)
    end

    @tag :docker
    test "launching an agent shows booting then transitions to chat", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/new")

      view
      |> element("form[phx-submit='spawn_agent']")
      |> render_submit(%{"name" => "Docker Test", "working_dir" => File.cwd!()})

      {path, _flash} = assert_redirect(view)
      assert path =~ "/chat/"

      # Follow the redirect — should see booting screen
      {:ok, view2, html} = live(conn, path)
      assert html =~ "Starting agent" or html =~ "Send"

      # Wait for agent to boot and transition to chat
      # Use assert_eventually pattern instead of raw sleep
      agent_id = path |> String.split("/") |> List.last()

      Enum.reduce_while(1..30, nil, fn _, _ ->
        Process.sleep(200)
        html = render(view2)

        if html =~ "Send" and html =~ "Docker Test" do
          {:halt, html}
        else
          {:cont, nil}
        end
      end)

      html = render(view2)
      assert html =~ "Send", "Agent never transitioned to chat view"
      assert html =~ "Docker Test"

      # Clean up
      try do
        Hive.ChatAgent.stop_agent(agent_id)
        Hive.Docker.destroy(agent_id)
      catch
        :exit, _ -> :ok
      end
    end
  end

  describe "empty state" do
    test "shows prompt to create or select agent", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Create or select an agent"
    end
  end

  describe "booting state" do
    test "unknown id shows booting screen", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/chat/nonexistent123")
      assert html =~ "Starting agent"
      assert html =~ "nonexistent123"
    end

    test "booting screen shows in sidebar", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat/nonexistent123")
      # Sidebar should show a booting entry with pulsing dot
      assert has_element?(view, "div.animate-pulse")
    end

    test "boot_status updates are shown", %{conn: conn} do
      id = "boot-test-123"
      {:ok, view, _html} = live(conn, "/chat/#{id}")

      # Simulate boot status via PubSub
      Phoenix.PubSub.broadcast(Hive.PubSub, "boot:#{id}", {:boot_status, id, "My Agent", "Building container image..."})
      Process.sleep(50)

      html = render(view)
      assert html =~ "Building container image..."
      assert html =~ "My Agent"
    end

    test "booting transitions to chat when agent starts", %{conn: conn} do
      id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      {:ok, view, html} = live(conn, "/chat/#{id}")
      assert html =~ "Starting agent"

      # Start the agent (which broadcasts chat_agent_started)
      {:ok, _pid} =
        Hive.ChatAgentSupervisor.start_agent(
          id: id,
          name: "Boot Transition Test",
          working_dir: File.cwd!(),
          started_by: "test",
          docker_ready: true
        )

      # Give PubSub time to deliver
      Process.sleep(100)

      html = render(view)
      assert html =~ "Send"
      assert html =~ "Boot Transition Test"
      refute html =~ "Starting agent"

      # Clean up
      try do
        Hive.ChatAgent.stop_agent(id)
      catch
        :exit, _ -> :ok
      end
    end

    test "spawn failure shows error and redirects", %{conn: conn} do
      id = "fail-test-123"
      {:ok, view, _html} = live(conn, "/chat/#{id}")

      # Simulate spawn failure
      Phoenix.PubSub.broadcast(Hive.PubSub, "boot:#{id}", {:agent_spawn_failed, "container exploded"})

      assert_redirect(view, "/")
    end
  end

  describe "tabs" do
    setup %{conn: conn} do
      # Create an agent to test tabs with
      id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

      {:ok, _pid} =
        Hive.ChatAgentSupervisor.start_agent(
          id: id,
          name: "Tab Test",
          working_dir: File.cwd!(),
          started_by: "test",
          docker_ready: true
        )

      on_exit(fn ->
        try do
          Hive.ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        Process.sleep(50)
      end)

      %{conn: conn, agent_id: id}
    end

    test "shows unified chat feed with message input", %{conn: conn, agent_id: id} do
      {:ok, _view, html} = live(conn, "/chat/#{id}")

      assert html =~ "Send"
      assert html =~ "chat-form"
    end

    test "root agent has no tab buttons or container URL", %{conn: conn, agent_id: id} do
      {:ok, view, _html} = live(conn, "/chat/#{id}")

      refute has_element?(view, "button[phx-click='switch_tab']")
      refute has_element?(view, "a[href^='http://localhost:']")
    end

    test "shows agent name and stop button", %{conn: conn, agent_id: id} do
      {:ok, view, html} = live(conn, "/chat/#{id}")

      assert html =~ "Tab Test"
      assert has_element?(view, "button[phx-click='stop_agent']")
    end
  end
end
