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
    assert name == "#{Loopyard.Docker.prefix()}#{ws}-work"
    assert WorkContainer.running?(ws)

    # Hardened against host escape (#74): no-new-privileges blocks setuid
    # escalation and the dangerous caps are dropped, so a breakout is defanged.
    assert {:ok, secopt} =
             Docker.docker(["inspect", "--format", "{{.HostConfig.SecurityOpt}}", name])

    assert secopt =~ "no-new-privileges"

    assert {:ok, capdrop} =
             Docker.docker(["inspect", "--format", "{{.HostConfig.CapDrop}}", name])

    assert capdrop =~ "SYS_ADMIN"

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

  test "the work container is a harness host: the REAL Claude harness handshakes over ACP" do
    # The north star — the box hosts a real harness, it doesn't reimplement one.
    # We prove the cheap, code-mounted work container can run the actual Claude
    # Code harness (via the claude-code-acp adapter baked into the base image)
    # and complete an ACP `initialize` handshake. Only a full prompt needs auth
    # (the parked piece); the handshake is pre-auth and proves the seam.
    ws = "acp-#{uid()}"
    volume = VolumeManager.code_volume_name(ws)

    on_exit(fn ->
      WorkContainer.down(ws)
      VolumeManager.delete_volume(volume)
    end)

    assert {:ok, name} = WorkContainer.ensure_up(ws)

    # The harness toolchain is present in the box.
    assert {:ok, tools} = Docker.exec_in(name, "node --version && which claude-agent-acp")
    assert tools =~ "claude-agent-acp"

    # Boot the REAL harness inside the container and speak ACP to it. The adapter
    # is a stdio JSON-RPC server; we pipe one `initialize` request and read the
    # response, then EOF. `Loopyard.Docker` has no stdin channel, so a test-only
    # shell pipeline drives `docker exec -i`.
    req =
      ~s({"jsonrpc":"2.0","id":0,"method":"initialize",) <>
        ~s("params":{"protocolVersion":1,"clientCapabilities":) <>
        ~s({"fs":{"readTextFile":true,"writeTextFile":true}}}})

    # `timeout` runs INSIDE the container (Debian coreutils) — macOS hosts
    # don't ship a `timeout` binary, so a host-side one breaks on darwin.
    cmd =
      "printf '%s\\n' '#{req}' | docker exec -i #{name} " <>
        "sh -c 'unset CLAUDECODE; timeout 25 claude-agent-acp'"

    {resp, _status} = System.cmd("sh", ["-c", cmd], stderr_to_stdout: true)

    # A valid ACP initialize result from the real Claude harness (the adapter
    # identifies as agentInfo.name "@agentclientprotocol/claude-agent-acp").
    assert resp =~ ~s("protocolVersion":1)
    assert resp =~ "claude-agent-acp"
    assert resp =~ "authMethods"
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
