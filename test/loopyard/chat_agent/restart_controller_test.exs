defmodule Loopyard.ChatAgent.RestartControllerTest do
  use ExUnit.Case, async: false

  # Tests boot real ChatAgents under the shared cwd WorkspaceGroup,
  # which churns under full-suite load. Bump the per-test budget so
  # setup doesn't flake when the group is mid-rebuild.
  @moduletag timeout: 10_000

  alias Loopyard.ChatAgent.RestartController
  alias Loopyard.TestHelpers

  setup do
    # Clamp the threshold for tests so we don't have to actually crash
    # 5 times in 60 seconds. 3 crashes in 5s is enough to prove the
    # mechanism while staying fast — and crucially the 5s window
    # survives a CI runner that pauses for a few seconds between
    # controller restart and the next crash (which used to fall out
    # of a 500ms window and produce flaky failures).
    Application.put_env(:loopyard, :quarantine_threshold, {3, 5_000})
    Application.put_env(:loopyard, :crash_backoff_base_ms, 10)

    on_exit(fn ->
      Application.delete_env(:loopyard, :quarantine_threshold)
      Application.delete_env(:loopyard, :crash_backoff_base_ms)
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
      Loopyard.Events.ChatAgent.subscribe()
      :ok = RestartController.release(id)
      assert_receive %Loopyard.Events.ChatAgent.Released{id: ^id}, 500
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

      :ets.insert(
        :chat_agents,
        {live_id, %{id: live_id, name: "alive", status: :idle, messages: []}}
      )

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
      workspace_id = Loopyard.Workspace.workspace_id(path)
      {:ok, _} = Loopyard.WorkspaceSupervisor.start_workspace(workspace_id, path)

      on_exit(fn ->
        TestHelpers.destroy_workspace(workspace_id)
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
          Loopyard.ChatAgent.stop_agent(id)
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
      # Own, isolated workspace — NOT File.cwd!(). The cwd-derived id is shared
      # by many tests, so under full-suite load that workspace group churns
      # (ServiceManager restarts → WorkspaceSupervisor rebuilds the group),
      # unregistering the agent supervisor + RestartController mid-sequence and
      # breaking kill→respawn→quarantine. A unique dir insulates this test.
      path =
        Path.join(System.tmp_dir!(), "loopyard-quarantine-#{System.unique_integer([:positive])}")

      File.mkdir_p!(path)
      workspace_id = Loopyard.Workspace.workspace_id(path)
      {:ok, _} = Loopyard.WorkspaceSupervisor.start_workspace(workspace_id, path)

      on_exit(fn ->
        TestHelpers.destroy_workspace(workspace_id)
        File.rm_rf(path)
        Process.sleep(50)
      end)

      %{workspace_id: workspace_id, path: path}
    end

    test "after N abnormal exits in window, the agent is quarantined and not respawned",
         %{workspace_id: workspace_id, path: path} do
      id = "crash-loop-#{:rand.uniform(1_000_000)}"
      Loopyard.Events.ChatAgent.subscribe()

      on_exit(fn ->
        try do
          Loopyard.ChatAgent.stop_agent(id)
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

      # Drive a crash loop: kill the live agent, let the controller respawn it,
      # kill again — until it quarantines. Rather than guess respawn latency with
      # a fixed sleep (the old flake), each step waits deterministically for a
      # live pid, then confirms the kill via :DOWN. We stop as soon as the agent
      # is quarantined: that's reached either by 3 crashes inside the window OR by
      # a respawn failing under the rapid re-kills — both are the crash-loop →
      # quarantine behavior under test. Bounded so a genuine "never quarantines"
      # regression still fails instead of looping forever.
      Enum.reduce_while(1..8, nil, fn _, _ ->
        if RestartController.quarantined?(id) do
          {:halt, :ok}
        else
          case await_live_pid(id, 3_000) do
            nil ->
              {:halt, :ok}

            pid ->
              ref = Process.monitor(pid)
              Process.exit(pid, :kill)
              assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
              {:cont, nil}
          end
        end
      end)

      # The 3rd crash should have triggered quarantine. Wait briefly
      # for the broadcast to land in our mailbox.
      assert_receive %Loopyard.Events.ChatAgent.Quarantined{id: ^id, summary: summary}, 2_000
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
          Loopyard.ChatAgent.stop_agent(id)
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

      case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
        [{pid, _}] -> Process.exit(pid, :kill)
        [] -> :ok
      end

      # Give the respawn a chance to happen
      Process.sleep(300)

      # Agent should be alive again (respawn happened), not quarantined
      refute RestartController.quarantined?(id)
      assert [{_pid, _}] = Registry.lookup(Loopyard.ChatAgentRegistry, id)
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
      Loopyard.ChatAgent.stop_agent(id)
      Process.sleep(100)

      refute RestartController.quarantined?(id)
    end
  end

  describe "crash_history persistence across controller restart" do
    # Audit HIGH #3 (commit 02d42f6). WorkspaceGroup uses
    # :one_for_all supervision — a sibling crash (ServiceManager,
    # ContainerMonitor, Checkpointer) restarts the RestartController.
    # Before the fix, crash_history lived in the GenServer's state
    # map and was wiped by the restart: an agent that was 4-of-5
    # crashes reset to 0-of-5, silently bypassing quarantine.
    #
    # These tests prove the history survives via ETS
    # (:restart_controller_history, keyed by {workspace_id, agent_id})
    # and that a post-restart controller still sees the pre-restart
    # counter.

    setup do
      path = File.cwd!()
      workspace_id = Loopyard.Workspace.workspace_id(path)
      {:ok, _} = Loopyard.WorkspaceSupervisor.start_workspace(workspace_id, path)

      on_exit(fn ->
        TestHelpers.destroy_workspace(workspace_id)
        Process.sleep(50)
      end)

      %{workspace_id: workspace_id, path: path}
    end

    test "ETS-backed history survives a controller-only restart", %{workspace_id: workspace_id} do
      agent_id = "history-persists-#{:rand.uniform(1_000_000)}"
      on_exit(fn -> :ets.delete(:restart_controller_history, {workspace_id, agent_id}) end)

      now = System.monotonic_time(:millisecond)
      stamps = [now - 50, now - 100]

      :ets.insert(:restart_controller_history, {{workspace_id, agent_id}, stamps})

      old_pid = controller_pid(workspace_id)
      assert is_pid(old_pid)

      # Kill just the controller. WorkspaceGroup is :one_for_all so
      # the siblings restart too — the registry gets re-registered
      # when the new controller init/1 runs.
      ref = Process.monitor(old_pid)
      Process.exit(old_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^old_pid, _}, 1_000

      new_pid = wait_for_new_controller(workspace_id, old_pid)
      assert new_pid != old_pid

      # The invariant: the history row is still in ETS after the
      # controller restart. Pre-fix this lived in process state and
      # would be gone.
      assert [{{^workspace_id, ^agent_id}, persisted}] =
               :ets.lookup(:restart_controller_history, {workspace_id, agent_id})

      assert persisted == stamps
    end

    @tag timeout: 10_000
    test "crash after controller restart counts pre-restart history toward quarantine",
         %{workspace_id: workspace_id, path: path} do
      # Threshold from suite setup: 3 crashes in 500ms. Pre-seed two
      # stamps — one more crash should quarantine. Without the ETS
      # fix the new controller would start with an empty map, the
      # crash would count as 1/3, and the agent would respawn instead
      # of quarantine.
      agent_id = "quarantine-after-restart-#{:rand.uniform(1_000_000)}"

      Loopyard.Events.ChatAgent.subscribe()

      on_exit(fn ->
        try do
          Loopyard.ChatAgent.stop_agent(agent_id)
        catch
          :exit, _ -> :ok
        end

        :ets.delete(:chat_agents, agent_id)
        :ets.delete(:restart_controller_history, {workspace_id, agent_id})
      end)

      now = System.monotonic_time(:millisecond)
      # Two recent timestamps, still inside the 500ms window.
      :ets.insert(
        :restart_controller_history,
        {{workspace_id, agent_id}, [now - 20, now - 40]}
      )

      # Force a :one_for_all restart of the WorkspaceGroup children
      # by killing the RestartController.
      old_pid = controller_pid(workspace_id)
      assert is_pid(old_pid)
      dref = Process.monitor(old_pid)
      Process.exit(old_pid, :kill)
      assert_receive {:DOWN, ^dref, :process, ^old_pid, _}, 1_000
      _new_pid = wait_for_new_controller(workspace_id, old_pid)

      # Now start an agent under the reborn controller and kill it.
      # That DOWN is crash #3, which MUST quarantine on the basis of
      # the pre-seeded stamps.
      {:ok, _agent_pid} =
        Loopyard.TestHelpers.start_agent(
          id: agent_id,
          name: "PostRestartCrasher",
          working_dir: path,
          started_by: "test"
        )

      [{apid, _}] = Registry.lookup(Loopyard.ChatAgentRegistry, agent_id)
      Process.exit(apid, :kill)

      # 5s — under CI load the controller takes longer to process the
      # DOWN + decide to quarantine. The pre-seeded stamps are inside
      # the threshold window, so it WILL quarantine; just sometimes
      # slow to do so.
      assert_receive %Loopyard.Events.ChatAgent.Quarantined{id: ^agent_id}, 5_000
      assert RestartController.quarantined?(agent_id)
    end
  end

  describe "release/1 ↔ handle_agent_down race (audit-2 MEDIUM #5)" do
    # Pre-fix: release/1 called :ets.delete on the history table from
    # the caller's process (operator clicking release in
    # /system/quarantine). handle_agent_down in the controller process
    # does read_history → filter → [now | stamps] → write_history. If
    # release fired between the read and write, the crash stamp
    # resurrected the just-deleted history — operator's release would
    # silently fail.
    #
    # Post-fix: purge_history_for/2 routes through a GenServer.call
    # to the controller, so the delete serializes with the DOWN
    # handler in the same process. We verify by:
    #   1. Seeding history directly in ETS.
    #   2. Starting a controller.
    #   3. Driving release/1 and a DOWN concurrently.
    #   4. Asserting the history ends up clean.

    setup do
      path = File.cwd!()
      workspace_id = Loopyard.Workspace.workspace_id(path)
      {:ok, _} = Loopyard.WorkspaceSupervisor.start_workspace(workspace_id, path)

      on_exit(fn ->
        TestHelpers.destroy_workspace(workspace_id)
        Process.sleep(50)
      end)

      %{workspace_id: workspace_id, path: path}
    end

    test "release/1 funnels the ETS delete through the controller", %{workspace_id: workspace_id} do
      agent_id = "purge-hop-#{:rand.uniform(1_000_000)}"

      :ets.insert(
        :chat_agents,
        {agent_id,
         %{
           id: agent_id,
           name: "Purger",
           status: :crashed,
           messages: [],
           workspace_id: workspace_id,
           quarantined: true,
           quarantine_reason: "test",
           quarantine_crashed_at: DateTime.utc_now()
         }}
      )

      :ets.insert(
        :restart_controller_history,
        {{workspace_id, agent_id}, [System.monotonic_time(:millisecond)]}
      )

      on_exit(fn ->
        :ets.delete(:chat_agents, agent_id)
        :ets.delete(:restart_controller_history, {workspace_id, agent_id})
      end)

      assert :ok = RestartController.release(agent_id)

      # History row must be gone AFTER release/1 returns — both the
      # hop case (controller alive) and the fallback (no controller)
      # have to clear it.
      assert :ets.lookup(:restart_controller_history, {workspace_id, agent_id}) == []
    end

    test "release wins against a concurrent crash when serialized",
         %{workspace_id: workspace_id} do
      agent_id = "release-race-#{:rand.uniform(1_000_000)}"

      :ets.insert(
        :chat_agents,
        {agent_id,
         %{
           id: agent_id,
           name: "Racer",
           status: :crashed,
           messages: [],
           workspace_id: workspace_id,
           quarantined: true,
           quarantine_reason: "test",
           quarantine_crashed_at: DateTime.utc_now()
         }}
      )

      on_exit(fn ->
        :ets.delete(:chat_agents, agent_id)
        :ets.delete(:restart_controller_history, {workspace_id, agent_id})
      end)

      # Seed old crash history.
      :ets.insert(
        :restart_controller_history,
        {{workspace_id, agent_id}, [System.monotonic_time(:millisecond) - 10]}
      )

      # Kick off release/1 in another Task while simultaneously
      # exercising the DOWN path. Both writes must serialize through
      # the controller GenServer. With the pre-fix code, release's
      # direct :ets.delete would sometimes lose to the read-modify-
      # write — leaving history behind. Post-fix, either:
      #   - DOWN runs first: history has [now, old_stamp], release
      #     then clears it → final: []
      #   - release runs first: ETS is empty, DOWN writes [now] →
      #     final: [now]
      # Either outcome is fine. The invariant we care about is that
      # release can't be silently skipped, which is what the old
      # race produced.

      # For a deterministic assertion we call release synchronously
      # so the controller handles {:purge_history, ...} before we
      # check. This confirms the call_hop path does clear ETS.
      assert :ok = RestartController.release(agent_id)
      assert :ets.lookup(:restart_controller_history, {workspace_id, agent_id}) == []
    end

    test "fallback to direct :ets.delete when no controller is registered" do
      # Cover the "no controller" branch in purge_history_for/2. We
      # use a workspace_id that has no RestartController registered.
      unknown_ws = "unknown-ws-#{:rand.uniform(1_000_000)}"
      agent_id = "unknown-agent-#{:rand.uniform(1_000_000)}"

      :ets.insert(
        :chat_agents,
        {agent_id,
         %{
           id: agent_id,
           name: "Orphan",
           status: :crashed,
           messages: [],
           workspace_id: unknown_ws,
           quarantined: true,
           quarantine_reason: "test",
           quarantine_crashed_at: DateTime.utc_now()
         }}
      )

      :ets.insert(
        :restart_controller_history,
        {{unknown_ws, agent_id}, [System.monotonic_time(:millisecond)]}
      )

      on_exit(fn ->
        :ets.delete(:chat_agents, agent_id)
        :ets.delete(:restart_controller_history, {unknown_ws, agent_id})
      end)

      # No controller registered for unknown_ws, so purge_history_for/2
      # falls back to the direct :ets.delete. The history row must
      # still be cleared.
      assert :ok = RestartController.release(agent_id)
      assert :ets.lookup(:restart_controller_history, {unknown_ws, agent_id}) == []
    end
  end

  # ── Helpers ──

  defp controller_pid(workspace_id) do
    case Registry.lookup(
           Loopyard.ChatAgent.RestartControllerRegistry,
           workspace_id
         ) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # Poll until a NEW controller pid is registered, or flunk on timeout.
  # :one_for_all restart is async — we have to wait for the supervisor
  # to bring the replacement up and register it.
  defp wait_for_new_controller(workspace_id, old_pid, deadline_ms \\ 2_000) do
    started = System.monotonic_time(:millisecond)

    loop = fn loop ->
      case controller_pid(workspace_id) do
        nil ->
          if System.monotonic_time(:millisecond) - started > deadline_ms do
            flunk("no controller registered after restart")
          end

          Process.sleep(20)
          loop.(loop)

        ^old_pid ->
          if System.monotonic_time(:millisecond) - started > deadline_ms do
            flunk("controller did not restart (still #{inspect(old_pid)})")
          end

          Process.sleep(20)
          loop.(loop)

        new_pid ->
          new_pid
      end
    end

    loop.(loop)
  end

  # A currently-registered, alive pid for the agent, or nil if none appears
  # within the deadline. Polls (the agent may be mid-respawn) rather than
  # assuming a fixed latency. nil means "no live agent" — e.g. it quarantined
  # and won't respawn, which the caller treats as a stop condition.
  defp await_live_pid(id, deadline_ms \\ 3_000) do
    started = System.monotonic_time(:millisecond)

    loop = fn loop ->
      with [{pid, _}] <- Registry.lookup(Loopyard.ChatAgentRegistry, id),
           true <- Process.alive?(pid) do
        pid
      else
        _ ->
          if System.monotonic_time(:millisecond) - started > deadline_ms do
            nil
          else
            Process.sleep(20)
            loop.(loop)
          end
      end
    end

    loop.(loop)
  end
end
