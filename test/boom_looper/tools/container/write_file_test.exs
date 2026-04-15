defmodule BoomLooper.Tools.Container.WriteFileTest do
  use ExUnit.Case, async: false

  alias BoomLooper.Tools.Container.WriteFile

  @agent_id "write-file-tool-test-agent"
  @workspace_id "ws-write-file-test"

  setup do
    :ets.insert(:chat_agents, {@agent_id,
                               %{id: @agent_id, workspace_id: @workspace_id}})
    on_exit(fn -> :ets.delete(:chat_agents, @agent_id) end)
    :ok
  end

  describe "compose file validation at write time" do
    test "rejects docker-compose.yml with a host bind mount" do
      compose = ~s|{"services":{"dev":{"image":"x","volumes":["/etc:/host/etc"]}}}|

      assert {:error, msg} =
               WriteFile.execute(
                 %{
                   agent_id: @agent_id,
                   path: ".boomlooper/workspace/docker-compose.yml",
                   content: compose
                 },
                 %{}
               )

      assert msg =~ "host bind mount"
      assert msg =~ "Fix:"
    end

    test "rejects docker-compose.yml with privileged: true" do
      compose = ~s|{"services":{"dev":{"image":"x","privileged":true}}}|

      assert {:error, msg} =
               WriteFile.execute(
                 %{
                   agent_id: @agent_id,
                   path: ".boomlooper/workspace/docker-compose.yml",
                   content: compose
                 },
                 %{}
               )

      assert msg =~ "privileged"
    end

    test "does NOT validate non-compose files" do
      # A random script containing `/etc` in its text shouldn't trip the
      # bind-mount validator — only docker-compose.yml gets checked.
      assert {:ok, _} =
               WriteFile.execute(
                 %{
                   agent_id: @agent_id,
                   path: "some/script.sh",
                   content: "mount -o bind /etc /host"
                 },
                 %{}
               )
    end

    test "unparseable compose is allowed through (compose-up surfaces syntax)" do
      content = "this: is: not: yaml ::"

      # Validator skips unparseable content — we enforce the boundary,
      # not syntax. compose-up will surface the parse error itself.
      assert {:ok, _} =
               WriteFile.execute(
                 %{
                   agent_id: @agent_id,
                   path: ".boomlooper/workspace/docker-compose.yml",
                   content: content
                 },
                 %{}
               )
    end

    test "allows a well-formed compose with a named volume" do
      compose = ~s|{"services":{"dev":{"image":"x","volumes":["${CODE_VOLUME}:/workspace"]}}}|

      assert {:ok, _} =
               WriteFile.execute(
                 %{
                   agent_id: @agent_id,
                   path: ".boomlooper/workspace/docker-compose.yml",
                   content: compose
                 },
                 %{}
               )
    end
  end
end
