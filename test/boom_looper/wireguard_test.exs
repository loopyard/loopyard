defmodule BoomLooper.WireGuardTest do
  use ExUnit.Case

  alias BoomLooper.WireGuard

  describe "available?/0" do
    test "returns boolean" do
      result = WireGuard.available?()
      assert is_boolean(result)
    end
  end

  describe "server_ip/0 and listen_port/0" do
    test "returns expected values" do
      assert WireGuard.server_ip() == "10.0.42.1"
      assert WireGuard.listen_port() == 51820
      assert WireGuard.interface() == "wg0"
    end
  end

  describe "client management" do
    setup do
      # Only run if wg is available
      unless WireGuard.available?() do
        %{skip: true}
      else
        # Clean up any test clients
        on_exit(fn ->
          for client <- WireGuard.list_clients() do
            if String.starts_with?(client["name"], "test-") do
              WireGuard.remove_client(client["name"])
            end
          end
        end)

        %{skip: false}
      end
    end

    @tag :wireguard
    test "add_client creates client with keypair and IP", %{skip: skip} do
      if skip do
        IO.puts("Skipping: wg not available")
      else
        {:ok, client} = WireGuard.add_client("test-device-#{:rand.uniform(100_000)}")

        assert client["name"] =~ "test-device"
        assert client["public_key"] != nil
        assert client["private_key"] != nil
        assert client["ip"] =~ "10.0.42."
        assert client["created_at"] != nil
      end
    end

    @tag :wireguard
    test "client_config generates valid WireGuard config", %{skip: skip} do
      if skip do
        IO.puts("Skipping: wg not available")
      else
        {:ok, client} = WireGuard.add_client("test-config-#{:rand.uniform(100_000)}")
        config = WireGuard.client_config(client)

        assert config =~ "[Interface]"
        assert config =~ "PrivateKey ="
        assert config =~ client["private_key"]
        assert config =~ client["ip"]
        assert config =~ "[Peer]"
        assert config =~ "PublicKey ="
        assert config =~ "AllowedIPs = 10.0.42.0/24"
        assert config =~ "Endpoint ="
        assert config =~ "PersistentKeepalive = 25"
      end
    end

    @tag :wireguard
    test "remove_client removes from list", %{skip: skip} do
      if skip do
        IO.puts("Skipping: wg not available")
      else
        name = "test-remove-#{:rand.uniform(100_000)}"
        {:ok, _} = WireGuard.add_client(name)
        assert Enum.any?(WireGuard.list_clients(), &(&1["name"] == name))

        WireGuard.remove_client(name)
        refute Enum.any?(WireGuard.list_clients(), &(&1["name"] == name))
      end
    end

    @tag :wireguard
    test "clients get unique IPs", %{skip: skip} do
      if skip do
        IO.puts("Skipping: wg not available")
      else
        {:ok, c1} = WireGuard.add_client("test-ip1-#{:rand.uniform(100_000)}")
        {:ok, c2} = WireGuard.add_client("test-ip2-#{:rand.uniform(100_000)}")

        assert c1["ip"] != c2["ip"]
      end
    end
  end
end
