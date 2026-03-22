defmodule BoomLooper.TerminalEchoTest do
  @moduledoc """
  Integration test that verifies terminal sessions don't produce
  double-echo or duplicate output.

  Requires Docker — tagged :docker.
  """
  use ExUnit.Case

  alias BoomLooper.Terminal

  @describetag :docker

  setup do
    container = "boom-looper-echo-test-#{:rand.uniform(100_000)}"

    {_, 0} = System.cmd("docker", ["run", "-d", "--name", container, "alpine:latest", "sleep", "300"],
      stderr_to_stdout: true)

    on_exit(fn ->
      case Registry.lookup(BoomLooper.TerminalRegistry, container) do
        [{pid, _}] ->
          GenServer.stop(pid, :normal)
          Process.sleep(50)
        [] -> :ok
      end
      System.cmd("docker", ["rm", "-f", container], stderr_to_stdout: true)
    end)

    %{container: container}
  end

  test "command output appears exactly once", %{container: container} do
    Phoenix.PubSub.subscribe(BoomLooper.PubSub, Terminal.topic(container))

    {:ok, _pid} = Terminal.get_or_start(container)

    # Wait for shell to be ready
    Process.sleep(500)

    # Use a unique marker so we can count occurrences precisely
    marker = "MARKER-#{:rand.uniform(1_000_000)}"
    Terminal.send_input(container, "echo #{marker}\n")

    # Collect all output for a few seconds
    output = collect_all_output(3_000)

    # The marker should appear exactly once in the output (the echo command's result).
    # If double-echo exists, it will appear 2+ times.
    occurrences = count_occurrences(output, marker)

    assert occurrences == 1,
      "Expected marker to appear exactly once, but found #{occurrences} times.\n" <>
      "Full output:\n---\n#{output}\n---\n" <>
      "This indicates double-echo in the terminal session."
  end

  test "typed input is not echoed back by the PTY", %{container: container} do
    Phoenix.PubSub.subscribe(BoomLooper.PubSub, Terminal.topic(container))

    {:ok, _pid} = Terminal.get_or_start(container)
    Process.sleep(500)

    # Send a command that produces known output
    Terminal.send_input(container, "echo TESTOUTPUT\n")

    output = collect_all_output(3_000)

    # We should see "TESTOUTPUT" (from echo command) but the input
    # "echo TESTOUTPUT" should NOT be echoed back as a separate line
    # by the local PTY. The shell inside docker may echo it (that's
    # expected for interactive shells), but we should not see it doubled.
    lines = String.split(output, "\n", trim: true)
    echo_lines = Enum.filter(lines, &String.contains?(&1, "echo TESTOUTPUT"))

    # At most 1 echo of the command (from the remote shell's prompt echo)
    # 0 is fine too (if the shell is non-interactive)
    assert length(echo_lines) <= 1,
      "Input 'echo TESTOUTPUT' was echoed #{length(echo_lines)} times (expected 0 or 1).\n" <>
      "Lines containing input: #{inspect(echo_lines)}\n" <>
      "Full output:\n---\n#{output}\n---"
  end

  test "sequential commands produce correct output order", %{container: container} do
    Phoenix.PubSub.subscribe(BoomLooper.PubSub, Terminal.topic(container))

    {:ok, _pid} = Terminal.get_or_start(container)
    Process.sleep(500)

    Terminal.send_input(container, "echo FIRST\n")
    Process.sleep(500)
    Terminal.send_input(container, "echo SECOND\n")

    output = collect_all_output(3_000)

    first_pos = find_position(output, "FIRST")
    second_pos = find_position(output, "SECOND")

    assert first_pos != nil, "FIRST not found in output"
    assert second_pos != nil, "SECOND not found in output"
    assert first_pos < second_pos, "FIRST should appear before SECOND"
  end

  # --- Helpers ---

  defp collect_all_output(timeout) do
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
    string
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end

  defp find_position(string, pattern) do
    case :binary.match(string, pattern) do
      {pos, _} -> pos
      :nomatch -> nil
    end
  end
end
