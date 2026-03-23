defmodule BoomLooper.SSHServerTest do
  use ExUnit.Case, async: false

  alias BoomLooper.Terminal

  @ssh_port 2223

  setup_all do
    {:ok, _pid} = BoomLooper.SSHServer.start_link(port: @ssh_port)

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

  defp open_shell(conn) do
    {:ok, chan} = :ssh_connection.session_channel(conn, 5_000)
    result = :ssh_connection.ptty_alloc(conn, chan, [])
    assert result in [:ok, :success], "ptty_alloc failed: #{inspect(result)}"
    result = :ssh_connection.shell(conn, chan)
    assert result in [:ok, :success], "shell failed: #{inspect(result)}"
    chan
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
    test "connects with container name as username", %{user_dir: user_dir} do
      container = "ssh-conn-#{:rand.uniform(100_000)}"
      {:ok, terminal_pid} = start_terminal(container)

      {:ok, conn} = connect(container, user_dir)
      :ssh.close(conn)

      stop_terminal(terminal_pid)
    end
  end

  describe "raw byte I/O" do
    @tag timeout: 10_000
    test "SSH sends individual characters immediately (no line buffering)", %{user_dir: user_dir} do
      container = "ssh-raw-#{:rand.uniform(100_000)}"
      {:ok, terminal_pid} = start_terminal(container)

      Phoenix.PubSub.subscribe(BoomLooper.PubSub, Terminal.topic(container))
      drain_pubsub()

      {:ok, conn} = connect(container, user_dir)
      chan = open_shell(conn)
      Process.sleep(300)
      drain_pubsub()

      # Send a single character — NOT followed by newline
      :ok = :ssh_connection.send(conn, chan, "x")

      # Should arrive at Terminal immediately
      output = collect_pubsub(1_500)
      assert output =~ "x", "Single char not received. SSH is line-buffering."

      :ssh.close(conn)
      stop_terminal(terminal_pid)
    end

    @tag timeout: 10_000
    test "SSH receives Terminal output without line buffering", %{user_dir: user_dir} do
      container = "ssh-recv-#{:rand.uniform(100_000)}"
      {:ok, terminal_pid} = start_terminal(container)

      {:ok, conn} = connect(container, user_dir)
      chan = open_shell(conn)
      Process.sleep(300)
      drain_ssh(conn, chan)

      marker = "RECV-#{:rand.uniform(1_000_000)}"
      GenServer.cast(terminal_pid, {:input, "echo #{marker}\n"})

      output = collect_ssh(conn, chan, 2_000)
      assert output =~ marker, "SSH didn't receive output. Got: #{inspect(output)}"

      :ssh.close(conn)
      stop_terminal(terminal_pid)
    end
  end

  describe "multiplayer" do
    @tag timeout: 10_000
    test "SSH and web see each other's input in real-time", %{user_dir: user_dir} do
      container = "ssh-mp-#{:rand.uniform(100_000)}"
      {:ok, terminal_pid} = start_terminal(container)

      # Web viewer (PubSub)
      Phoenix.PubSub.subscribe(BoomLooper.PubSub, Terminal.topic(container))
      drain_pubsub()

      # SSH viewer
      {:ok, conn} = connect(container, user_dir)
      chan = open_shell(conn)
      Process.sleep(300)
      drain_pubsub()
      drain_ssh(conn, chan)

      # SSH user types
      marker = "MP-#{:rand.uniform(1_000_000)}"
      :ok = :ssh_connection.send(conn, chan, "echo #{marker}\n")

      # Web viewer sees it
      web_output = collect_pubsub(2_000)
      assert web_output =~ marker, "Web didn't see SSH input. Got: #{inspect(web_output)}"

      # Web user types
      marker2 = "WEB-#{:rand.uniform(1_000_000)}"
      drain_ssh(conn, chan)
      GenServer.cast(terminal_pid, {:input, "echo #{marker2}\n"})

      # SSH sees it
      ssh_output = collect_ssh(conn, chan, 2_000)
      assert ssh_output =~ marker2, "SSH didn't see web input. Got: #{inspect(ssh_output)}"

      :ssh.close(conn)
      stop_terminal(terminal_pid)
    end

    @tag timeout: 10_000
    test "clear from web sends ANSI clear to SSH", %{user_dir: user_dir} do
      container = "ssh-clr-#{:rand.uniform(100_000)}"
      {:ok, terminal_pid} = start_terminal(container)

      {:ok, conn} = connect(container, user_dir)
      chan = open_shell(conn)
      Process.sleep(300)
      drain_ssh(conn, chan)

      Terminal.clear_buffer(container)

      output = collect_ssh(conn, chan, 1_000)
      assert output =~ "\e[2J", "SSH didn't receive clear. Got: #{inspect(output)}"

      :ssh.close(conn)
      stop_terminal(terminal_pid)
    end
  end

  # --- PubSub helpers ---

  defp drain_pubsub do
    receive do
      {:terminal_output, _} -> drain_pubsub()
      :terminal_clear -> drain_pubsub()
    after
      200 -> :ok
    end
  end

  defp collect_pubsub(timeout) do
    pubsub_loop("", timeout)
  end

  defp pubsub_loop(acc, remaining) when remaining <= 0, do: acc
  defp pubsub_loop(acc, remaining) do
    start = System.monotonic_time(:millisecond)
    receive do
      {:terminal_output, data} ->
        elapsed = System.monotonic_time(:millisecond) - start
        pubsub_loop(acc <> data, remaining - elapsed)
    after
      remaining -> acc
    end
  end

  # --- SSH helpers ---

  defp drain_ssh(conn, chan) do
    receive do
      {:ssh_cm, ^conn, {:data, ^chan, _, _}} -> drain_ssh(conn, chan)
    after
      200 -> :ok
    end
  end

  defp collect_ssh(conn, chan, timeout) do
    ssh_loop(conn, chan, "", timeout)
  end

  defp ssh_loop(_conn, _chan, acc, remaining) when remaining <= 0, do: acc
  defp ssh_loop(conn, chan, acc, remaining) do
    start = System.monotonic_time(:millisecond)
    receive do
      {:ssh_cm, ^conn, {:data, ^chan, _, data}} ->
        elapsed = System.monotonic_time(:millisecond) - start
        ssh_loop(conn, chan, acc <> to_string(data), remaining - elapsed)
    after
      remaining -> acc
    end
  end
end
