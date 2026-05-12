defmodule Loopyard.Source.Local.SyncMonitorTest do
  use ExUnit.Case, async: false

  alias Loopyard.Source.Local.{Mutagen, SyncMonitor}

  @pubsub Loopyard.PubSub

  # These tests boot SyncMonitor against a stubbed Mutagen runner and
  # assert state transitions + PubSub broadcasts. No real mutagen, no real
  # containers.

  setup do
    agent = start_supervised!({Agent, fn -> %{responses: []} end})

    # Each test pushes a queue of responses; the runner pops one per call.
    # If the queue is empty, return {"", 0} (happy path).
    runner = fn _args ->
      Agent.get_and_update(agent, fn state ->
        case state.responses do
          [h | t] -> {h, %{state | responses: t}}
          [] -> {{"Status: Watching for changes\n", 0}, state}
        end
      end)
    end

    Application.put_env(:loopyard, :mutagen_runner, runner)

    # Stub the container readiness probe so SyncMonitor never shells out
    # to real docker. Default: pretend the container is always ready.
    Application.put_env(:loopyard, :container_ready_check, fn _container -> :ok end)

    on_exit(fn ->
      Application.delete_env(:loopyard, :mutagen_runner)
      Application.delete_env(:loopyard, :container_ready_check)
    end)

    %{agent: agent}
  end

  defp queue(agent, responses) do
    Agent.update(agent, fn state -> %{state | responses: responses} end)
  end

  defp with_worktree(fun) do
    wt = Path.join(System.tmp_dir!(), "loopyard-sm-wt-#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(wt)

    try do
      fun.(wt)
    after
      File.rm_rf!(wt)
    end
  end

  defp start_monitor(workspace_id, worktree_path) do
    start_supervised!(
      {SyncMonitor,
       [
         workspace_id: workspace_id,
         worktree_path: worktree_path,
         container_name: "loopyard-#{workspace_id}-workspace-1"
       ]}
    )
  end

  describe "init → running" do
    test "starts the session on first tick and broadcasts :running", %{agent: agent} do
      with_worktree(fn wt ->
        # First runner call is session_status (:missing → try_start path).
        # Second runner call is start_sync.
        queue(agent, [
          {"session bl-runcase does not exist", 1},
          {"", 0}
        ])

        ws_id = "runcase"
        Loopyard.Events.SourceSync.subscribe(ws_id)

        _pid = start_monitor(ws_id, wt)

        assert_receive %Loopyard.Events.SourceSync.Updated{
                         workspace_id: ^ws_id,
                         status: %{status: :running}
                       },
                       500
      end)
    end
  end

  describe "try_start with missing worktree" do
    test "transitions to :errored and broadcasts", %{agent: agent} do
      ws_id = "nowt-#{:rand.uniform(100_000)}"

      # session_status returns :missing → poll calls try_start → worktree
      # check fails before we ever hit start_sync.
      queue(agent, [{"session does not exist", 1}])

      Phoenix.PubSub.subscribe(@pubsub, SyncMonitor.topic(ws_id))

      _pid =
        start_supervised!(
          {SyncMonitor,
           [
             workspace_id: ws_id,
             worktree_path: "/does/not/exist/#{ws_id}",
             container_name: "loopyard-#{ws_id}-workspace-1"
           ]}
        )

      assert_receive %Loopyard.Events.SourceSync.Updated{
                       workspace_id: ^ws_id,
                       status: %{status: :errored, last_error: err}
                     },
                     500

      assert is_binary(err)
      assert String.contains?(err, "worktree missing")
    end
  end

  describe "status/1" do
    test "returns :stopped when no monitor is running" do
      assert %{status: :stopped} = SyncMonitor.status("ghost-#{:rand.uniform(100_000)}")
    end
  end

  describe "topic/1" do
    test "scopes to workspace id" do
      assert SyncMonitor.topic("abcd") == "source_sync:abcd"
    end
  end

  # Sanity — ensure we're not accidentally hitting the real mutagen binary.
  test "Mutagen.session_name is stable" do
    assert Mutagen.session_name("x") == "loopyard-x"
  end

  describe "container readiness" do
    test "backs off and errors when the container never becomes ready", %{agent: agent} do
      # Make the ready check always fail — simulate a container that
      # hasn't finished booting.
      Application.put_env(:loopyard, :container_ready_check, fn _c -> {:error, :not_ready} end)

      with_worktree(fn wt ->
        queue(agent, [{"session does not exist", 1}])

        ws_id = "notready-#{:rand.uniform(100_000)}"
        Loopyard.Events.SourceSync.subscribe(ws_id)

        _pid = start_monitor(ws_id, wt)

        assert_receive %Loopyard.Events.SourceSync.Updated{
                         workspace_id: ^ws_id,
                         status: %{status: :errored, last_error: err}
                       },
                       2_000

        assert err =~ "container is not ready"
      end)
    end
  end

  describe "terminate/2 session persistence" do
    test "does NOT terminate the session on normal shutdown", %{agent: agent} do
      with_worktree(fn wt ->
        queue(agent, [
          {"session does not exist", 1},
          {"", 0}
        ])

        ws_id = "persist-#{:rand.uniform(100_000)}"
        pid = start_monitor(ws_id, wt)

        # Wait for session creation to settle.
        Loopyard.Events.SourceSync.subscribe(ws_id)

        assert_receive %Loopyard.Events.SourceSync.Updated{
                         workspace_id: ^ws_id,
                         status: %{status: :running}
                       },
                       500

        # Record runner calls from this point on.
        test_pid = self()

        Application.put_env(:loopyard, :mutagen_runner, fn args ->
          send(test_pid, {:mutagen_call, args})
          {"", 0}
        end)

        # Gracefully stop the GenServer (supervisor-like shutdown, not
        # prepare_for_removal). terminate/1 should NOT call terminate_sync.
        ref = Process.monitor(pid)
        GenServer.stop(pid, :normal)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500

        refute_received {:mutagen_call, ["sync", "terminate", _]}
      end)
    end

    test "DOES terminate after prepare_for_removal/1", %{agent: agent} do
      with_worktree(fn wt ->
        queue(agent, [
          {"session does not exist", 1},
          {"", 0}
        ])

        ws_id = "remove-#{:rand.uniform(100_000)}"
        pid = start_monitor(ws_id, wt)

        Loopyard.Events.SourceSync.subscribe(ws_id)

        assert_receive %Loopyard.Events.SourceSync.Updated{
                         workspace_id: ^ws_id,
                         status: %{status: :running}
                       },
                       500

        SyncMonitor.prepare_for_removal(ws_id)

        test_pid = self()

        Application.put_env(:loopyard, :mutagen_runner, fn args ->
          send(test_pid, {:mutagen_call, args})
          {"", 0}
        end)

        ref = Process.monitor(pid)
        GenServer.stop(pid, :normal)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500

        assert_received {:mutagen_call, ["sync", "terminate", _]}
      end)
    end
  end
end
