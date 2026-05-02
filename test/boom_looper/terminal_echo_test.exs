defmodule BoomLooper.TerminalEchoTest do
  @moduledoc """
  Tests that the terminal produces clean output — no double-echo,
  no duplicate output, even with multiple subscribers.

  Uses a local shell (no Docker) to exercise the same script(1) + stty
  PTY path that Docker containers use.
  """
  use ExUnit.Case
  @moduletag :terminal

  alias BoomLooper.Terminal

  # Build the same kind of command Terminal.build_cmd produces, but
  # targeting a local shell instead of docker exec.
  # script provides a PTY, sh runs interactively with echo.
  defp local_shell_cmd do
    script = System.find_executable("script")

    case :os.type() do
      {:unix, :darwin} ->
        {script, ["-q", "/dev/null", "/bin/sh"]}

      _ ->
        {script, ["-qc", "/bin/sh", "/dev/null"]}
    end
  end

  defp start_terminal(container) do
    {:ok, pid} =
      GenServer.start_link(Terminal, [container: container, cmd: local_shell_cmd()],
        name: {:via, Registry, {BoomLooper.TerminalRegistry, container}}
      )

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
    test "command output is not duplicated" do
      container = "single-#{:rand.uniform(100_000)}"
      topic = Terminal.topic(container)
      BoomLooper.Events.Terminal.subscribe(container)

      {:ok, pid} = start_terminal(container)
      drain()

      # Use a marker that's distinct from the echo command itself
      # to isolate command OUTPUT from input echo
      marker = "SINGLE-#{:rand.uniform(1_000_000)}"
      GenServer.cast(pid, {:input, "echo #{marker}\n"})

      output = collect(2_000)

      # With PTY echo, the marker appears in:
      # 1. Input echo: "echo SINGLE-123\n" (contains marker)
      # 2. Command output: "SINGLE-123\n" (contains marker)
      # Total: exactly 2. If we see 3+, something is duplicating.
      count = count_occurrences(output, marker)

      assert count == 2,
             "Expected marker twice (input echo + output), got #{count}.\nOutput: #{inspect(output)}"

      stop_terminal(pid)
    end

    test "shell prompt is visible (PTY echo works)" do
      container = "prompt-#{:rand.uniform(100_000)}"
      topic = Terminal.topic(container)
      BoomLooper.Events.Terminal.subscribe(container)

      {:ok, pid} = start_terminal(container)

      # Collect initial output — should contain a shell prompt
      output = collect(1_000)

      assert output =~ "$" || output =~ "#" || output =~ ">",
             "No shell prompt visible. User can't see what they're typing.\nOutput: #{inspect(output)}"

      stop_terminal(pid)
    end
  end

  describe "multiple subscribers (multiplayer)" do
    test "3 subscribers each see command output without extra duplication" do
      container = "multi-#{:rand.uniform(100_000)}"
      topic = Terminal.topic(container)

      {:ok, pid} = start_terminal(container)

      # 3 subscribers, each in their own process to simulate 3 browser tabs
      parent = self()

      subscribers =
        for i <- 1..3 do
          spawn_link(fn ->
            BoomLooper.Events.Terminal.subscribe(container)
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

        assert count == 2,
               "Subscriber #{i} saw marker #{count} times (expected 2: input echo + output).\nOutput: #{inspect(output)}"
      end

      stop_terminal(pid)
    end

    test "3 subscribers each send a command, no extra duplication" do
      container = "3writers-#{:rand.uniform(100_000)}"
      topic = Terminal.topic(container)

      {:ok, pid} = start_terminal(container)

      # Subscribe in the test process to see ALL output
      BoomLooper.Events.Terminal.subscribe(container)
      drain()

      markers =
        for i <- 1..3 do
          m = "CMD#{i}-#{:rand.uniform(1_000_000)}"
          GenServer.cast(pid, {:input, "echo #{m}\n"})
          Process.sleep(300)
          m
        end

      output = collect(3_000)

      for {marker, i} <- Enum.with_index(markers, 1) do
        count = count_occurrences(output, marker)

        assert count == 2,
               "Command #{i} marker appeared #{count} times (expected 2: input echo + output).\nOutput: #{inspect(output)}"
      end

      stop_terminal(pid)
    end
  end

  describe "clear (multiplayer)" do
    test "clear_buffer empties buffer and broadcasts to all subscribers" do
      container = "clear-#{:rand.uniform(100_000)}"
      topic = Terminal.topic(container)

      {:ok, pid} = start_terminal(container)
      drain()

      # Send a command to fill the buffer
      GenServer.cast(pid, {:input, "echo BEFORE_CLEAR\n"})
      Process.sleep(500)

      assert Terminal.get_buffer(container) =~ "BEFORE_CLEAR"

      # Subscribe 2 viewers
      BoomLooper.Events.Terminal.subscribe(container)

      parent = self()

      viewer2 =
        spawn_link(fn ->
          BoomLooper.Events.Terminal.subscribe(container)
          send(parent, :viewer2_ready)

          receive do
            %BoomLooper.Events.Terminal.Clear{} -> send(parent, :viewer2_cleared)
          after
            3_000 -> send(parent, :viewer2_timeout)
          end
        end)

      assert_receive :viewer2_ready, 1_000

      # Clear
      Terminal.clear_buffer(container)

      # Both viewers should receive the clear broadcast
      assert_receive %BoomLooper.Events.Terminal.Clear{}, 1_000
      assert_receive :viewer2_cleared, 1_000

      # Buffer should be empty
      assert Terminal.get_buffer(container) == ""

      # New output after clear should work normally
      GenServer.cast(pid, {:input, "echo AFTER_CLEAR\n"})
      output = collect(2_000)
      assert output =~ "AFTER_CLEAR"

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
      BoomLooper.Events.Terminal.subscribe(container)

      # The buffer should have the marker
      buffer = Terminal.get_buffer(container)
      assert buffer =~ marker, "Buffer missing marker"

      # Send another command
      marker2 = "LATE-#{:rand.uniform(1_000_000)}"
      GenServer.cast(pid, {:input, "echo #{marker2}\n"})

      output = collect(2_000)

      # Live output should have marker2 twice (input echo + output), not more
      assert count_occurrences(output, marker2) == 2,
             "Late command marker appeared #{count_occurrences(output, marker2)} times (expected 2).\nOutput: #{inspect(output)}"

      # The early marker should NOT appear in live PubSub output
      # (PubSub only delivers new messages after subscribe)
      assert count_occurrences(output, marker) == 0,
             "Buffer was re-delivered via PubSub — would cause doubling for late joiners"

      stop_terminal(pid)
    end
  end

  # --- Helpers ---

  defp drain do
    receive do
      %BoomLooper.Events.Terminal.Output{} -> drain()
    after
      200 -> :ok
    end
  end

  defp collect(timeout) do
    collect_loop("", timeout)
  end

  defp collect_loop(acc, timeout) do
    receive do
      %BoomLooper.Events.Terminal.Output{data: data} -> collect_loop(acc <> data, timeout)
    after
      timeout -> acc
    end
  end

  defp count_occurrences(string, pattern) do
    length(String.split(string, pattern)) - 1
  end
end
