defmodule Loopyard.AgentSandboxTest do
  use ExUnit.Case, async: true

  alias Loopyard.AgentSandbox

  describe "container_name/2" do
    test "deterministic format" do
      assert AgentSandbox.container_name("ws-abc123", "agent-xyz") ==
               "loopyard-ws-abc123-agent-agent-xyz"
    end

    test "same inputs always produce same output" do
      a = AgentSandbox.container_name("w1", "a1")
      b = AgentSandbox.container_name("w1", "a1")
      assert a == b
    end

    test "different agents in same workspace get different names" do
      a = AgentSandbox.container_name("w1", "a1")
      b = AgentSandbox.container_name("w1", "a2")
      refute a == b
    end

    test "same agent_id in different workspaces gets different names" do
      a = AgentSandbox.container_name("w1", "a1")
      b = AgentSandbox.container_name("w2", "a1")
      refute a == b
    end
  end

  describe "image_name/0" do
    test "returns a pinned tag" do
      name = AgentSandbox.image_name()
      assert is_binary(name)
      assert name =~ ~r{^loopyard/agent-sandbox:\d+\.\d+\.\d+$}
    end
  end

  # Integration tests exercise actual Docker. Tagged :docker so they
  # only run in the CI docker-e2e job, not in default `mix test`.
  describe "ensure_running/3 + stop/2 (Docker integration)" do
    @describetag :docker

    setup do
      # Unique IDs per test so concurrent runs don't fight over the
      # same container name.
      workspace_id = "test-ws-#{:rand.uniform(1_000_000)}"
      agent_id = "test-agent-#{:rand.uniform(1_000_000)}"
      volume_name = "loopyard-sandbox-test-volume-#{:rand.uniform(1_000_000)}"

      # Create a throwaway volume to mount. Cleanup in on_exit.
      {:ok, _} = Loopyard.Docker.docker(["volume", "create", volume_name])

      on_exit(fn ->
        _ = AgentSandbox.stop(workspace_id, agent_id)
        _ = Loopyard.Docker.docker(["volume", "rm", "-f", volume_name])
      end)

      %{workspace_id: workspace_id, agent_id: agent_id, volume_name: volume_name}
    end

    test "starts a fresh container", %{
      workspace_id: ws,
      agent_id: aid,
      volume_name: vol
    } do
      assert :ok = AgentSandbox.ensure_running(ws, aid, vol)
      assert AgentSandbox.running?(ws, aid)
    end

    test "is idempotent — second call when already running is a no-op", %{
      workspace_id: ws,
      agent_id: aid,
      volume_name: vol
    } do
      :ok = AgentSandbox.ensure_running(ws, aid, vol)
      # Second call must not fail and must not create a duplicate
      assert :ok = AgentSandbox.ensure_running(ws, aid, vol)
      assert AgentSandbox.running?(ws, aid)
    end

    test "stop removes the container and is idempotent", %{
      workspace_id: ws,
      agent_id: aid,
      volume_name: vol
    } do
      :ok = AgentSandbox.ensure_running(ws, aid, vol)
      assert AgentSandbox.running?(ws, aid)

      assert :ok = AgentSandbox.stop(ws, aid)
      refute AgentSandbox.running?(ws, aid)

      # Calling stop again when there's nothing to stop is fine.
      assert :ok = AgentSandbox.stop(ws, aid)
    end

    test "container has the expected labels", %{
      workspace_id: ws,
      agent_id: aid,
      volume_name: vol
    } do
      :ok = AgentSandbox.ensure_running(ws, aid, vol)
      name = AgentSandbox.container_name(ws, aid)

      {:ok, output} =
        Loopyard.Docker.docker([
          "inspect",
          "-f",
          "{{index .Config.Labels \"loopyard.sandbox\"}}|{{index .Config.Labels \"loopyard.workspace_id\"}}|{{index .Config.Labels \"loopyard.agent_id\"}}",
          name
        ])

      assert String.trim(output) == "true|#{ws}|#{aid}"
    end

    test "container is on the 'none' network", %{
      workspace_id: ws,
      agent_id: aid,
      volume_name: vol
    } do
      :ok = AgentSandbox.ensure_running(ws, aid, vol)
      name = AgentSandbox.container_name(ws, aid)

      {:ok, output} =
        Loopyard.Docker.docker([
          "inspect",
          "-f",
          "{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}",
          name
        ])

      assert String.trim(output) == "none"
    end

    test "workspace volume is mounted at /workspace", %{
      workspace_id: ws,
      agent_id: aid,
      volume_name: vol
    } do
      :ok = AgentSandbox.ensure_running(ws, aid, vol)
      name = AgentSandbox.container_name(ws, aid)

      # Write a file from inside the container, then verify the
      # volume holds it.
      {:ok, _} = Loopyard.Docker.exec_in(name, "echo sandbox-write > /workspace/marker")

      {:ok, out} =
        Loopyard.Docker.docker([
          "run",
          "--rm",
          "-v",
          "#{vol}:/workspace",
          "alpine",
          "cat",
          "/workspace/marker"
        ])

      assert String.trim(out) == "sandbox-write"
    end
  end
end
