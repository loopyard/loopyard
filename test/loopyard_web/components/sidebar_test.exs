defmodule LoopyardWeb.Components.SidebarTest do
  use ExUnit.Case

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import LoopyardWeb.Components.Sidebar

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
      assert first_host_port(%{"3000" => 32_001}) == "32001"
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

  describe "agent_display_status/1 → status_dot/1" do
    # The agent_item/console_item components were folded into the generic
    # `sidebar_item` (the status→dot mapping moved to the call sites). The
    # *logic* lives in these two public functions — test it directly.
    #
    # agent_display_status falls back to a ChatAgentRegistry lookup when the
    # agent map carries no cached `:alive?` flag, so register a pid under the
    # id to make the "live" cases pass.
    defp register_live_agent(id) do
      {:ok, _} = Registry.register(Loopyard.ChatAgentRegistry, id, nil)
      :ok
    end

    defp dot(agent), do: status_dot(agent_display_status(agent))

    test "live + idle → ready (green)" do
      register_live_agent("a1")
      assert dot(%{id: "a1", name: "Test Agent", status: :idle}) == "bg-green-500"
    end

    test "no live GenServer → sleeping (gray)" do
      assert agent_display_status(%{id: "orphan", name: "Agent", status: :idle}) == :sleeping
      assert dot(%{id: "orphan", name: "Agent", status: :idle}) == "bg-zinc-400"
    end

    test "a cached alive?: false overrides the registry → sleeping" do
      register_live_agent("cached")
      assert dot(%{id: "cached", name: "C", status: :idle, alive?: false}) == "bg-zinc-400"
    end

    test "quarantined → red, regardless of liveness" do
      assert agent_display_status(%{id: "q", name: "Q", status: :idle, quarantined: true}) ==
               :quarantined

      assert dot(%{id: "q", name: "Q", status: :idle, quarantined: true}) == "bg-red-500"
    end

    test "booting (live) → violet pulse" do
      register_live_agent("boot")
      assert dot(%{id: "boot", name: "B", status: :booting}) =~ "animate-pulse"
    end

    test "rate_limited (live) → violet pulse (auto-retry armed)" do
      register_live_agent("rl")
      d = dot(%{id: "rl", name: "RL", status: :rate_limited})
      assert d =~ "bg-violet-500"
      assert d =~ "animate-pulse"
    end

    test "auth_expired (live) → red (terminal without re-auth)" do
      register_live_agent("auth")
      assert dot(%{id: "auth", name: "AuthExp", status: :auth_expired}) == "bg-red-500"
    end

    test "destroying → hidden (gray)" do
      register_live_agent("gone")
      assert agent_display_status(%{id: "gone", name: "G", status: :destroying}) == :hidden
    end

    test "malformed agent map → sleeping (never crashes the sidebar)" do
      assert agent_display_status(%{}) == :sleeping
    end
  end

  describe "service_item/1" do
    test "renders service name with status dot" do
      svc = %{name: "postgres", status: :running, ports: %{"5432" => 32_885}}

      html =
        render_comp(&service_item/1, %{
          svc: svc,
          base_path: "/projects/p1/workspaces/w1",
          selected: false
        })

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
