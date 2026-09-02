defmodule Loopyard.PortExposer do
  @moduledoc """
  TCP proxy that fronts a loopback-bound registry port on `0.0.0.0`.

  Loopyard binds every Docker-published port to `127.0.0.1` so
  nothing is reachable from the LAN by default. When an operator
  toggles exposure on for `{workspace, service, container_port}`,
  this GenServer opens an `:inet` listener on `0.0.0.0:<host_port>`
  and forwards connections to `127.0.0.1:<host_port>`. Closing the
  exposure terminates the GenServer; the listener socket and every
  in-flight connection drop within milliseconds.

  No `docker compose` rewrite. No container restart. The compose
  file stays loopback-only forever — the exposer is what goes
  public, and the user sees exactly one "padlock open" signal per
  exposed port.

  ## Counters

  Every byte forwarded in either direction is tallied. `status/1`
  returns bytes_in / bytes_out / connection count / peer IPs. The
  audit trail of expose/revoke events lives in EventLog; counters
  are a "what's happening right now" view and reset on restart.
  """

  use GenServer, restart: :transient

  require Logger

  alias Loopyard.EventLog

  # --- Public API ---

  def start_link(opts) do
    key = Keyword.fetch!(opts, :key)
    GenServer.start_link(__MODULE__, opts, name: via(key))
  end

  @doc "Return the exposer pid for a registry entry, or nil."
  def whereis({_ws, _svc, _cport} = key) do
    case Registry.lookup(Loopyard.PortExposerRegistry, key) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Live status for the exposer at this key. `:not_running` when no
  exposer is up.
  """
  def status({_ws, _svc, _cport} = key) do
    case whereis(key) do
      nil -> :not_running
      pid -> GenServer.call(pid, :status, 1_000)
    end
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    key = Keyword.fetch!(opts, :key)
    host_port = Keyword.fetch!(opts, :host_port)
    upstream_host = opts |> Keyword.get(:upstream_host, {127, 0, 0, 1}) |> normalize_host()
    upstream_port = Keyword.get(opts, :upstream_port, host_port)
    bind_ip = Keyword.get(opts, :bind_ip, {0, 0, 0, 0})

    case :gen_tcp.listen(host_port, [
           :binary,
           packet: :raw,
           active: false,
           reuseaddr: true,
           ip: bind_ip
         ]) do
      {:ok, listen_sock} ->
        state = %{
          key: key,
          host_port: host_port,
          bind_ip: bind_ip,
          upstream_host: upstream_host,
          upstream_port: upstream_port,
          listen_sock: listen_sock,
          accept_task: nil,
          # client_sock => %{peer: "ip", upstream: upstream_sock}
          clients: %{},
          # upstream_sock => client_sock  (reverse index for O(1) forward)
          upstream_to_client: %{},
          bytes_in: 0,
          bytes_out: 0,
          upstream_failures: 0,
          opened_at: DateTime.utc_now()
        }

        {ws, svc, cport} = key
        bind_str = :inet.ntoa(bind_ip) |> to_string()

        EventLog.info(
          "ports:#{ws}",
          "Proxy #{svc}/#{cport} on #{bind_str}:#{host_port} → 127.0.0.1:#{upstream_port}"
        )

        {:ok, state, {:continue, :start_accepting}}

      {:error, reason} ->
        Logger.error("[PortExposer] Listen on #{host_port} failed: #{inspect(reason)}")
        {:stop, {:listen_failed, reason}}
    end
  end

  @impl true
  def handle_continue(:start_accepting, state) do
    {:noreply, spawn_acceptor(state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      host_port: state.host_port,
      bytes_in: state.bytes_in,
      bytes_out: state.bytes_out,
      connection_count: map_size(state.clients),
      upstream_failures: state.upstream_failures,
      peers:
        state.clients
        |> Map.values()
        |> Enum.map(& &1.peer)
        |> Enum.uniq(),
      opened_at: state.opened_at
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({:accepted, client_sock}, state) do
    state = handle_accepted(state, client_sock)
    # The accept task that sent this message is about to exit. Clear
    # its ref so spawn_acceptor sees nil and launches a new one.
    {:noreply, spawn_acceptor(%{state | accept_task: nil})}
  end

  def handle_info({:tcp, sock, data}, state) do
    state = forward_data(state, sock, data)
    :inet.setopts(sock, active: :once)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, sock}, state) do
    {:noreply, close_pair(state, sock)}
  end

  def handle_info({:tcp_error, sock, _reason}, state) do
    {:noreply, close_pair(state, sock)}
  end

  def handle_info({:EXIT, pid, _reason}, %{accept_task: pid} = state) do
    # Acceptor task crashed BEFORE sending {:accepted, ...} — respawn.
    {:noreply, spawn_acceptor(%{state | accept_task: nil})}
  end

  # Normal EXIT from accept task AFTER it sent {:accepted, ...} and
  # we already cleared accept_task to nil. Nothing to do.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  # Upstream is dead — shut down cleanly so the registry can restart
  # us when the container comes back via discover_docker_ports.
  def handle_info(:upstream_dead, state) do
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen_sock)

    for {client, %{upstream: upstream}} <- state.clients do
      safe_close(client)
      safe_close(upstream)
    end

    {ws, svc, cport} = state.key
    EventLog.info("ports:#{ws}", "Revoked exposure of #{svc}/#{cport}")
    :ok
  end

  # --- Private ---

  defp via(key) do
    {:via, Registry, {Loopyard.PortExposerRegistry, key}}
  end

  defp spawn_acceptor(%{accept_task: nil} = state) do
    server = self()
    listen_sock = state.listen_sock

    task_pid =
      spawn_link(fn ->
        case :gen_tcp.accept(listen_sock) do
          {:ok, client} ->
            :ok = :gen_tcp.controlling_process(client, server)
            send(server, {:accepted, client})

          {:error, :closed} ->
            :ok

          {:error, reason} ->
            Logger.warning("[PortExposer] accept/1 returned #{inspect(reason)}")
        end
      end)

    %{state | accept_task: task_pid}
  end

  defp spawn_acceptor(state), do: state

  defp handle_accepted(state, client_sock) do
    peer = peer_ip(client_sock)

    case :gen_tcp.connect(
           state.upstream_host,
           state.upstream_port,
           [
             :binary,
             packet: :raw,
             active: :once,
             keepalive: true
           ],
           500
         ) do
      {:ok, upstream_sock} ->
        # Enable keepalive on both sides so dead connections (phone
        # loses WiFi, laptop sleeps) are detected within minutes
        # instead of hanging for 2 hours.
        :inet.setopts(client_sock, active: :once, keepalive: true)
        :ok = :gen_tcp.controlling_process(upstream_sock, self())

        %{
          state
          | clients: Map.put(state.clients, client_sock, %{peer: peer, upstream: upstream_sock}),
            upstream_to_client: Map.put(state.upstream_to_client, upstream_sock, client_sock),
            upstream_failures: 0
        }

      {:error, reason} ->
        :gen_tcp.close(client_sock)
        failures = Map.get(state, :upstream_failures, 0) + 1

        if failures >= 5 do
          {_ws, svc, cport} = state.key

          Logger.error(
            "[PortExposer] upstream #{svc}/#{cport} dead after #{failures} failures — shutting down proxy"
          )

          # Self-terminate. Registry will restart us when
          # discover_docker_ports runs on next container start.
          Process.send(self(), :upstream_dead, [])
        else
          if failures == 1 do
            Logger.warning(
              "[PortExposer] upstream :#{state.upstream_port} unreachable: #{inspect(reason)}"
            )
          end
        end

        Map.put(state, :upstream_failures, failures)
    end
  end

  # Data from a CLIENT socket → forward upstream, count as bytes_in.
  # Data from an UPSTREAM socket → forward to its client, count as bytes_out.
  defp forward_data(state, sock, data) do
    cond do
      Map.has_key?(state.clients, sock) ->
        %{upstream: upstream} = Map.get(state.clients, sock)

        case :gen_tcp.send(upstream, data) do
          :ok -> %{state | bytes_in: state.bytes_in + byte_size(data)}
          {:error, _} -> close_pair(state, sock)
        end

      client = Map.get(state.upstream_to_client, sock) ->
        case :gen_tcp.send(client, data) do
          :ok -> %{state | bytes_out: state.bytes_out + byte_size(data)}
          {:error, _} -> close_pair(state, sock)
        end

      true ->
        state
    end
  end

  # Closing either side of a pair tears down both.
  defp close_pair(state, sock) do
    cond do
      entry = Map.get(state.clients, sock) ->
        safe_close(sock)
        safe_close(entry.upstream)

        %{
          state
          | clients: Map.delete(state.clients, sock),
            upstream_to_client: Map.delete(state.upstream_to_client, entry.upstream)
        }

      client = Map.get(state.upstream_to_client, sock) ->
        safe_close(sock)
        safe_close(client)

        %{
          state
          | clients: Map.delete(state.clients, client),
            upstream_to_client: Map.delete(state.upstream_to_client, sock)
        }

      true ->
        state
    end
  end

  defp peer_ip(sock) do
    case :inet.peername(sock) do
      {:ok, {ip, _port}} -> ip |> Tuple.to_list() |> Enum.join(".")
      _ -> "unknown"
    end
  end

  defp safe_close(sock) do
    :gen_tcp.close(sock)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp normalize_host({_, _, _, _} = tuple), do: tuple

  defp normalize_host(str) when is_binary(str) do
    {:ok, ip} = str |> String.to_charlist() |> :inet.parse_address()
    ip
  end
end
