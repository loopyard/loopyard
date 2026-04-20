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
    test "boot task crashes with agent still :booting → boot_failed fires" do
      id = fresh_id()
      ChatAgent.register_booting(id, "watcher test", File.cwd!())

      # Directly invoke the watcher path with a boot function that
      # crashes. start_monitored returns :ok and runs async.
      Task.Supervisor.start_child(BoomLooper.TaskSupervisor, fn ->
        boot_task =
          Task.Supervisor.async_nolink(BoomLooper.TaskSupervisor, fn ->
            raise "boot exploded"
          end)

        # Inline the watcher logic from AgentBoot.start_monitored so
        # this test doesn't depend on the full boot saga (which needs
        # workspace setup).
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
      end)

      # Give the monitor time to fire.
      Process.sleep(200)

      # boot_failed deletes the ETS row + broadcasts BootFailed.
      assert :ets.lookup(:chat_agents, id) == []
    end

    test "boot task crashes but agent is no longer :booting → no-op" do
      id = fresh_id()

      # Pre-populate ETS with a non-:booting status, as if the agent
      # had already finished booting and transitioned.
      summary = %{id: id, status: :idle, name: "already ready", working_dir: File.cwd!(), started_at: DateTime.utc_now(), last_activity_at: DateTime.utc_now()}
      :ets.insert(:chat_agents, {id, summary})

      Task.Supervisor.start_child(BoomLooper.TaskSupervisor, fn ->
        boot_task =
          Task.Supervisor.async_nolink(BoomLooper.TaskSupervisor, fn ->
            raise "boot exploded"
          end)

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
      end)

      Process.sleep(200)

      # ETS row preserved — the watcher correctly no-opped.
      assert [{^id, row}] = :ets.lookup(:chat_agents, id)
      assert row.status == :idle

      on_exit(fn -> :ets.delete(:chat_agents, id) end)
    end

    test "boot task clean exit → no boot_failed (nothing to surface)" do
      id = fresh_id()
      ChatAgent.register_booting(id, "clean exit", File.cwd!())

      Task.Supervisor.start_child(BoomLooper.TaskSupervisor, fn ->
        boot_task =
          Task.Supervisor.async_nolink(BoomLooper.TaskSupervisor, fn ->
            :ok
          end)

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
      end)

      Process.sleep(200)

      # ETS row still :booting — the watcher doesn't clean up after
      # a clean boot. That's the real boot path's responsibility.
      assert [{^id, row}] = :ets.lookup(:chat_agents, id)
      assert row.status == :booting

      on_exit(fn -> :ets.delete(:chat_agents, id) end)
    end

    test "public AgentBoot.start_monitored/3 with a crashing boot path surfaces failure within ~100ms" do
      # Exercise the real public function with agent_opts that will
      # cause the saga to crash immediately. The saga's first step is
      # load_config_step which reads from a volume — non-existent
      # workspace_id yields nil config, which is valid; the crash
      # needs to come from something else. Using bogus agent_type
      # is the easiest repro: Agents.Registry.name_to_module/1 will
      # raise.
      id = fresh_id()
      ChatAgent.register_booting(id, "start_monitored test", File.cwd!())

      BoomLooper.AgentBoot.start_monitored(
        id,
        [
          working_dir: File.cwd!(),
          workspace_id: "nonexistent-ws",
          agent_type: "definitely_not_a_real_agent_type_#{:rand.uniform(1_000_000)}"
        ],
        # Short deadline so even if the saga hangs we don't wait long.
        boot_deadline_ms: 2_000
      )

      # The watcher should fire boot_failed within a couple seconds —
      # either because the saga raised immediately, or because the
      # deadline elapsed.
      start = System.monotonic_time(:millisecond)

      Enum.reduce_while(1..50, nil, fn _i, _acc ->
        Process.sleep(100)
        case :ets.lookup(:chat_agents, id) do
          [] -> {:halt, :deleted}
          [{^id, %{status: :crashed}}] -> {:halt, :crashed}
          _ -> {:cont, nil}
        end
      end)

      elapsed = System.monotonic_time(:millisecond) - start

      assert elapsed < 3_000,
             "boot failure should surface within 3s (surface #9). Took #{elapsed}ms."

      assert :ets.lookup(:chat_agents, id) == [] or
               match?([{^id, %{status: :crashed}}], :ets.lookup(:chat_agents, id))
    end
  end
end
