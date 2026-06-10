defmodule Loopyard.Workspace.WorkContainerTest do
  @moduledoc """
  Smoke test for the cheap, Loopyard-owned work container (north-star D10:
  "working is the default state"). Proves an agent has a code-mounted place to
  act WITHOUT booting the project's compose/preview cluster.

      mix test --include docker test/loopyard/workspace/work_container_test.exs
  """
  use ExUnit.Case, async: false
  @moduletag :docker
  @moduletag timeout: 600_000

  alias Loopyard.{Workspace.WorkContainer, VolumeManager, VolumeIO, Docker}

  test "ensure_up boots a code-mounted container; exec sees the volume; down removes it" do
    ws = "wc-#{uid()}"
    volume = VolumeManager.code_volume_name(ws)

    on_exit(fn ->
      WorkContainer.down(ws)
      VolumeManager.delete_volume(volume)
    end)

    # Seed a file into the code volume the way onboarding/git would.
    :ok = VolumeManager.create_volume(volume)
    :ok = VolumeIO.write_file(volume, "hello.txt", "from the volume\n")

    # Working is cheap: no compose, no project image — just the work container.
    assert {:ok, name} = WorkContainer.ensure_up(ws)
    assert name == "loopyard-#{ws}-work"
    assert WorkContainer.running?(ws)

    # The agent's eye view: it execs here and sees the branch's code at /workspace.
    assert {:ok, out} = WorkContainer.exec(ws, "cat /workspace/hello.txt")
    assert out =~ "from the volume"

    # And it can write back — the volume is the source of truth.
    assert {:ok, _} = WorkContainer.exec(ws, "echo agent-wrote > /workspace/agent.txt")
    assert {:ok, back} = VolumeIO.read_file(volume, "agent.txt")
    assert back =~ "agent-wrote"

    # Idempotent: a second ensure_up is a no-op on the same container.
    assert {:ok, ^name} = WorkContainer.ensure_up(ws)

    # Disposable: down removes the container, the volume survives.
    :ok = WorkContainer.down(ws)
    refute WorkContainer.running?(ws)
    assert {:ok, still} = VolumeIO.read_file(volume, "agent.txt")
    assert still =~ "agent-wrote"
  end

  test "ensure_up restarts a stopped work container rather than orphaning it" do
    ws = "wc-#{uid()}"
    volume = VolumeManager.code_volume_name(ws)

    on_exit(fn ->
      WorkContainer.down(ws)
      VolumeManager.delete_volume(volume)
    end)

    assert {:ok, name} = WorkContainer.ensure_up(ws)
    assert {:ok, _} = Docker.docker(["stop", name])
    refute WorkContainer.running?(ws)

    # Stopped-but-present → ensure_up starts it back up (same container).
    assert {:ok, ^name} = WorkContainer.ensure_up(ws)
    assert WorkContainer.running?(ws)
  end

  defp uid, do: :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
end
