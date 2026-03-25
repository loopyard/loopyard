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
    test "returns green for healthy" do
      assert service_dot(%{health: :healthy}) == "bg-green-500"
    end

    test "returns blue for started" do
      assert service_dot(%{health: :started}) == "bg-blue-400"
    end

    test "returns red for crashed" do
      assert service_dot(%{health: :crashed}) == "bg-red-500"
    end

    test "returns blue for running without health" do
      assert service_dot(%{running: true}) == "bg-blue-400"
    end

    test "returns gray for stopped" do
      assert service_dot(%{running: false}) == "bg-zinc-400"
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
    test "renders agent name and status dot" do
      agent = %{id: "a1", name: "Test Agent", status: :idle}
      html = render_comp(&agent_item/1, %{agent: agent, selected: false})
      assert html =~ "Test Agent"
      assert html =~ "bg-green-500"
    end

    test "no remove button in sidebar for any status" do
      for status <- [:idle, :thinking, :stopped, :crashed, :booting] do
        agent = %{id: "a1", name: "Agent", status: status}
        html = render_comp(&agent_item/1, %{agent: agent, selected: false})
        refute html =~ "remove_agent", "expected no remove_agent for status #{status}"
        refute html =~ "&times;", "expected no × for status #{status}"
      end
    end

    test "shows boot status subtitle when booting" do
      agent = %{id: "a1", name: "Agent", status: :booting, boot_status: "Building image..."}
      html = render_comp(&agent_item/1, %{agent: agent, selected: false})
      assert html =~ "Building image..."
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
    test "renders service name with health dot" do
      svc = %{name: "postgres", health: :healthy, running: true, ports: %{"5432" => 32885}}
      html = render_comp(&service_item/1, %{svc: svc, base_path: "/projects/p1/workspaces/w1", selected: false})
      assert html =~ "postgres"
      assert html =~ "bg-green-500"
    end

    test "shows port link when healthy" do
      svc = %{name: "dev", health: :healthy, running: true, ports: %{"3000" => 3000}}
      html = render_comp(&service_item/1, %{svc: svc, base_path: "/base", selected: false})
      assert html =~ "http://localhost:3000"
      assert html =~ ":3000"
    end

    test "does not render remove button" do
      svc = %{name: "redis", health: :healthy, running: true, ports: %{}}
      html = render_comp(&service_item/1, %{svc: svc, base_path: "/base", selected: false})
      refute html =~ "remove"
      refute html =~ "&times;"
    end
  end
end
