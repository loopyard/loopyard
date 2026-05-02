defmodule BoomLooper.TerminalTest do
  use ExUnit.Case

  alias BoomLooper.Terminal

  describe "topic/1" do
    test "returns PubSub topic for a container" do
      assert Terminal.topic("my-container") == "terminal_output:my-container"
    end
  end

  describe "build_cmd/1" do
    test "returns a two-element tuple {executable, args}" do
      {executable, args} = Terminal.build_cmd("test-container")
      assert is_binary(executable)
      assert is_list(args)
      assert File.exists?(executable)
    end

    test "uses docker exec -it for proper TTY in container" do
      {_executable, args} = Terminal.build_cmd("test-container")

      joined = Enum.join(args, " ")
      assert joined =~ "docker"
      assert joined =~ "exec"
      assert joined =~ "-it"
    end

    test "includes the container name in the command" do
      {_executable, args} = Terminal.build_cmd("my-fancy-container")

      joined = Enum.join(args, " ")
      assert joined =~ "my-fancy-container"
    end

    test "uses script executable on macOS/Linux" do
      {executable, _args} = Terminal.build_cmd("test-container")

      if System.find_executable("script") do
        assert executable == System.find_executable("script")
      else
        assert executable == System.find_executable("docker")
      end
    end

    test "macOS uses -q /dev/null form" do
      if :os.type() == {:unix, :darwin} && System.find_executable("script") do
        {_executable, args} = Terminal.build_cmd("test-container")
        assert "-q" in args
        assert "/dev/null" in args
      end
    end
  end

  describe "send_input/2 when not running" do
    test "returns error" do
      assert {:error, :not_running} =
               Terminal.send_input("nonexistent-container-#{:rand.uniform(100_000)}", "hello")
    end
  end

  describe "get_buffer/1 when not running" do
    test "returns empty string" do
      assert "" = Terminal.get_buffer("nonexistent-container-#{:rand.uniform(100_000)}")
    end
  end

  describe "get_or_start/1" do
    test "returns error for non-running container" do
      result = Terminal.get_or_start("nonexistent-container-#{:rand.uniform(100_000)}")
      assert {:error, _} = result
    end
  end

  describe "lifecycle with Docker" do
    @describetag :docker

    setup do
      # Start a minimal container to test against
      container = "boom-looper-terminal-test-#{:rand.uniform(100_000)}"

      {_, 0} =
        System.cmd("docker", ["run", "-d", "--name", container, "alpine:latest", "sleep", "300"],
          stderr_to_stdout: true
        )

      on_exit(fn ->
        System.cmd("docker", ["rm", "-f", container], stderr_to_stdout: true)
      end)

      %{container: container}
    end

    test "starts a session, receives output, and buffers it", %{container: container} do
      BoomLooper.Events.Terminal.subscribe(container)

      assert {:ok, pid} = Terminal.get_or_start(container)
      assert Process.alive?(pid)

      # Send a command
      Terminal.send_input(container, "echo hello-from-terminal\n")

      # Should receive output via PubSub
      assert_receive %BoomLooper.Events.Terminal.Output{data: data}, 3_000
      # May receive in chunks — collect output
      output = collect_output(data, 2_000)
      assert output =~ "hello-from-terminal"

      # Buffer should contain the output for late joiners
      buffer = Terminal.get_buffer(container)
      assert buffer =~ "hello-from-terminal"

      # Second call to get_or_start returns same pid
      assert {:ok, ^pid} = Terminal.get_or_start(container)

      # Clean up
      GenServer.stop(pid, :normal)
      Process.sleep(50)
    end

    test "broadcasts exit when container shell exits", %{container: container} do
      BoomLooper.Events.Terminal.subscribe(container)

      {:ok, pid} = Terminal.get_or_start(container)

      # Send exit command
      Terminal.send_input(container, "exit\n")

      # Should receive exit broadcast
      assert_receive %BoomLooper.Events.Terminal.Exit{code: _code}, 5_000
      Process.sleep(100)
      refute Process.alive?(pid)
    end
  end

  # Collect PubSub output messages for a duration
  defp collect_output(initial, timeout) do
    collect_output_loop(initial, timeout)
  end

  defp collect_output_loop(acc, timeout) do
    receive do
      %BoomLooper.Events.Terminal.Output{data: data} -> collect_output_loop(acc <> data, timeout)
    after
      timeout -> acc
    end
  end
end
