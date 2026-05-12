defmodule Loopyard.Tools.Container.VolumesTest do
  use ExUnit.Case, async: false

  alias Loopyard.Tools.Container.Volumes

  @agent_id "volumes-tool-test-agent"
  @workspace_id "ws-volumes-test"

  setup do
    # Seed the chat_agents ETS table with a fake agent scoped to
    # @workspace_id. The Volumes tool looks up workspace_id from here.
    :ets.insert(:chat_agents, {@agent_id, %{id: @agent_id, workspace_id: @workspace_id}})
    on_exit(fn -> :ets.delete(:chat_agents, @agent_id) end)
    :ok
  end

  describe "workspace boundary" do
    test "rejects `ls` on a foreign volume" do
      other = "loopyard-some-other-workspace-code"

      assert {:error, msg} =
               Volumes.execute(
                 %{agent_id: @agent_id, action: "ls #{other} /"},
                 %{}
               )

      assert msg =~ "does not belong to this workspace"
      assert msg =~ @workspace_id
    end

    test "rejects `info` on a foreign volume" do
      assert {:error, msg} =
               Volumes.execute(
                 %{agent_id: @agent_id, action: "info loopyard-other-ws-code"},
                 %{}
               )

      assert msg =~ "does not belong"
    end

    test "rejects a volume with an unrelated prefix" do
      assert {:error, _} =
               Volumes.execute(
                 %{agent_id: @agent_id, action: "info random-volume"},
                 %{}
               )
    end

    test "accepts a volume that matches the agent's workspace prefix" do
      # Use a name that passes the prefix check; volume_info will return
      # nil because the volume doesn't actually exist, which is fine —
      # we're only asserting the authorization layer doesn't block.
      own = "loopyard-#{@workspace_id}-code"

      case Volumes.execute(%{agent_id: @agent_id, action: "info #{own}"}, %{}) do
        {:ok, _} ->
          :ok

        # "Volume not found" is the expected error from volume_info when
        # the volume doesn't exist — that means authorization passed.
        {:error, msg} ->
          refute msg =~ "does not belong to this workspace",
                 "authorization should have allowed own-prefix volume"
      end
    end

    test "agent with no workspace gets rejected" do
      :ets.insert(:chat_agents, {"no-ws-agent", %{id: "no-ws-agent"}})
      on_exit(fn -> :ets.delete(:chat_agents, "no-ws-agent") end)

      assert {:error, msg} =
               Volumes.execute(
                 %{agent_id: "no-ws-agent", action: "info loopyard-anything"},
                 %{}
               )

      assert msg =~ "no workspace"
    end
  end
end
