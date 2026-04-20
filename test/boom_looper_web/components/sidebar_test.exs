defmodule BoomLooperWeb.Components.SidebarTest do
  use ExUnit.Case

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import BoomLooperWeb.Components.Sidebar

  defp render_comp(func, assigns_map) do
    rendered_to_string(func.(Map.new(assigns_map) |> Map.put(:__changed__, %{})))
  end

  describe "status_dot/1" do
    test "returns green for idle" do
      assert status_dot(:idle) == "bg-green-500"
    end

    test "returns animated violet for booting" do
      assert status_dot(:booting) =~ "animate-pulse"
    end

    test "returns gray for stopped" do
      assert status_dot(:stopped) == "bg-zinc-400"
    end

    test "returns red for crashed" do
      assert status_dot(:crashed) == "bg-red-500"
    end

    test "returns gray for unknown status" do
      assert status_dot(:unknown) == "bg-zinc-400"
    end
  end

  describe "service_dot/1" do
    test "returns green for running" do
      assert service_dot(%{status: :running}) == "bg-green-500"
    end

    test "returns blue with pulse for starting" do
      assert service_dot(%{status: :starting}) == "bg-blue-400 animate-pulse"
    end

    test "returns red for crashed" do
      assert service_dot(%{status: :crashed}) == "bg-red-500"
    end

    test "returns gray for stopped" do
      assert service_dot(%{status: :stopped}) == "bg-zinc-400"
    end

    test "returns gray for unknown status" do
      assert service_dot(%{status: :unknown}) == "bg-zinc-400"
      assert service_dot(%{}) == "bg-zinc-400"
    end
  end

  describe "first_host_port/1" do
    test "returns nil for nil" do
      assert first_host_port(nil) == nil
    end

    test "returns nil for empty map" do
      assert first_host_port(%{}) == nil
    end

    test "returns first port as string" do
      assert first_host_port(%{"3000" => 32001}) == "32001"
    end
  end

  describe "thinking_word/1" do
    test "returns a string" do
      assert is_binary(thinking_word("test-agent-123"))
    end

    test "returns different words for different agents" do
      # Not guaranteed but very likely with different IDs
      words = for i <- 1..20, do: thinking_word("agent-#{i}")
      assert length(Enum.uniq(words)) > 1
    end
  end

  describe "service_detail/1" do
    test "returns image name" do
      assert service_detail(%{image: "postgres:15"}) == "postgres:15"
    end

    test "returns command truncated" do
      assert service_detail(%{command: "mix phx.server"}) == "mix phx.server"
    end

    test "returns empty for unknown" do
      assert service_detail(%{}) == ""
    end
  end

  describe "agent_item/1" do
    # agent_display_status/1 checks ChatAgentRegistry to decide if an
    # agent is "Sleeping" (no live GenServer) vs. Ready/Thinking. For
    # these rendering tests to assert the live states, register a
    # dummy pid under the agent id so the liveness check passes.
    defp register_live_agent(id) do
      {:ok, pid} = Task.start_link(fn -> receive do _ -> :ok end end)
      {:ok, _} = Registry.register(BoomLooper.ChatAgentRegistry, id, nil)
      on_exit_stop(pid)
      pid
    end

    defp on_exit_stop(pid) do
      ExUnit.Callbacks.on_exit(fn -> send(pid, :stop) end)
    end

    test "renders agent name and status dot (live idle → green/Ready)" do
      register_live_agent("a1")
      agent = %{id: "a1", name: "Test Agent", status: :idle}
      html = render_comp(&agent_item/1, %{agent: agent, selected: false})
      assert html =~ "Test Agent"
      assert html =~ "bg-green-500"
    end

    test "no live GenServer → Sleeping (gray, no green)" do
      agent = %{id: "orphan", name: "Agent", status: :idle}
      html = render_comp(&agent_item/1, %{agent: agent, selected: false})
      assert html =~ "Sleeping"
      assert html =~ "bg-zinc-400"
      refute html =~ "bg-green-500"
    end

    test "no remove button in sidebar for any status" do
      for status <- [:idle, :thinking, :stopped, :crashed, :booting] do
        agent = %{id: "no-remove-#{status}", name: "Agent", status: status}
        html = render_comp(&agent_item/1, %{agent: agent, selected: false})
        refute html =~ "remove_agent", "expected no remove_agent for status #{status}"
        refute html =~ "&times;", "expected no × for status #{status}"
      end
    end

    test "shows boot status subtitle when booting" do
      register_live_agent("a1-booting")
      agent = %{id: "a1-booting", name: "Agent", status: :booting, boot_status: "Building image..."}
      html = render_comp(&agent_item/1, %{agent: agent, selected: false})
      assert html =~ "Building image..."
    end

    test "quarantined flag → red dot (distinct from :ready/:crashed mapping)" do
      register_live_agent("quar-1")
      agent = %{id: "quar-1", name: "Quar", status: :idle, quarantined: true}
      html = render_comp(&agent_item/1, %{agent: agent, selected: false})
      assert html =~ "bg-red-500"
      refute html =~ "bg-green-500"
    end

    test ":rate_limited status → violet pulse (thinking look — auto-retry armed)" do
      register_live_agent("rl-1")
      agent = %{id: "rl-1", name: "RL", status: :rate_limited}
      html = render_comp(&agent_item/1, %{agent: agent, selected: false})
      assert html =~ "bg-violet-500"
      assert html =~ "animate-pulse"
    end

    test ":auth_expired status → red dot (terminal without manual re-auth)" do
      register_live_agent("auth-1")
      agent = %{id: "auth-1", name: "AuthExp", status: :auth_expired}
      html = render_comp(&agent_item/1, %{agent: agent, selected: false})
      assert html =~ "bg-red-500"
    end
  end

  describe "console_item/1" do
    test "renders console name with green dot" do
      console = %{id: "c1", name: "workspace"}
      html = render_comp(&console_item/1, %{console: console, base_path: "/projects/p1/workspaces/w1", selected: false})
      assert html =~ "workspace"
      assert html =~ "bg-green-500"
    end

    test "does not render remove/close button" do
      console = %{id: "c1", name: "workspace"}
      html = render_comp(&console_item/1, %{console: console, base_path: "/projects/p1/workspaces/w1", selected: false})
      refute html =~ "close_console"
      refute html =~ "remove"
      refute html =~ "&times;"
    end

    test "links to console path" do
      console = %{id: "c1", name: "workspace"}
      html = render_comp(&console_item/1, %{console: console, base_path: "/projects/p1/workspaces/w1", selected: false})
      assert html =~ "/projects/p1/workspaces/w1/consoles/c1"
    end
  end

  describe "service_item/1" do
    test "renders service name with status dot" do
      svc = %{name: "postgres", status: :running, ports: %{"5432" => 32885}}
      html = render_comp(&service_item/1, %{svc: svc, base_path: "/projects/p1/workspaces/w1", selected: false})
      assert html =~ "postgres"
      assert html =~ "bg-green-500"
    end

    test "shows port link when running" do
      svc = %{name: "dev", status: :running, ports: %{"3000" => 3000}}
      html = render_comp(&service_item/1, %{svc: svc, base_path: "/base", selected: false})
      assert html =~ "http://localhost:3000"
      assert html =~ ":3000"
    end

    test "does not render remove button" do
      svc = %{name: "redis", status: :running, ports: %{}}
      html = render_comp(&service_item/1, %{svc: svc, base_path: "/base", selected: false})
      refute html =~ "remove"
      refute html =~ "&times;"
    end
  end
end
