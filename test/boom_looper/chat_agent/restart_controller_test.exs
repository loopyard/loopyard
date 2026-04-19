defmodule BoomLooper.ChatAgent.RestartControllerTest do
  use ExUnit.Case, async: false

  alias BoomLooper.ChatAgent.RestartController
  alias BoomLooper.TestHelpers

  setup do
    # Clamp the threshold way down for tests so we don't have to
    # actually crash 5 times in 60 seconds. 3 crashes in 500ms is
    # enough to prove the mechanism while staying fast.
    Application.put_env(:boom_looper, :quarantine_threshold, {3, 500})
    Application.put_env(:boom_looper, :crash_backoff_base_ms, 10)

    on_exit(fn ->
      Application.delete_env(:boom_looper, :quarantine_threshold)
      Application.delete_env(:boom_looper, :crash_backoff_base_ms)
    end)

    :ok
  end

  describe "release/1" do
    setup do
      id = "release-test-#{:rand.uniform(1_000_000)}"

      :ets.insert(
        :chat_agents,
        {id,
         %{
           id: id,
           name: "Release Test",
           status: :crashed,
           messages: [],
           workspace_id: nil,
           quarantined: true,
           quarantine_reason: "test",
           quarantine_crashed_at: DateTime.utc_now()
         }}
      )

      on_exit(fn -> :ets.delete(:chat_agents, id) end)
      %{id: id}
    end

    test "clears the quarantine flag from the ETS summary", %{id: id} do
      assert RestartController.quarantined?(id)
      assert :ok = RestartController.release(id)
      refute RestartController.quarantined?(id)
    end

    test "strips quarantine metadata fields, not just the flag", %{id: id} do
      :ok = RestartController.release(id)
      [{^id, summary}] = :ets.lookup(:chat_agents, id)

      refute Map.has_key?(summary, :quarantined)
      refute Map.has_key?(summary, :quarantine_reason)
      refute Map.has_key?(summary, :quarantine_crashed_at)
    end

    test "broadcasts Released on the chat_agents topic", %{id: id} do
      BoomLooper.Events.ChatAgent.subscribe()
      :ok = RestartController.release(id)
      assert_receive %BoomLooper.Events.ChatAgent.Released{id: ^id}, 500
    end

    test "is idempotent — calling release on a released agent is :ok", %{id: id} do
      :ok = RestartController.release(id)
      assert :ok = RestartController.release(id)
    end

    test "release on an unknown agent id is :ok (no crash)" do
      assert :ok = RestartController.release("does-not-exist")
    end
  end

  describe "quarantined?/1" do
    test "returns false for an agent with no ETS entry" do
      refute RestartController.quarantined?("no-such-agent")
    end

    test "returns false for an agent without the quarantined flag" do
      id = "not-quarantined-#{:rand.uniform(1_000_000)}"
      :ets.insert(:chat_agents, {id, %{id: id, status: :idle, messages: []}})
      on_exit(fn -> :ets.delete(:chat_agents, id) end)

      refute RestartController.quarantined?(id)
    end

    test "returns true when the flag is set" do
      id = "quarantined-#{:rand.uniform(1_000_000)}"

      :ets.insert(
        :chat_agents,
        {id, %{id: id, status: :crashed, messages: [], quarantined: true}}
      )

      on_exit(fn -> :ets.delete(:chat_agents, id) end)

      assert RestartController.quarantined?(id)
    end
  end

  describe "list_quarantined/0" do
    test "returns only agents with the quarantined flag set, with key fields" do
      live_id = "live-#{:rand.uniform(1_000_000)}"
      q_id = "q-#{:rand.uniform(1_000_000)}"
      crashed_at = DateTime.utc_now()

      :ets.insert(:chat_agents, {live_id, %{id: live_id, name: "alive", status: :idle, messages: []}})

      :ets.insert(
        :chat_agents,
        {q_id,
         %{
           id: q_id,
           name: "doomed",
           status: :crashed,
           messages: [],
           workspace_id: "ws-1",
           quarantined: true,
           quarantine_reason: "5 crashes",
           quarantine_crashed_at: crashed_at
         }}
      )

      on_exit(fn ->
        :ets.delete(:chat_agents, live_id)
        :ets.delete(:chat_agents, q_id)
      end)

      results = RestartController.list_quarantined()

      assert Enum.any?(results, fn r ->
               r.id == q_id and r.name == "doomed" and r.workspace_id == "ws-1" and
                 r.reason == "5 crashes" and r.crashed_at == crashed_at
             end)

      refute Enum.any?(results, fn r -> r.id == live_id end)
    end
  end

  describe "start_agent/2 quarantine gate" do
    # Full integration: start a workspace, quarantine an agent, attempt
    # to re-start it via the controller — expect :quarantined.

    setup do
      path = File.cwd!()
      workspace_id = BoomLooper.Workspace.workspace_id(path)
      {:ok, _} = BoomLooper.WorkspaceSupervisor.start_workspace(workspace_id, path)

      on_exit(fn ->
        BoomLooper.WorkspaceSupervisor.stop_workspace(workspace_id)
        Process.sleep(50)
      end)

      %{workspace_id: workspace_id, path: path}
    end

    test "start_agent returns {:error, :quarantined} when the id is quarantined", %{
      workspace_id: workspace_id,
      path: path
    } do
      id = "gate-test-#{:rand.uniform(1_000_000)}"

      # Pre-seed ETS with a quarantined entry
      :ets.insert(
        :chat_agents,
        {id,
         %{
           id: id,
           name: "quarantined",
           status: :crashed,
           messages: [],
           workspace_id: workspace_id,
           quarantined: true,
           quarantine_reason: "test",
           quarantine_crashed_at: DateTime.utc_now()
         }}
      )

      on_exit(fn -> :ets.delete(:chat_agents, id) end)

      assert {:error, :quarantined} =
               RestartController.start_agent(workspace_id,
                 id: id,
                 name: "quarantined",
                 working_dir: path,
                 started_by: "test"
               )
    end

    test "start_agent succeeds once the agent is released", %{
      workspace_id: workspace_id,
      path: path
    } do
      id = "release-start-#{:rand.uniform(1_000_000)}"

      :ets.insert(
        :chat_agents,
        {id,
         %{
           id: id,
           name: "released",
           status: :crashed,
           messages: [],
           workspace_id: workspace_id,
           quarantined: true,
           quarantine_reason: "test",
           quarantine_crashed_at: DateTime.utc_now()
         }}
      )

      on_exit(fn ->
        try do
          BoomLooper.ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        :ets.delete(:chat_agents, id)
      end)

      # Blocked while quarantined
      assert {:error, :quarantined} =
               RestartController.start_agent(workspace_id,
                 id: id,
                 name: "released",
                 working_dir: path,
                 started_by: "test"
               )

      # Release, then start succeeds
      :ok = RestartController.release(id)

      assert {:ok, _pid} =
               RestartController.start_agent(workspace_id,
                 id: id,
                 name: "released",
                 working_dir: path,
                 started_by: "test"
               )
    end
  end

  describe "crash-loop quarantine trigger" do
    # Spawn an agent, kill it repeatedly faster than the threshold
    # window, assert the controller quarantines it on the Nth crash.

    setup do
      path = File.cwd!()
      workspace_id = BoomLooper.Workspace.workspace_id(path)
      {:ok, _} = BoomLooper.WorkspaceSupervisor.start_workspace(workspace_id, path)

      on_exit(fn ->
        BoomLooper.WorkspaceSupervisor.stop_workspace(workspace_id)
        Process.sleep(50)
      end)

      %{workspace_id: workspace_id, path: path}
    end

    test "after N abnormal exits in window, the agent is quarantined and not respawned",
         %{workspace_id: workspace_id, path: path} do
      id = "crash-loop-#{:rand.uniform(1_000_000)}"
      BoomLooper.Events.ChatAgent.subscribe()

      on_exit(fn ->
        try do
          BoomLooper.ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        :ets.delete(:chat_agents, id)
      end)

      # Start the agent through the full path (controller → supervisor).
      {:ok, _pid} =
        TestHelpers.start_agent(
          id: id,
          name: "Crasher",
          working_dir: path,
          started_by: "test"
        )

      # Kill it 3 times in a row — threshold is 3/500ms from setup.
      for _ <- 1..3 do
        case Registry.lookup(BoomLooper.ChatAgentRegistry, id) do
          [{pid, _}] ->
            Process.exit(pid, :kill)
            # Give the controller time to see :DOWN and decide
            Process.sleep(100)

          [] ->
            :ok
        end
      end

      # The 3rd crash should have triggered quarantine. Wait briefly
      # for the broadcast to land in our mailbox.
      assert_receive %BoomLooper.Events.ChatAgent.Quarantined{id: ^id, summary: summary}, 2_000
      assert summary.quarantined == true
      assert summary.quarantine_reason =~ "killed"

      # And a new call to start_agent should be refused until release.
      assert {:error, :quarantined} =
               RestartController.start_agent(workspace_id,
                 id: id,
                 name: "Crasher",
                 working_dir: path,
                 started_by: "test"
               )

      # ETS still has the agent (so it shows in /system/quarantine)
      # but with the flag set.
      assert RestartController.quarantined?(id)
    end

    test "a single abnormal exit does NOT quarantine — below threshold",
         %{path: path} do
      id = "single-crash-#{:rand.uniform(1_000_000)}"

      on_exit(fn ->
        try do
          BoomLooper.ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        :ets.delete(:chat_agents, id)
      end)

      {:ok, _pid} =
        TestHelpers.start_agent(
          id: id,
          name: "One-off",
          working_dir: path,
          started_by: "test"
        )

      case Registry.lookup(BoomLooper.ChatAgentRegistry, id) do
        [{pid, _}] -> Process.exit(pid, :kill)
        [] -> :ok
      end

      # Give the respawn a chance to happen
      Process.sleep(300)

      # Agent should be alive again (respawn happened), not quarantined
      refute RestartController.quarantined?(id)
      assert [{_pid, _}] = Registry.lookup(BoomLooper.ChatAgentRegistry, id)
    end

    test "normal shutdown (not a crash) does not count toward the threshold",
         %{path: path} do
      id = "clean-stop-#{:rand.uniform(1_000_000)}"

      on_exit(fn -> :ets.delete(:chat_agents, id) end)

      {:ok, _pid} =
        TestHelpers.start_agent(
          id: id,
          name: "Clean",
          working_dir: path,
          started_by: "test"
        )

      # Explicit stop is not a crash — no respawn, no crash count
      BoomLooper.ChatAgent.stop_agent(id)
      Process.sleep(100)

      refute RestartController.quarantined?(id)
    end
  end
end
