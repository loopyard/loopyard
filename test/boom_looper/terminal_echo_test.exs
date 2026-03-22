defmodule BoomLooper.TerminalEchoTest do
  @moduledoc """
  Tests that the terminal produces clean output — no double-echo,
  no duplicate output, even with multiple subscribers.

  Uses a local shell (no Docker) to exercise the same script(1) + stty
  PTY path that Docker containers use.
  """
  use ExUnit.Case

  alias BoomLooper.Terminal

  # Build the same kind of command Terminal.build_cmd produces, but
  # targeting a local shell instead of docker exec.
  defp local_shell_cmd do
    script = System.find_executable("script")
    inner = "stty -echo 2>/dev/null; exec sh"

    case :os.type() do
      {:unix, :darwin} ->
        {script, ["-q", "/dev/null", "/bin/sh", "-c", inner]}
      _ ->
        {script, ["-qc", inner, "/dev/null"]}
    end
  end

  defp start_terminal(container) do
    {:ok, pid} = GenServer.start_link(Terminal, [container: container, cmd: local_shell_cmd()],
      name: {:via, Registry, {BoomLooper.TerminalRegistry, container}})
    # Wait for shell to be ready
    Process.sleep(400)
    {:ok, pid}
  end

  defp stop_terminal(pid) do
    if Process.alive?(pid) do
      GenServer.cast(pid, {:input, "exit\n"})
      ref = Process.monitor(pid)
      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        2_000 -> GenServer.stop(pid, :normal)
      end
    end
  end

  describe "single subscriber" do
    test "command output appears exactly once" do
      container = "single-#{:rand.uniform(100_000)}"
      topic = Terminal.topic(container)
      Phoenix.PubSub.subscribe(BoomLooper.PubSub, topic)

      {:ok, pid} = start_terminal(container)

      # Drain startup output (prompt, etc)
      drain()

      marker = "SINGLE-#{:rand.uniform(1_000_000)}"
      GenServer.cast(pid, {:input, "echo #{marker}\n"})

      output = collect(2_000)
      count = count_occurrences(output, marker)

      assert count == 1,
        "Expected marker once, got #{count}.\nOutput: #{inspect(output)}"

      stop_terminal(pid)
    end

    test "input is not echoed back (stty -echo works)" do
      container = "noecho-#{:rand.uniform(100_000)}"
      topic = Terminal.topic(container)
      Phoenix.PubSub.subscribe(BoomLooper.PubSub, topic)

      {:ok, pid} = start_terminal(container)
      drain()

      # Send a command where the input line is distinguishable from output
      GenServer.cast(pid, {:input, "echo HELLO\n"})

      output = collect(2_000)

      # "echo HELLO" (the input) should NOT appear — stty -echo suppresses it
      # "HELLO" (the output) should appear exactly once
      refute output =~ "echo HELLO",
        "Input was echoed back by PTY. stty -echo failed.\nOutput: #{inspect(output)}"
      assert output =~ "HELLO"

      stop_terminal(pid)
    end
  end

  describe "multiple subscribers (multiplayer)" do
    test "3 subscribers each see command output exactly once" do
      container = "multi-#{:rand.uniform(100_000)}"
      topic = Terminal.topic(container)

      {:ok, pid} = start_terminal(container)

      # 3 subscribers, each in their own process to simulate 3 browser tabs
      parent = self()

      subscribers = for i <- 1..3 do
        spawn_link(fn ->
          Phoenix.PubSub.subscribe(BoomLooper.PubSub, topic)
          send(parent, {:subscribed, i})

          # Wait for the "go" signal
          receive do
            :go -> :ok
          end

          output = collect(3_000)
          send(parent, {:result, i, output})
        end)
      end

      # Wait for all subscribers to be ready
      for i <- 1..3, do: assert_receive({:subscribed, ^i}, 1_000)

      # Tell subscribers to start collecting
      for sub <- subscribers, do: send(sub, :go)

      # Small delay to ensure collectors are in receive
      Process.sleep(100)

      # Send a command from "user 1"
      marker = "MULTI-#{:rand.uniform(1_000_000)}"
      GenServer.cast(pid, {:input, "echo #{marker}\n"})

      # Each subscriber should see the marker exactly once
      for i <- 1..3 do
        assert_receive {:result, ^i, output}, 5_000

        count = count_occurrences(output, marker)
        assert count == 1,
          "Subscriber #{i} saw marker #{count} times (expected 1).\nOutput: #{inspect(output)}"
      end

      stop_terminal(pid)
    end

    test "3 subscribers each send a command, each command output appears once" do
      container = "3writers-#{:rand.uniform(100_000)}"
      topic = Terminal.topic(container)

      {:ok, pid} = start_terminal(container)

      # Subscribe in the test process to see ALL output
      Phoenix.PubSub.subscribe(BoomLooper.PubSub, topic)
      drain()

      markers = for i <- 1..3 do
        m = "CMD#{i}-#{:rand.uniform(1_000_000)}"
        GenServer.cast(pid, {:input, "echo #{m}\n"})
        Process.sleep(300)
        m
      end

      output = collect(3_000)

      for {marker, i} <- Enum.with_index(markers, 1) do
        count = count_occurrences(output, marker)
        assert count == 1,
          "Command #{i} marker appeared #{count} times (expected 1).\nOutput: #{inspect(output)}"
      end

      stop_terminal(pid)
    end
  end

  describe "buffer for late joiners" do
    test "buffer contains output, late subscriber gets it without doubling" do
      container = "buffer-#{:rand.uniform(100_000)}"
      topic = Terminal.topic(container)

      {:ok, pid} = start_terminal(container)

      # Send a command BEFORE subscribing (simulates late joiner)
      marker = "EARLY-#{:rand.uniform(1_000_000)}"
      GenServer.cast(pid, {:input, "echo #{marker}\n"})
      Process.sleep(500)

      # Now subscribe (late joiner)
      Phoenix.PubSub.subscribe(BoomLooper.PubSub, topic)

      # The buffer should have the marker
      buffer = Terminal.get_buffer(container)
      assert buffer =~ marker, "Buffer missing marker"

      # Send another command
      marker2 = "LATE-#{:rand.uniform(1_000_000)}"
      GenServer.cast(pid, {:input, "echo #{marker2}\n"})

      output = collect(2_000)

      # Live output should have marker2 once
      assert count_occurrences(output, marker2) == 1,
        "Late command marker doubled.\nOutput: #{inspect(output)}"

      # The buffer should NOT be re-delivered via PubSub
      # (PubSub only delivers new messages after subscribe)
      refute output =~ marker,
        "Buffer was re-delivered via PubSub — would cause doubling for late joiners"

      stop_terminal(pid)
    end
  end

  # --- Helpers ---

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

  defp collect_loop(acc, timeout) do
    receive do
      {:terminal_output, data} -> collect_loop(acc <> data, timeout)
    after
      timeout -> acc
    end
  end

  defp count_occurrences(string, pattern) do
    length(String.split(string, pattern)) - 1
  end
end
