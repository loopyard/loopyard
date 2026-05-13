defmodule Loopyard.SSHServerTest do
  use ExUnit.Case, async: false
  @moduletag :ssh

  alias Loopyard.Terminal
  alias Loopyard.SSHServer.Channel

  setup_all do
    # SSHServer is started by the application with port 0 (auto-assigned).
    # Get the actual port it's listening on.
    ssh_port = Loopyard.SSHServer.port()

    unless ssh_port do
      raise "SSHServer not running — cannot run SSH tests"
    end

    user_dir = Path.join(System.tmp_dir!(), "loopyard-ssh-client-#{:rand.uniform(100_000)}")
    File.mkdir_p!(user_dir)
    File.chmod!(user_dir, 0o700)

    on_exit(fn -> File.rm_rf!(user_dir) end)

    %{user_dir: user_dir, ssh_port: ssh_port}
  end

  # --- Helpers ---

  defp connect(user, user_dir, ssh_port) do
    :ssh.connect(
      ~c"localhost",
      ssh_port,
      [
        user: String.to_charlist(user),
        user_dir: String.to_charlist(user_dir),
        silently_accept_hosts: true,
        user_interaction: false
      ],
      5_000
    )
  end

  defp open_shell(conn) do
    {:ok, chan} = :ssh_connection.session_channel(conn, 5_000)
    result = :ssh_connection.ptty_alloc(conn, chan, [])
    assert result in [:ok, :success]
    result = :ssh_connection.shell(conn, chan)
    assert result in [:ok, :success]
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
    {:ok, pid} =
      GenServer.start_link(Terminal, [container: container, cmd: local_shell_cmd()],
        name: {:via, Registry, {Loopyard.TerminalRegistry, container}}
      )

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

  defp drain_pubsub do
    receive do
      %Loopyard.Events.Terminal.Output{} -> drain_pubsub()
      %Loopyard.Events.Terminal.Clear{} -> drain_pubsub()
    after
      200 -> :ok
    end
  end

  defp collect_pubsub(timeout), do: pubsub_loop("", timeout)

  defp pubsub_loop(acc, remaining) when remaining <= 0, do: acc

  defp pubsub_loop(acc, remaining) do
    start = System.monotonic_time(:millisecond)

    receive do
      %Loopyard.Events.Terminal.Output{data: data} ->
        pubsub_loop(acc <> data, remaining - (System.monotonic_time(:millisecond) - start))
    after
      remaining -> acc
    end
  end

  defp drain_ssh(conn, chan) do
    receive do
      {:ssh_cm, ^conn, {:data, ^chan, _, _}} -> drain_ssh(conn, chan)
    after
      200 -> :ok
    end
  end

  defp collect_ssh(conn, chan, timeout), do: ssh_loop(conn, chan, "", timeout)

  defp ssh_loop(_conn, _chan, acc, remaining) when remaining <= 0, do: acc

  defp ssh_loop(conn, chan, acc, remaining) do
    start = System.monotonic_time(:millisecond)

    receive do
      {:ssh_cm, ^conn, {:data, ^chan, _, data}} ->
        ssh_loop(
          conn,
          chan,
          acc <> to_string(data),
          remaining - (System.monotonic_time(:millisecond) - start)
        )
    after
      remaining -> acc
    end
  end

  # --- Unit tests (no SSH connection needed) ---

  describe "Channel.clear_signal?/1" do
    test "detects Ctrl+L" do
      assert Channel.clear_signal?(<<12>>)
    end

    test "rejects regular characters" do
      refute Channel.clear_signal?("a")
      refute Channel.clear_signal?("ls\n")
      refute Channel.clear_signal?(<<13>>)
    end

    test "rejects multi-byte data containing Ctrl+L" do
      refute Channel.clear_signal?(<<12, 13>>)
    end
  end

  # --- Integration tests ---

  describe "connection" do
    test "connects with container name as username", %{user_dir: user_dir, ssh_port: ssh_port} do
      container = "ssh-conn-#{:rand.uniform(100_000)}"
      {:ok, terminal_pid} = start_terminal(container)

      {:ok, conn} = connect(container, user_dir, ssh_port)
      :ssh.close(conn)

      stop_terminal(terminal_pid)
    end
  end

  describe "raw byte I/O" do
    @tag timeout: 10_000
    test "SSH sends individual characters immediately (no line buffering)", %{
      user_dir: user_dir,
      ssh_port: ssh_port
    } do
      container = "ssh-raw-#{:rand.uniform(100_000)}"
      {:ok, terminal_pid} = start_terminal(container)

      Loopyard.Events.Terminal.subscribe(container)
      drain_pubsub()

      {:ok, conn} = connect(container, user_dir, ssh_port)
      chan = open_shell(conn)
      Process.sleep(300)
      drain_pubsub()

      :ok = :ssh_connection.send(conn, chan, "x")

      output = collect_pubsub(1_500)
      assert output =~ "x", "Single char not received. SSH is line-buffering."

      :ssh.close(conn)
      stop_terminal(terminal_pid)
    end

    @tag timeout: 10_000
    test "SSH receives Terminal output", %{user_dir: user_dir, ssh_port: ssh_port} do
      container = "ssh-recv-#{:rand.uniform(100_000)}"
      {:ok, terminal_pid} = start_terminal(container)

      {:ok, conn} = connect(container, user_dir, ssh_port)
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
    test "SSH and web see each other's input", %{user_dir: user_dir, ssh_port: ssh_port} do
      container = "ssh-mp-#{:rand.uniform(100_000)}"
      {:ok, terminal_pid} = start_terminal(container)

      Loopyard.Events.Terminal.subscribe(container)
      drain_pubsub()

      {:ok, conn} = connect(container, user_dir, ssh_port)
      chan = open_shell(conn)
      Process.sleep(300)
      drain_pubsub()
      drain_ssh(conn, chan)

      # SSH → web
      marker = "MP-#{:rand.uniform(1_000_000)}"
      :ok = :ssh_connection.send(conn, chan, "echo #{marker}\n")

      web_output = collect_pubsub(2_000)
      assert web_output =~ marker, "Web didn't see SSH input."

      # Web → SSH
      marker2 = "WEB-#{:rand.uniform(1_000_000)}"
      drain_ssh(conn, chan)
      GenServer.cast(terminal_pid, {:input, "echo #{marker2}\n"})

      ssh_output = collect_ssh(conn, chan, 2_000)
      assert ssh_output =~ marker2, "SSH didn't see web input."

      :ssh.close(conn)
      stop_terminal(terminal_pid)
    end

    @tag timeout: 10_000
    test "clear propagates from web to SSH", %{user_dir: user_dir, ssh_port: ssh_port} do
      container = "ssh-clr-#{:rand.uniform(100_000)}"
      {:ok, terminal_pid} = start_terminal(container)

      {:ok, conn} = connect(container, user_dir, ssh_port)
      chan = open_shell(conn)
      Process.sleep(300)
      drain_ssh(conn, chan)

      Terminal.clear_buffer(container)

      output = collect_ssh(conn, chan, 1_000)
      assert output =~ "\e[2J", "SSH didn't receive clear."

      :ssh.close(conn)
      stop_terminal(terminal_pid)
    end
  end
end
