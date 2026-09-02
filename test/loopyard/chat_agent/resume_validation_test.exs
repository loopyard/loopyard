defmodule Loopyard.ChatAgent.ResumeValidationTest do
  @moduledoc """
  init_resume validates the saved ETS summary before reconstructing a
  ChatAgent struct from it. Missing required fields (working_dir,
  name, started_at) indicate ETS corruption, a schema drift, or a
  half-populated row from an aborted boot — any of which would
  otherwise produce a struct with nil fields that crashes on first
  use.

  Refusing to resume + emitting clear telemetry + a logged error is
  better than silently booting a broken agent. The supervisor will
  surface the `{:corrupted_resume_state, missing_fields}` stop
  reason and a human can remove-and-recreate the agent.
  """

  use Loopyard.AgentCase

  alias Loopyard.ChatAgent
  alias Loopyard.TestSupport.RecordingBackend

  @moduletag timeout: 10_000

  setup do
    RecordingBackend.reset()
    :ok
  end

  describe "init_resume summary validation" do
    test "missing working_dir → stop with :corrupted_resume_state + telemetry" do
      id = "corrupt-ws-#{:rand.uniform(100_000)}"
      now = DateTime.utc_now()

      bad_summary = %{
        id: id,
        name: "test",
        # working_dir MISSING
        started_at: now,
        last_activity_at: now,
        status: :stopped,
        messages: []
      }

      :ets.insert(:chat_agents, {id, bad_summary})
      on_exit(fn -> :ets.delete(:chat_agents, id) end)

      parent = self()
      handler_id = "resume-rejected-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:loopyard, :agent, :resume_rejected],
        fn _event, _m, meta, _cfg -> send(parent, {:rejected, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Trap the supervisor's EXIT so the stop signal doesn't kill the test.
      Process.flag(:trap_exit, true)

      # Call GenServer.start_link directly (bypassing TestHelpers so
      # we can capture the stop reason).
      result = GenServer.start_link(ChatAgent, id: id, resume: true, backend: RecordingBackend)

      assert {:error, {:corrupted_resume_state, missing}} = result
      assert :working_dir in missing

      assert_receive {:rejected, meta}, 500
      assert meta.agent_id == id
      assert :working_dir in meta.missing_fields
    end

    test "missing started_at + name → same rejection path" do
      id = "corrupt-both-#{:rand.uniform(100_000)}"

      bad_summary = %{
        id: id,
        # name MISSING
        # started_at MISSING
        last_activity_at: DateTime.utc_now(),
        status: :stopped,
        messages: []
      }

      :ets.insert(:chat_agents, {id, bad_summary})
      on_exit(fn -> :ets.delete(:chat_agents, id) end)

      Process.flag(:trap_exit, true)

      result = GenServer.start_link(ChatAgent, id: id, resume: true, backend: RecordingBackend)

      assert {:error, {:corrupted_resume_state, missing}} = result
      assert :name in missing
      assert :started_at in missing
    end

    test "valid summary → resumes cleanly" do
      id = "valid-resume-#{:rand.uniform(100_000)}"
      now = DateTime.utc_now()

      tmp_dir =
        Path.join(System.tmp_dir!(), "resume-valid-#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      summary = %{
        id: id,
        name: "valid",
        working_dir: tmp_dir,
        bind_mount: nil,
        workspace_id: nil,
        started_at: now,
        last_activity_at: now,
        status: :stopped,
        messages: []
      }

      :ets.insert(:chat_agents, {id, summary})

      on_exit(fn ->
        try do
          ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        :ets.delete(:chat_agents, id)
        File.rm_rf!(tmp_dir)
      end)

      {:ok, _pid} =
        Loopyard.TestHelpers.start_agent(
          id: id,
          name: "valid",
          working_dir: tmp_dir,
          backend: RecordingBackend,
          resume: true
        )

      case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
        [{pid, _}] ->
          state = :sys.get_state(pid)
          assert state.name == "valid"
          assert state.working_dir == tmp_dir

        [] ->
          flunk("agent didn't resume")
      end
    end

    test "resuming from a summary with a stale host bind_mount/host_access comes back clean (CONTAINMENT)" do
      # Regression: `resume_from_summary` does `struct(saved)` first, copying
      # EVERY saved field verbatim — including a bind_mount/host_access left
      # over from before the containment invariant existed. A later `struct/2`
      # call only overrides a specific field list; if bind_mount/host_access
      # aren't in it, the stale host path survives into the live state even
      # though the actual session was correctly forced container-only. This
      # proves the state agrees with the (safe) session: both come back nil/false.
      id = "stale-bind-#{:rand.uniform(100_000)}"
      now = DateTime.utc_now()

      tmp_dir =
        Path.join(System.tmp_dir!(), "resume-stale-#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      summary = %{
        id: id,
        name: "stale",
        working_dir: tmp_dir,
        # Stale host access from before the containment fix — must NOT survive.
        bind_mount: "/Users/someone/some-host-project",
        host_access: true,
        workspace_id: nil,
        started_at: now,
        last_activity_at: now,
        status: :stopped,
        messages: []
      }

      :ets.insert(:chat_agents, {id, summary})

      on_exit(fn ->
        try do
          ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        :ets.delete(:chat_agents, id)
        File.rm_rf!(tmp_dir)
      end)

      {:ok, _pid} =
        Loopyard.TestHelpers.start_agent(
          id: id,
          name: "stale",
          working_dir: tmp_dir,
          backend: RecordingBackend,
          resume: true
        )

      case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
        [{pid, _}] ->
          state = :sys.get_state(pid)
          assert state.bind_mount == nil
          assert state.host_access == false

        [] ->
          flunk("agent didn't resume")
      end
    end
  end
end
