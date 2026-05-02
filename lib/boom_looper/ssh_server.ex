defmodule BoomLooper.SSHServer do
  @moduledoc """
  SSH server for terminal access to Docker containers.
  Username is the container name. No password.

    ssh -p <port> container-name@localhost

  Multiplayer — SSH sessions share the same Terminal GenServer as
  browser console tabs. All viewers see the same terminal.

  Port is configurable:
  - `SSH_PORT` env var — set to a specific port or "0" for auto-assign
  - Default: 0 (OS picks an available port)
  """
  use GenServer
  require Logger

  @default_port 0

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The SSH port number. Returns the actual port (resolved after auto-assign)."
  def port do
    GenServer.call(__MODULE__, :port)
  catch
    :exit, _ -> nil
  end

  @impl true
  def init(opts) do
    port =
      Keyword.get_lazy(opts, :port, fn ->
        case System.get_env("SSH_PORT") do
          nil -> @default_port
          val -> String.to_integer(val)
        end
      end)

    system_dir = ensure_host_keys()
    :ssh.start()

    ssh_opts = [
      system_dir: String.to_charlist(system_dir),
      ssh_cli: {BoomLooper.SSHServer.Channel, []},
      no_auth_needed: true,
      idle_time: :infinity
    ]

    case :ssh.daemon(port, ssh_opts) do
      {:ok, pid} ->
        actual_port = resolve_port(pid, port)
        Logger.info("[SSHServer] Listening on port #{actual_port}")
        {:ok, %{daemon: pid, port: actual_port}}

      {:error, reason} ->
        Logger.error("[SSHServer] Failed to start: #{inspect(reason)}")
        {:stop, reason}
    end
  rescue
    e ->
      Logger.error("[SSHServer] Failed to start: #{Exception.message(e)}")
      {:stop, Exception.message(e)}
  end

  @impl true
  def handle_call(:port, _from, state) do
    {:reply, state.port, state}
  end

  # Catchalls — the SSH daemon itself handles ssh connections; this
  # GenServer only holds the daemon ref + port. No user cast/call
  # expected; absorb strays.
  def handle_call(_msg, _from, state), do: {:reply, {:error, :unknown_call}, state}
  @impl true
  def handle_cast(_msg, state), do: {:noreply, state}
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state[:daemon], do: :ssh.stop_daemon(state.daemon)
  end

  # When port is 0, query the daemon for the actual assigned port
  defp resolve_port(daemon, 0) do
    case :ssh.daemon_info(daemon) do
      {:ok, info} ->
        Keyword.get(info, :port, 0)

      _ ->
        0
    end
  end

  defp resolve_port(_daemon, port), do: port

  # --- Host keys ---

  defp ensure_host_keys do
    dir = Path.join(BoomLooper.Workspace.home_dir(), "ssh")

    unless File.exists?(Path.join(dir, "ssh_host_rsa_key")) do
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)

      rsa_key = :public_key.generate_key({:rsa, 2048, 65537})
      write_pem(dir, "ssh_host_rsa_key", :RSAPrivateKey, rsa_key)

      ec_key = :public_key.generate_key({:namedCurve, :secp256r1})
      write_pem(dir, "ssh_host_ecdsa_key", :ECPrivateKey, ec_key)
    end

    dir
  end

  defp write_pem(dir, filename, type, key) do
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(type, key)])
    path = Path.join(dir, filename)
    File.write!(path, pem)
    File.chmod!(path, 0o600)
  end
end
