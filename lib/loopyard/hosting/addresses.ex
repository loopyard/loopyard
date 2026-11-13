defmodule Loopyard.Hosting.Addresses do
  @moduledoc """
  Every address the server can be reached at, for `mix loopyard.service status`:

    * **loopback** — always, `http://127.0.0.1:<port>`.
    * **LAN** — only when bound beyond loopback (`LOOPYARD_BIND`): each
      non-loopback IPv4 interface address (for `0.0.0.0`) or the one bound
      address, plus the Bonjour `<LocalHostName>.local` name on macOS.
    * **tailnet** — when the `tailscale` CLI is present (on `PATH`, or inside
      `/Applications/Tailscale.app`): the HTTPS name `tailscale serve`
      publishes when it proxies to this port, otherwise the machine's
      MagicDNS name with the one command that would publish it.
    * **tunnel** — hostnames in `~/.cloudflared/config.yml` whose ingress
      points at this port (a named Cloudflare tunnel).

  A LiveView websocket works through any of them because dev's endpoint runs
  with `check_origin: false` (see `config/dev.exs`) — a proxy hostname never
  matches the endpoint's `url: [host:]`, and Phoenix's `check_origin: :conn`
  compares the scheme and port too, which an HTTPS proxy in front of plain
  HTTP never satisfies.

  Injectable (`:runner`, `:ifaddrs`, `:find_executable`, `:file_read`) so
  tests never ask the real machine.
  """

  @tailscale_app "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

  @type address :: %{
          kind: :loopback | :lan | :tailnet | :tunnel,
          url: String.t(),
          note: String.t() | nil
        }

  @doc "All addresses for a server on `port` bound to `bind` (an IP string)."
  @spec list(pos_integer(), String.t(), keyword()) :: [address()]
  def list(port, bind, opts \\ []) do
    [%{kind: :loopback, url: "http://127.0.0.1:#{port}", note: nil}] ++
      lan(port, bind, opts) ++ tailnet(port, bind, opts) ++ tunnels(port, opts)
  end

  # ── LAN ──────────────────────────────────────────────────────────────────

  defp lan(port, bind, opts) do
    case :inet.parse_strict_address(String.to_charlist(bind)) do
      {:ok, {127, _, _, _}} ->
        []

      {:ok, {0, 0, 0, 0}} ->
        ips =
          for ip <- interface_ips(opts),
              do: %{kind: :lan, url: "http://#{ip}:#{port}", note: nil}

        ips ++ bonjour(port, opts)

      {:ok, ip} ->
        [%{kind: :lan, url: "http://#{:inet.ntoa(ip)}:#{port}", note: nil}]

      _ ->
        []
    end
  end

  @doc false
  def interface_ips(opts) do
    ifaddrs = Keyword.get(opts, :ifaddrs, &:inet.getifaddrs/0)

    case ifaddrs.() do
      {:ok, ifs} ->
        for {_name, props} <- ifs,
            :up in Keyword.get(props, :flags, []),
            {:addr, {a, _, _, _} = ip} <- props,
            a != 127,
            # Tailscale's CGNAT range is listed under tailnet, not LAN.
            not cgnat?(ip),
            uniq: true,
            do: ip |> :inet.ntoa() |> to_string()

      _ ->
        []
    end
  end

  defp cgnat?({100, b, _, _}) when b in 64..127, do: true
  defp cgnat?(_), do: false

  defp bonjour(port, opts) do
    runner = Loopyard.Hosting.runner(opts)
    find = Keyword.get(opts, :find_executable, &System.find_executable/1)

    with scutil when is_binary(scutil) <- find.("scutil"),
         {name, 0} <- runner.(scutil, ["--get", "LocalHostName"], stderr_to_stdout: true),
         name when name != "" <- String.trim(name) do
      [%{kind: :lan, url: "http://#{name}.local:#{port}", note: "Bonjour"}]
    else
      _ -> []
    end
  end

  # ── tailnet ──────────────────────────────────────────────────────────────

  @doc "The `tailscale` CLI: on PATH, else inside the macOS app bundle."
  @spec tailscale_cli(keyword()) :: String.t() | nil
  def tailscale_cli(opts \\ []) do
    find = Keyword.get(opts, :find_executable, &System.find_executable/1)
    exists? = Keyword.get(opts, :file_exists?, &File.exists?/1)

    find.("tailscale") || if(exists?.(@tailscale_app), do: @tailscale_app)
  end

  defp tailnet(port, bind, opts) do
    runner = Loopyard.Hosting.runner(opts)

    # `status --json` answers with a body even when it exits non-zero (signed
    # out, stopped), so the body decides, not the exit code.
    with cli when is_binary(cli) <- tailscale_cli(opts),
         {json, _} <- runner.(cli, ["status", "--json"], []),
         {:ok, %{"Self" => self} = status} <- Jason.decode(json) do
      case self["DNSName"] do
        dns when is_binary(dns) and dns != "" ->
          host = String.trim_trailing(dns, ".")
          published(cli, host, port, runner) ++ direct_tailnet(port, bind, self)

        _ ->
          [
            %{
              kind: :tailnet,
              url: "(no tailnet name)",
              note: "Tailscale is #{status["BackendState"] || "not connected"}: sign in to it"
            }
          ]
      end
    else
      _ -> []
    end
  end

  defp published(cli, host, port, runner) do
    case served_urls(cli, port, runner) do
      [] ->
        [
          %{
            kind: :tailnet,
            url: "https://#{host}",
            note: "not published; run: #{cli} serve --bg #{port}"
          }
        ]

      served ->
        Enum.map(served, &%{kind: :tailnet, url: &1, note: "tailscale serve"})
    end
  end

  # Listening beyond loopback also answers on the machine's tailnet IP.
  defp direct_tailnet(port, bind, self) do
    if String.starts_with?(bind, "127.") do
      []
    else
      for ip <- self["TailscaleIPs"] || [], not String.contains?(ip, ":") do
        %{kind: :tailnet, url: "http://#{ip}:#{port}", note: "direct"}
      end
    end
  end

  @doc false
  # `tailscale serve status --json` → the https URLs whose handler proxies to
  # this port. Shape: %{"Web" => %{"host:443" => %{"Handlers" => %{"/" =>
  # %{"Proxy" => "http://127.0.0.1:4000"}}}}}.
  def served_urls(cli, port, runner) do
    with {json, 0} <- runner.(cli, ["serve", "status", "--json"], []),
         {:ok, %{"Web" => web}} when is_map(web) <- Jason.decode(json) do
      for {hostport, %{"Handlers" => handlers}} <- web,
          Enum.any?(handlers, fn {_path, h} -> proxies_to?(h["Proxy"], port) end) do
        case String.split(hostport, ":") do
          [host, "443"] -> "https://#{host}"
          [host, p] -> "https://#{host}:#{p}"
          [host] -> "https://#{host}"
        end
      end
    else
      _ -> []
    end
  end

  defp proxies_to?(proxy, port) when is_binary(proxy) do
    proxy == "#{port}" or String.ends_with?(proxy, ":#{port}") or
      String.ends_with?(proxy, ":#{port}/")
  end

  defp proxies_to?(_, _), do: false

  # ── named tunnel ─────────────────────────────────────────────────────────

  defp tunnels(port, opts) do
    read = Keyword.get(opts, :file_read, &File.read/1)
    user_home = Keyword.get_lazy(opts, :user_home, &System.user_home!/0)

    case read.(Path.join([user_home, ".cloudflared", "config.yml"])) do
      {:ok, yaml} ->
        for host <- tunnel_hosts(yaml, port),
            do: %{kind: :tunnel, url: "https://#{host}", note: "cloudflared"}

      _ ->
        []
    end
  end

  @doc """
  Hostnames in a cloudflared `config.yml` whose ingress `service` points at
  `port`. A line scanner, not a YAML parser: it pairs each `hostname:` with
  the next `service:`, which is how every cloudflared ingress rule is written.
  """
  @spec tunnel_hosts(String.t(), pos_integer()) :: [String.t()]
  def tunnel_hosts(yaml, port) do
    yaml
    |> String.split("\n")
    |> Enum.reduce({nil, []}, fn line, {host, acc} ->
      case {ingress_line(line), host} do
        {{:hostname, h}, _} ->
          {h, acc}

        {{:service, svc}, h} when is_binary(h) ->
          {nil, if(proxies_to?(svc, port), do: [h | acc], else: acc)}

        _ ->
          {host, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp ingress_line(line) do
    case Regex.run(~r/^\s*-?\s*(hostname|service):\s*["']?([^\s"']+)/, line) do
      [_, "hostname", v] -> {:hostname, v}
      [_, "service", v] -> {:service, v}
      _ -> nil
    end
  end
end
