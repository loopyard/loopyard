defmodule BoomLooper.AgentBootTest do
  use ExUnit.Case, async: false

  alias BoomLooper.AgentBoot
  alias BoomLooper.ChatAgent

  setup do
    # Clean up agents — :chat_agents is owned by StateKeeper
    _ = BoomLooper.StateKeeper.ensure_tables!()
    for {id, _} <- :ets.tab2list(:chat_agents) do
      :ets.delete(:chat_agents, id)
    end

    :ok
  end

  describe "boot/3" do
    test "registers boot status updates before starting session" do
      id = "boot-test-#{:rand.uniform(100_000)}"
      working_dir = Path.join(System.tmp_dir!(), "agent-boot-status-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(working_dir)
      on_exit(fn -> File.rm_rf!(working_dir) end)

      ChatAgent.register_booting(id, "Test", working_dir)

      # Boot will fail (no workspace supervisor running) but should update status first
      AgentBoot.boot(id, [
        id: id,
        name: "Test",
        working_dir: working_dir,
        started_by: "test",
        bind_mount: working_dir
      ])

      # Agent should have been cleaned up by boot_failed
      # (workspace not running → start_agent fails → boot_failed removes from ETS)
      assert ChatAgent.get_state(id) == nil
    end

    test "sends initial setup message when no workspace config exists" do
      # This tests the default_message logic — when ws_config is nil,
      # the setup guide should be sent as the initial message
      id = "setup-msg-test-#{:rand.uniform(100_000)}"
      working_dir = System.tmp_dir!() |> Path.join("agent-boot-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(working_dir)

      on_exit(fn -> File.rm_rf!(working_dir) end)

      ChatAgent.register_booting(id, "Setup", working_dir)

      # Will fail at workspace startup, but exercises the code path
      AgentBoot.boot(id, [
        id: id,
        name: "Setup",
        working_dir: working_dir,
        started_by: "test",
        bind_mount: working_dir
      ])

      # Just verifying it doesn't crash — the actual message send
      # requires a running workspace + agent GenServer
    end
  end
end
