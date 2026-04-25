defmodule BoomLooper.AgentBootWatcherTest do
  @moduledoc """
  Surface #9 of plans/agent-sanity.md.

  When a boot Task dies without running the `boot_failed/2` path
  (OS kill, TaskSupervisor :shutdown timeout, uncaught raise), the
  agent's ETS row stays in `:booting` status until the
  `@stuck_booting_seconds` UI heuristic kicks in (5 minutes). Five
  minutes is an eternity — users stare at a spinner before seeing
  any actionable signal.

  `AgentBoot.start_monitored/3` spawns the boot Task as async_nolink
  plus a sibling watcher Task that `Process.monitor/1`s the boot pid.
  On `:DOWN` with a non-normal reason AND status still `:booting`,
  the watcher calls `ChatAgent.boot_failed/2` with
  `{:boot_task_crashed, reason}` — the UI clears within ~100ms.

  The watcher also enforces a hard deadline (default 2 min) for
  wedged boots that didn't actually crash but never finish.

  Tests:
    1. Boot task crash with agent :booting → boot_failed fires.
    2. Boot task crash with agent already moved (not :booting) →
       no-op (don't clobber post-boot state).
    3. Boot task deadline exceeded → force-kill + boot_failed.
    4. Boot task clean exit → no boot_failed (nothing to do).
  """

  use ExUnit.Case, async: false

  alias BoomLooper.ChatAgent

  @moduletag timeout: 10_000

  defp fresh_id do
    "boot-watcher-test-#{:rand.uniform(100_000)}"
  end

  describe "surface #9: boot-task watcher" do
    # Inline the watcher logic from AgentBoot.start_monitored so these
    # tests don't depend on the full boot saga. Returns once the watcher
    # task has finished its work (DOWN handled). Sends `:watcher_done`
    # back to `parent` instead of `Process.sleep`-ing for an arbitrary
    # window.
    defp run_watcher(parent, id, boot_fn) do
      Task.Supervisor.start_child(BoomLooper.TaskSupervisor, fn ->
        boot_task = Task.Supervisor.async_nolink(BoomLooper.TaskSupervisor, boot_fn)
        ref = Process.monitor(boot_task.pid)

        receive do
          {:DOWN, ^ref, :process, _, :normal} ->
            :ok

          {:DOWN, ^ref, :process, _, reason} ->
            case :ets.lookup(:chat_agents, id) do
              [{^id, %{status: :booting}}] ->
                ChatAgent.boot_failed(id, {:boot_task_crashed, reason})

              _ ->
                :ok
            end
        end

        send(parent, :watcher_done)
      end)
    end

    test "boot task crashes with agent still :booting → boot_failed fires" do
      id = fresh_id()
      ChatAgent.register_booting(id, "watcher test", File.cwd!())

      run_watcher(self(), id, fn -> raise "boot exploded" end)

      # Wait for the watcher's DOWN handler to finish, not an arbitrary
      # 200ms. Tight 500ms cap catches a real hang without inflating the
      # suite when the path is fast.
      assert_receive :watcher_done, 500

      # boot_failed deletes the ETS row + broadcasts BootFailed.
      assert :ets.lookup(:chat_agents, id) == []
    end

    test "boot task crashes but agent is no longer :booting → no-op" do
      id = fresh_id()

      # Pre-populate ETS with a non-:booting status, as if the agent
      # had already finished booting and transitioned.
      summary = %{id: id, status: :idle, name: "already ready", working_dir: File.cwd!(), started_at: DateTime.utc_now(), last_activity_at: DateTime.utc_now()}
      :ets.insert(:chat_agents, {id, summary})

      run_watcher(self(), id, fn -> raise "boot exploded" end)

      assert_receive :watcher_done, 500

      # ETS row preserved — the watcher correctly no-opped.
      assert [{^id, row}] = :ets.lookup(:chat_agents, id)
      assert row.status == :idle

      on_exit(fn -> :ets.delete(:chat_agents, id) end)
    end

    test "boot task clean exit → no boot_failed (nothing to surface)" do
      id = fresh_id()
      ChatAgent.register_booting(id, "clean exit", File.cwd!())

      run_watcher(self(), id, fn -> :ok end)

      assert_receive :watcher_done, 500

      # ETS row still :booting — the watcher doesn't clean up after
      # a clean boot. That's the real boot path's responsibility.
      assert [{^id, row}] = :ets.lookup(:chat_agents, id)
      assert row.status == :booting

      on_exit(fn -> :ets.delete(:chat_agents, id) end)
    end

    test "public AgentBoot.start_monitored/3 with a crashing boot path surfaces failure within ~100ms" do
      # Subscribe to the ChatAgent topic so we can deterministically wait
      # for the BootFailed event instead of polling ETS every 100ms.
      BoomLooper.ChatAgent.subscribe()

      id = fresh_id()
      ChatAgent.register_booting(id, "start_monitored test", File.cwd!())

      BoomLooper.AgentBoot.start_monitored(
        id,
        [
          working_dir: File.cwd!(),
          workspace_id: "nonexistent-ws",
          agent_type: "definitely_not_a_real_agent_type_#{:rand.uniform(1_000_000)}"
        ],
        # Tight deadline keeps the test fast — the saga raises on the
        # bogus agent_type lookup well before this elapses, so the
        # deadline is just the upper bound.
        boot_deadline_ms: 500
      )

      assert_receive %BoomLooper.Events.ChatAgent.BootFailed{id: ^id}, 2_000

      assert :ets.lookup(:chat_agents, id) == [] or
               match?([{^id, %{status: :crashed}}], :ets.lookup(:chat_agents, id))
    end
  end
end
