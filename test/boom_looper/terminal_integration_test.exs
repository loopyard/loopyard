defmodule BoomLooper.TerminalIntegrationTest do
  @moduledoc """
  Full-stack terminal test: websocket → channel → Terminal GenServer →
  Port → PTY → output → PubSub → channel → websocket push.

  Uses a local shell (no Docker). Tests the same code path the browser
  uses, just without Docker in the loop.
  """
  use BoomLooperWeb.ChannelCase

  alias BoomLooper.Terminal
  alias BoomLooperWeb.TerminalChannel

  defp local_shell_cmd do
    script = System.find_executable("script")
    case :os.type() do
      {:unix, :darwin} ->
        {script, ["-q", "/dev/null", "/bin/sh"]}
      _ ->
        {script, ["-qc", "/bin/sh", "/dev/null"]}
    end
  end

  defp start_terminal_with_local_shell(container) do
    {:ok, pid} = GenServer.start_link(Terminal, [container: container, cmd: local_shell_cmd()],
      name: {:via, Registry, {BoomLooper.TerminalRegistry, container}})
    Process.sleep(500)
    {:ok, pid}
  end

  defp cleanup_terminal(container) do
    case Registry.lookup(BoomLooper.TerminalRegistry, container) do
      [{pid, _}] ->
        GenServer.cast(pid, {:input, "exit\n"})
        ref = Process.monitor(pid)
        receive do
          {:DOWN, ^ref, _, _, _} -> :ok
        after
          2_000 -> GenServer.stop(pid, :normal)
        end
      [] -> :ok
    end
  end

  # Collect all "output" pushes from the channel, concatenate the data
  defp collect_channel_output(timeout) do
    collect_loop("", timeout)
  end

  defp collect_loop(acc, remaining) when remaining <= 0, do: acc
  defp collect_loop(acc, remaining) do
    start = System.monotonic_time(:millisecond)
    receive do
      %Phoenix.Socket.Message{event: "output", payload: %{"data" => data}} ->
        elapsed = System.monotonic_time(:millisecond) - start
        collect_loop(acc <> data, remaining - elapsed)
      # Also handle atom-key payloads
      %Phoenix.Socket.Message{event: "output", payload: %{data: data}} ->
        elapsed = System.monotonic_time(:millisecond) - start
        collect_loop(acc <> data, remaining - elapsed)
    after
      remaining -> acc
    end
  end

  defp drain_channel_output do
    receive do
      %Phoenix.Socket.Message{event: "output", payload: _} -> drain_channel_output()
    after
      300 -> :ok
    end
  end

  defp count(string, pattern) do
    length(String.split(string, pattern)) - 1
  end

  defp viewer_collect(timeout) do
    viewer_loop("", timeout)
  end

  defp viewer_loop(acc, remaining) when remaining <= 0, do: acc
  defp viewer_loop(acc, remaining) do
    start = System.monotonic_time(:millisecond)
    receive do
      {:terminal_output, data} ->
        elapsed = System.monotonic_time(:millisecond) - start
        viewer_loop(acc <> data, remaining - elapsed)
    after
      remaining -> acc
    end
  end

  describe "full websocket stack" do
    setup do
      container = "integration-#{:rand.uniform(100_000)}"
      {:ok, _pid} = start_terminal_with_local_shell(container)
      on_exit(fn -> cleanup_terminal(container) end)
      %{container: container}
    end

    test "channel join succeeds and delivers prompt", %{container: container} do
      {:ok, _, _socket} =
        socket(BoomLooperWeb.UserSocket, "user", %{})
        |> subscribe_and_join(TerminalChannel, "terminal:#{container}")

      # Should receive at least the shell prompt via channel push
      output = collect_channel_output(1_000)
      assert output != "", "No output received after channel join"
    end

    test "sending input via channel produces output exactly once", %{container: container} do
      {:ok, _, socket} =
        socket(BoomLooperWeb.UserSocket, "user", %{})
        |> subscribe_and_join(TerminalChannel, "terminal:#{container}")

      drain_channel_output()

      marker = "INTEG-#{:rand.uniform(1_000_000)}"
      push(socket, "input", %{"data" => "echo #{marker}\n"})

      output = collect_channel_output(2_000)

      # Marker can appear at most twice: input echo + command output
      # If it appears 3+ times, something in the channel stack is doubling
      c = count(output, marker)
      assert c <= 2,
        "Marker appeared #{c} times via channel (max 2 expected). " <>
        "The channel/websocket stack is duplicating output.\n" <>
        "Output: #{inspect(output)}"

      assert c >= 1,
        "Marker not found in channel output at all.\nOutput: #{inspect(output)}"
    end

    test "multiple viewers via PubSub each see output once", %{container: container} do
      # Test multiplayer via PubSub directly (not ChannelCase, which
      # conflates the test process's channel topic subscription).
      # This simulates what happens in production: each channel process
      # subscribes to the terminal_output topic independently.
      parent = self()

      viewers = for i <- 1..3 do
        spawn_link(fn ->
          Phoenix.PubSub.subscribe(BoomLooper.PubSub, Terminal.topic(container))
          send(parent, {:ready, i})
          receive do: (:go -> :ok)

          output = viewer_collect(3_000)
          send(parent, {:output, i, output})
        end)
      end

      for i <- 1..3, do: assert_receive({:ready, ^i}, 1_000)
      for v <- viewers, do: send(v, :go)
      Process.sleep(100)

      marker = "MULTI-#{:rand.uniform(1_000_000)}"
      terminal_pid = elem(hd(Registry.lookup(BoomLooper.TerminalRegistry, container)), 0)
      GenServer.cast(terminal_pid, {:input, "echo #{marker}\n"})

      for i <- 1..3 do
        assert_receive {:output, ^i, output}, 5_000
        c = count(output, marker)
        assert c <= 2,
          "Viewer #{i} saw marker #{c} times (max 2).\nOutput: #{inspect(output)}"
      end
    end

    test "buffer replay + live output does not duplicate", %{container: container} do
      # Send a command BEFORE any channel joins — goes into buffer
      early_marker = "EARLY-#{:rand.uniform(1_000_000)}"
      GenServer.cast(
        elem(hd(Registry.lookup(BoomLooper.TerminalRegistry, container)), 0),
        {:input, "echo #{early_marker}\n"}
      )
      Process.sleep(500)

      # Now join — should get buffer + start receiving live
      {:ok, _, socket} =
        socket(BoomLooperWeb.UserSocket, "user", %{})
        |> subscribe_and_join(TerminalChannel, "terminal:#{container}")

      # Collect everything (buffer + any live output)
      initial = collect_channel_output(1_000)

      early_count = count(initial, early_marker)
      assert early_count <= 2,
        "Early marker appeared #{early_count} times in initial output (max 2). " <>
        "Buffer replay is overlapping with live.\nOutput: #{inspect(initial)}"

      # Now send a new command
      late_marker = "LATE-#{:rand.uniform(1_000_000)}"
      push(socket, "input", %{"data" => "echo #{late_marker}\n"})

      live = collect_channel_output(2_000)

      late_count = count(live, late_marker)
      assert late_count <= 2,
        "Late marker appeared #{late_count} times (max 2). " <>
        "Output: #{inspect(live)}"

      leave(socket)
    end
  end
end
