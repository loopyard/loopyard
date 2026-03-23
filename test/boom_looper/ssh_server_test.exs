defmodule BoomLooper.SSHServerTest do
  use ExUnit.Case

  alias BoomLooper.Terminal

  @ssh_port 2223

  setup_all do
    {:ok, _pid} = BoomLooper.SSHServer.start_link(port: @ssh_port)

    # Writable user_dir for the SSH client (known_hosts storage)
    user_dir = Path.join(System.tmp_dir!(), "boom-looper-ssh-client-#{:rand.uniform(100_000)}")
    File.mkdir_p!(user_dir)
    File.chmod!(user_dir, 0o700)

    on_exit(fn -> File.rm_rf!(user_dir) end)

    %{user_dir: user_dir}
  end

  defp connect(user, user_dir) do
    :ssh.connect(~c"localhost", @ssh_port, [
      user: String.to_charlist(user),
      user_dir: String.to_charlist(user_dir),
      silently_accept_hosts: true,
      user_interaction: false
    ], 5_000)
  end

  defp local_shell_cmd do
    script = System.find_executable("script")
    case :os.type() do
      {:unix, :darwin} -> {script, ["-q", "/dev/null", "/bin/sh"]}
      _ -> {script, ["-qc", "/bin/sh", "/dev/null"]}
    end
  end

  defp start_terminal(container) do
    {:ok, pid} = GenServer.start_link(Terminal, [container: container, cmd: local_shell_cmd()],
      name: {:via, Registry, {BoomLooper.TerminalRegistry, container}})
    Process.sleep(400)
    {:ok, pid}
  end

  defp stop_terminal(pid) do
    if Process.alive?(pid) do
      GenServer.cast(pid, {:input, "exit\n"})
      ref = Process.monitor(pid)
      receive do
        {:DOWN, ^ref, _, _, _} -> :ok
      after
        2_000 -> GenServer.stop(pid, :normal)
      end
    end
  end

  describe "connection" do
    test "connects with container name as username, no password", %{user_dir: user_dir} do
      container = "ssh-test-#{:rand.uniform(100_000)}"
      {:ok, terminal_pid} = start_terminal(container)

      case connect(container, user_dir) do
        {:ok, conn} -> :ssh.close(conn)
        {:error, reason} -> flunk("SSH connect failed: #{inspect(reason)}")
      end

      stop_terminal(terminal_pid)
    end
  end

  describe "multiplayer" do
    test "SSH and PubSub share the same terminal session", _context do
      container = "ssh-multi-#{:rand.uniform(100_000)}"
      {:ok, terminal_pid} = start_terminal(container)

      Phoenix.PubSub.subscribe(BoomLooper.PubSub, Terminal.topic(container))
      Process.sleep(500)
      drain()

      marker = "SSHMULTI-#{:rand.uniform(1_000_000)}"
      GenServer.cast(terminal_pid, {:input, "echo #{marker}\n"})

      output = collect(2_000)
      assert output =~ marker

      stop_terminal(terminal_pid)
    end
  end

  defp drain do
    receive do
      {:terminal_output, _} -> drain()
    after
      200 -> :ok
    end
  end

  defp collect(timeout) do
    collect_loop("", timeout)
  end

  defp collect_loop(acc, remaining) when remaining <= 0, do: acc
  defp collect_loop(acc, remaining) do
    start = System.monotonic_time(:millisecond)
    receive do
      {:terminal_output, data} ->
        elapsed = System.monotonic_time(:millisecond) - start
        collect_loop(acc <> data, remaining - elapsed)
    after
      remaining -> acc
    end
  end
end
