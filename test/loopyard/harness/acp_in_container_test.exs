defmodule Loopyard.Harness.ACPInContainerTest do
  @moduledoc """
  The convergence test: Loopyard's `Backend.ACP` (the Elixir side) drives the
  REAL Claude harness running *inside* the cheap `WorkContainer`, over ACP via
  `docker exec -i`. This is the north star realized end to end up to the auth
  boundary — the box hosts a real harness and Loopyard speaks to it through the
  same `Agent.Backend` behaviour the whole multiplayer stack already renders.

  Handshake (`initialize`) and session creation (`session/new`) succeed
  pre-auth; a full prompt additionally needs an in-container inference
  credential (the parked piece — #3/#12), so this test stops at "session is
  live", which is exactly the seam that proves the wiring.

      mix test --include docker test/loopyard/agent/backend/acp_in_container_test.exs
  """
  use ExUnit.Case, async: false
  @moduletag :docker
  @moduletag timeout: 600_000

  alias Loopyard.Harness.ACP
  alias Loopyard.Workspace.WorkContainer
  alias Loopyard.{VolumeManager, VolumeIO}

  test "Backend.ACP handshakes the real harness inside the work container" do
    ws = "acpbe-#{uid()}"
    volume = VolumeManager.code_volume_name(ws)

    on_exit(fn ->
      WorkContainer.down(ws)
      VolumeManager.delete_volume(volume)
    end)

    # A code-mounted box with some code in it (the harness's cwd is /workspace).
    :ok = VolumeManager.create_volume(volume)
    :ok = VolumeIO.write_file(volume, "README.md", "# hello from the volume\n")
    {:ok, container} = WorkContainer.ensure_up(ws)

    # Loopyard's Elixir backend launches the real adapter via `docker exec -i`
    # and completes the ACP handshake + session creation inside the container.
    assert {:ok, conn} =
             ACP.start_session(
               container: container,
               cwd: "/workspace",
               adapter: "claude-agent-acp"
             )

    assert ACP.session_alive?(conn)

    # session/new returned an id — the harness is live and ready for a turn
    # (the turn itself is what needs in-container auth).
    assert is_binary(ACP.session_id(conn))

    :ok = ACP.stop(conn)
    refute ACP.session_alive?(conn)
  end

  defp uid, do: :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
end
