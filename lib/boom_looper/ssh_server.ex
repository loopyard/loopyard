defmodule BoomLooper.SSHServer do
  @moduledoc """
  SSH server for terminal access to Docker containers.
  Username is the container name. No password.

    ssh -p 2222 container-name@localhost

  Multiplayer — SSH sessions share the same Terminal GenServer as
  browser console tabs. All viewers see the same terminal.

  Uses `ssh_server_channel` behavior (see `BoomLooper.SSHServer.Channel`)
  for raw byte access — every keystroke arrives immediately, same as
  the websocket path.
  """
  require Logger

  @default_port 2222

  def start_link(opts \\ []) do
    port = Keyword.get(opts, :port, @default_port)
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
        Logger.info("[SSHServer] Listening on port #{port}")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("[SSHServer] Failed to start: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("[SSHServer] Failed to start: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc "The SSH port number."
  def port, do: @default_port

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
