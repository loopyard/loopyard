defmodule Loopyard.Tools.Container.DaemonGateTest do
  @moduledoc """
  The two tools that own their own `Port.open` (exec, compose streaming)
  bypass `Docker.docker/2`'s daemon gate, so they must honour it themselves —
  docs/CODE_RULES.md → "Every Docker shell-out honours the daemon gate". The
  default suite runs with the daemon disabled: a gated tool answers with a
  readable error and never spawns `docker`.
  """
  use ExUnit.Case, async: true

  alias Loopyard.Tools.Container.{DockerCompose, Exec, Helpers}

  test "the shared gate reports the daemon as unavailable in this env" do
    refute Loopyard.Docker.daemon_available?()
    assert {:error, msg} = Helpers.require_docker_daemon()
    assert msg =~ "Docker is not available"
  end

  # `exec` gates right before its Port.open, AFTER container resolution (so a
  # workspace-less agent keeps its "no workspace" answer — container_test.exs).
  # In this daemon-less env resolution itself fails first, so the gate can't
  # be reached through `execute/2` here; the helper test above covers it.
  test "exec keeps its pre-gate error precedence" do
    assert {:error, msg} = Exec.execute(%{agent_id: "no-such-agent", command: "true"}, %{})
    assert msg =~ "no workspace"
  end

  test "docker_compose refuses `up` before the host sync or the stream Port" do
    assert {:error, msg} =
             DockerCompose.execute(%{agent_id: "no-such-agent", command: "up -d"}, %{})

    assert msg =~ "Docker is not available"
  end
end
