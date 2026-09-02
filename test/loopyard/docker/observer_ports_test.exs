defmodule Loopyard.Docker.ObserverPortsTest do
  use ExUnit.Case, async: true

  alias Loopyard.Docker.Observer

  # Regression test for the sidebar "open in browser" link. The
  # Observer parses `docker ps --format {{.Ports}}` output into
  # `%{container_port => host_port}` — if that returns empty, the
  # sidebar's `first_host_port/1` returns nil and the port link
  # silently disappears.
  #
  # We bind published ports to 127.0.0.1 (not 0.0.0.0) for per-
  # workspace isolation. An earlier version of this parser hard-
  # coded `0.0.0.0:...` and stopped matching once the security
  # change landed. This test fails noisily if anyone narrows the
  # regex again.

  describe "parse_host_ports/1" do
    test "parses 127.0.0.1-bound ports (our production default)" do
      assert %{3000 => 33_958} = Observer.parse_host_ports("127.0.0.1:33958->3000/tcp")
    end

    test "still parses 0.0.0.0-bound ports (legacy / LAN deployments)" do
      assert %{3000 => 33_958} = Observer.parse_host_ports("0.0.0.0:33958->3000/tcp")
    end

    test "parses IPv6 [::] prefix" do
      assert %{3000 => 33_958} = Observer.parse_host_ports("[::]:33958->3000/tcp")
    end

    test "parses multiple port mappings in one string" do
      input = "127.0.0.1:33958->3000/tcp, 127.0.0.1:33959->4000/tcp"

      assert %{3000 => 33_958, 4000 => 33_959} = Observer.parse_host_ports(input)
    end

    test "mixed v4 and v6 bindings" do
      input = "0.0.0.0:33958->3000/tcp, [::]:33958->3000/tcp, 127.0.0.1:33959->4000/tcp"

      assert %{3000 => 33_958, 4000 => 33_959} = Observer.parse_host_ports(input)
    end

    test "returns empty map for empty or non-binary input" do
      assert %{} = Observer.parse_host_ports("")
      assert %{} = Observer.parse_host_ports(nil)
      assert %{} = Observer.parse_host_ports(:not_a_string)
    end

    test "ignores garbage text around valid mappings" do
      input = "unrelated noise 127.0.0.1:33958->3000/tcp more noise"
      assert %{3000 => 33_958} = Observer.parse_host_ports(input)
    end
  end
end
