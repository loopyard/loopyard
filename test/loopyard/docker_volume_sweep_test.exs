defmodule Loopyard.Test.DockerVolumeSweepTest do
  use ExUnit.Case, async: true

  alias Loopyard.Test.DockerVolumeSweep

  test "only test-prefixed volumes that appeared during the run are the run's own" do
    before = MapSet.new(["loopyard-test-old-code"])

    now = [
      "loopyard-test-old-code",
      "loopyard-test-new1-code",
      "loopyard-3e57c067-code",
      "gbrain-gbrain-machine-1"
    ]

    assert DockerVolumeSweep.created_since(before, now) == MapSet.new(["loopyard-test-new1-code"])
  end

  test "the default run (daemon gate closed) never lists or sweeps" do
    assert DockerVolumeSweep.snapshot() == nil
    assert DockerVolumeSweep.sweep(nil) == 0
  end
end
