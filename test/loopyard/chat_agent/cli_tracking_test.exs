defmodule Loopyard.ChatAgent.CliTrackingTest do
  @moduledoc """
  Surface #12 of plans/agent-sanity.md.

  The Claude CLI subprocess runs as a real OS process spawned by the
  SDK Session pid via a Port. If the ChatAgent GenServer crashes in
  a way that skips `terminate/2` (`:brutal_kill`, supervisor
  `:shutdown` timeout, node crash), the `claude` binary keeps running
  as an orphan — hogging RAM and burning API tokens against the
  account until manual cleanup.

  The fix: track the OS pid via `Loopyard.Resources.track/4` with
  the ChatAgent as owner. The Janitor monitors the owner and runs
  the release fn (SIGKILL the OS pid) when the owner goes DOWN,
  regardless of exit reason.

  This test proves:
    1. A newly-started agent has its CLI OS pid tracked in Resources
       under `kind: :claude_cli`.
    2. When we replace the session (restart paths), the old tracked
       pid is released and the new one is tracked.
    3. `terminate/2` no longer calls `OSProcess.kill` directly — the
       Janitor owns that responsibility.

  We use RecordingBackend rather than the real ClaudeCode backend
  because the real CLI needs auth + a real subprocess to spawn.
  Under RecordingBackend, `OSProcess.pid_of(session)` returns `nil`
  (the session is a plain Agent with no Port), so this test can't
  exercise the actual OS-pid-tracking path end-to-end. That
  integration-style assertion lives in the manual `mix loopyard.rpc`
  smoke test; here we focus on the tracking-discipline invariants:
  `state.tracked_cli_os_pid` follows session replacement, and the
  helper is called on every restart path.
  """

  use Loopyard.AgentCase

  alias Loopyard.ChatAgent
  alias Loopyard.TestSupport.RecordingBackend

  @moduletag timeout: 10_000

  setup do
    RecordingBackend.reset()

    id = "cli-track-test-#{:rand.uniform(100_000)}"

    {:ok, _pid} =
      Loopyard.TestHelpers.start_agent(
        id: id,
        name: "CLI Tracking Test",
        started_by: "test",
        backend: RecordingBackend
      )

    on_exit(fn ->
      try do
        ChatAgent.stop_agent(id)
      catch
        :exit, _ -> :ok
      end

      Process.sleep(20)
    end)

    %{id: id}
  end

  defp agent_pid(id) do
    case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  describe "track_cli_os_pid discipline" do
    test "initial state has no tracked os pid under RecordingBackend (pid_of/1 returns nil)",
         %{id: id} do
      # With the fake backend the session is a plain Agent process —
      # no Port, no Claude CLI, `OSProcess.pid_of/1` returns nil.
      # The invariant we want: state.tracked_cli_os_pid is nil in that
      # case, NOT a stale value carried over from somewhere else.
      pid = agent_pid(id)
      state = :sys.get_state(pid)
      assert state.tracked_cli_os_pid == nil
    end

    test "Resources.list_for_owner returns no :claude_cli entries under fake backend",
         %{id: id} do
      # Directly assert the Janitor has no :claude_cli entry for this
      # agent. Under a real backend with a live Port, we'd see one
      # entry here.
      pid = agent_pid(id)

      entries = Loopyard.Resources.list_for_owner(pid)
      refute Enum.any?(entries, &(&1.kind == :claude_cli))
    end

    test "stopping the agent doesn't leave :claude_cli entries dangling", %{id: id} do
      pid = agent_pid(id)

      # Stop cleanly.
      ChatAgent.stop_agent(id)
      Process.sleep(100)

      # Janitor should have released any tracked resources via DOWN.
      refute Process.alive?(pid)

      # No leftover entries for this dead owner in the global list.
      all = Loopyard.Resources.all()
      refute Enum.any?(all, fn e -> e.owner == pid and e.kind == :claude_cli end)
    end
  end

  describe "terminate/2 hardening" do
    test "terminate path no longer calls OSProcess.kill directly", %{id: id} do
      # Indirect assertion: we can't easily mock OSProcess.kill, but we
      # can assert the codepath succeeds without the kill call by
      # checking the module source. A literal grep would be fragile;
      # instead we check `terminate/2` does NOT mention `OSProcess.kill`.
      source =
        File.read!(
          __ENV__.file
          |> Path.dirname()
          |> Path.join("../../../lib/loopyard/chat_agent.ex")
        )

      # Extract the terminate/2 function body — bounded by `def terminate`
      # and the next top-level `def `/`defp `.
      terminate_body =
        source
        |> String.split(~r/\n  @impl true\n  def terminate\(_reason, state\) do/, parts: 2)
        |> List.last()
        |> String.split(~r/\n  # --- Private ---|\n  @impl true/, parts: 2)
        |> List.first()

      refute String.contains?(terminate_body, "OSProcess.kill"),
             "terminate/2 must not SIGKILL directly — Resources.Janitor does that on DOWN"

      # Sanity: the agent still terminates cleanly.
      pid = agent_pid(id)
      assert Process.alive?(pid)
      ChatAgent.stop_agent(id)
      Process.sleep(50)
      refute Process.alive?(pid)
    end
  end

  describe ":restart_session replaces tracked pid" do
    test "restart_session clears tracked_cli_os_pid when new session has no os pid",
         %{id: id} do
      pid = agent_pid(id)

      # Seed a fake "previously tracked" pid in state. Because the
      # fake backend's session has no OS pid, after restart the
      # tracked pid should reset to nil — confirming track_cli_os_pid
      # is called on the restart path and handles the nil-pid case.
      :sys.replace_state(pid, fn s -> Map.put(s, :tracked_cli_os_pid, 999_999) end)

      GenServer.cast(pid, :restart_session)
      Process.sleep(100)

      state = :sys.get_state(pid)
      assert state.tracked_cli_os_pid == nil
    end
  end
end
