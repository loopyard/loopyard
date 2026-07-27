defmodule Loopyard.DockerDaemonTest do
  # async: false — drives the ONE named keeper GenServer via injected fns.
  use ExUnit.Case, async: false

  alias Loopyard.DockerDaemon

  setup do
    on_exit(fn ->
      Application.delete_env(:loopyard, :docker_probe_fun)
      Application.delete_env(:loopyard, :docker_heal_fun)
      :persistent_term.put({DockerDaemon, :up}, true)
    end)

    :ok
  end

  defp tick, do: send(Process.whereis(DockerDaemon), :probe)

  test "two failed probes declare DOWN, fire the heal, and recovery is silent" do
    test = self()
    Application.put_env(:loopyard, :docker_probe_fun, fn -> :error end)
    Application.put_env(:loopyard, :docker_heal_fun, fn -> send(test, :healed) end)

    tick()
    # One strike: still optimistic.
    _ = :sys.get_state(DockerDaemon)
    assert DockerDaemon.up?()

    tick()
    _ = :sys.get_state(DockerDaemon)
    refute DockerDaemon.up?()
    assert_receive :healed, 1_000

    # Probe comes back → up flips silently; heal budget resets.
    Application.put_env(:loopyard, :docker_probe_fun, fn -> :ok end)
    tick()
    state = :sys.get_state(DockerDaemon)
    assert DockerDaemon.up?()
    assert state.heal_attempts == 0
  end

  test "heal budget is bounded — then one decisive announcement, no hot loop" do
    test = self()
    Application.put_env(:loopyard, :docker_probe_fun, fn -> :error end)
    Application.put_env(:loopyard, :docker_heal_fun, fn -> send(test, :healed) end)

    # strike, declare(+heal 1), heal 2, give up, then nothing new.
    for _ <- 1..6, do: tick()
    state = :sys.get_state(DockerDaemon)

    assert state.heal_attempts == 2
    assert state.announced
    assert_receive :healed, 1_000
    assert_receive :healed, 1_000
    refute_receive :healed, 200

    # Recovery resets the announcement latch for the NEXT outage.
    Application.put_env(:loopyard, :docker_probe_fun, fn -> :ok end)
    tick()
    refute :sys.get_state(DockerDaemon).announced
  end
end
