defmodule Loopyard.Hosting.AddressesTest do
  use ExUnit.Case, async: true

  alias Loopyard.Hosting.Addresses

  @ifaddrs {:ok,
            [
              {~c"lo0", [flags: [:up, :loopback], addr: {127, 0, 0, 1}]},
              {~c"en0", [flags: [:up, :broadcast], addr: {192, 168, 1, 20}]},
              {~c"en1", [flags: [:broadcast], addr: {10, 0, 0, 9}]},
              {~c"utun4", [flags: [:up], addr: {100, 101, 102, 103}]}
            ]}

  @status Jason.encode!(%{
            "Self" => %{
              "DNSName" => "studio.tail1234.ts.net.",
              "TailscaleIPs" => ["100.101.102.103", "fd7a:115c::1"]
            }
          })

  @served Jason.encode!(%{
            "TCP" => %{"443" => %{"HTTPS" => true}},
            "Web" => %{
              "studio.tail1234.ts.net:443" => %{
                "Handlers" => %{"/" => %{"Proxy" => "http://127.0.0.1:4000"}}
              }
            }
          })

  # No tailscale, no scutil, no cloudflared config unless a test says so.
  defp opts(extra \\ []) do
    Keyword.merge(
      [
        ifaddrs: fn -> @ifaddrs end,
        find_executable: fn _ -> nil end,
        file_exists?: fn _ -> false end,
        file_read: fn _ -> {:error, :enoent} end,
        user_home: "/Users/me",
        runner: fn _, _, _ -> {"", 1} end
      ],
      extra
    )
  end

  defp urls(list), do: Enum.map(list, & &1.url)

  test "loopback only when bound to loopback" do
    assert [%{kind: :loopback, url: "http://127.0.0.1:4000"}] =
             Addresses.list(4000, "127.0.0.1", opts())
  end

  test "0.0.0.0 lists every up, non-loopback, non-tailnet IPv4 interface plus Bonjour" do
    runner = fn "/usr/sbin/scutil", ["--get", "LocalHostName"], _ -> {"studio\n", 0} end

    find = fn
      "scutil" -> "/usr/sbin/scutil"
      _ -> nil
    end

    list = Addresses.list(4000, "0.0.0.0", opts(runner: runner, find_executable: find))

    assert urls(list) == [
             "http://127.0.0.1:4000",
             "http://192.168.1.20:4000",
             "http://studio.local:4000"
           ]
  end

  test "a specific bind address is the one LAN address" do
    assert "http://192.168.1.20:4000" in urls(Addresses.list(4000, "192.168.1.20", opts()))
  end

  describe "tailnet" do
    defp ts_runner(serve_json) do
      fn
        _cli, ["status", "--json"], _ -> {@status, 0}
        _cli, ["serve", "status", "--json"], _ -> serve_json
      end
    end

    test "found inside the macOS app bundle when not on PATH" do
      app = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
      assert Addresses.tailscale_cli(opts(file_exists?: &(&1 == app))) == app
      assert Addresses.tailscale_cli(opts()) == nil

      assert Addresses.tailscale_cli(
               opts(find_executable: fn "tailscale" -> "/usr/local/bin/tailscale" end)
             ) ==
               "/usr/local/bin/tailscale"
    end

    test "tailscale serve's https name when it proxies to our port" do
      o =
        opts(
          find_executable: fn
            "tailscale" -> "ts"
            _ -> nil
          end,
          runner: ts_runner({@served, 0})
        )

      assert %{kind: :tailnet, url: "https://studio.tail1234.ts.net", note: "tailscale serve"} in Addresses.list(
               4000,
               "127.0.0.1",
               o
             )
    end

    test "the MagicDNS name and the command to publish it when serve isn't set up" do
      o =
        opts(
          find_executable: fn
            "tailscale" -> "ts"
            _ -> nil
          end,
          runner: ts_runner({"{}", 0})
        )

      [_, tailnet] = Addresses.list(4000, "127.0.0.1", o)

      assert tailnet.url == "https://studio.tail1234.ts.net"
      assert tailnet.note =~ "ts serve --bg 4000"
    end

    test "serve proxying to a different port doesn't count" do
      o =
        opts(
          find_executable: fn
            "tailscale" -> "ts"
            _ -> nil
          end,
          runner: ts_runner({@served, 0})
        )

      [_, tailnet] = Addresses.list(4100, "127.0.0.1", o)
      assert tailnet.note =~ "not published"
    end

    test "bound beyond loopback also answers on the tailnet IPv4" do
      o =
        opts(
          find_executable: fn
            "tailscale" -> "ts"
            _ -> nil
          end,
          runner: ts_runner({@served, 0})
        )

      assert "http://100.101.102.103:4000" in urls(Addresses.list(4000, "0.0.0.0", o))
    end

    test "a signed-out tailscale says so instead of listing a name" do
      signed_out = Jason.encode!(%{"BackendState" => "NeedsLogin", "Self" => %{"DNSName" => ""}})

      o =
        opts(
          find_executable: fn
            "tailscale" -> "ts"
            _ -> nil
          end,
          runner: fn _, _, _ -> {signed_out, 1} end
        )

      assert [_, %{kind: :tailnet, note: note}] = Addresses.list(4000, "127.0.0.1", o)
      assert note =~ "NeedsLogin"
    end

    test "a tailscale that won't answer lists nothing" do
      o =
        opts(
          find_executable: fn
            "tailscale" -> "ts"
            _ -> nil
          end,
          runner: fn _, _, _ -> {"stopped", 1} end
        )

      assert [%{kind: :loopback}] = Addresses.list(4000, "127.0.0.1", o)
    end
  end

  describe "named tunnel" do
    @yaml """
    tunnel: 6ff42ae2-765d-4adf-8112-31c55c1551ef
    credentials-file: /Users/me/.cloudflared/6ff42ae2.json
    ingress:
      - hostname: loopyard.example.com
        service: http://localhost:4000
      - hostname: "other.example.com"
        service: http://localhost:8080
      - service: http_status:404
    """

    test "hostnames whose ingress points at our port" do
      assert Addresses.tunnel_hosts(@yaml, 4000) == ["loopyard.example.com"]
      assert Addresses.tunnel_hosts(@yaml, 8080) == ["other.example.com"]
    end

    test "listed from ~/.cloudflared/config.yml" do
      read = fn "/Users/me/.cloudflared/config.yml" -> {:ok, @yaml} end

      assert %{kind: :tunnel, url: "https://loopyard.example.com", note: "cloudflared"} in Addresses.list(
               4000,
               "127.0.0.1",
               opts(file_read: read)
             )
    end
  end

  # Any hostname a proxy fronts the server with (a ts.net name, a tunnel
  # hostname) must be accepted by the LiveView socket. `check_origin: :conn`
  # or a host list would reject them (scheme/port differ behind an HTTPS
  # proxy), so the phone would load the page and then never connect.
  test "dev's endpoint accepts websocket origins from any hostname" do
    dev = Config.Reader.read!("config/dev.exs", env: :dev, target: :host)
    assert dev[:loopyard][LoopyardWeb.Endpoint][:check_origin] == false
  end
end
