defmodule Loopyard.ChatAgent.PlanLimitTest do
  @moduledoc """
  Account failover (#118). A plan limit belongs to the ACCOUNT: one agent's
  refusal is every sibling's, without a turn burned to learn it. An agent at
  its limit moves — only — to an account its own account's owner permitted,
  that holds a credential for its harness and isn't limited itself; the
  interrupted turn is re-driven exactly once; nothing ping-pongs; and with
  nowhere to go, one inbox item says so and settles when the limit clears.
  """
  use Loopyard.AgentCase

  alias Loopyard.Agent.Event
  alias Loopyard.{AccountLimits, ChatAgent, Notifications, Workstation}
  alias Loopyard.ChatAgent.PlanLimit
  alias Loopyard.TestSupport.RecordingBackend
  alias Loopyard.Workstation.Failover

  @moduletag timeout: 15_000

  setup do
    own_recording_backend()
    Application.put_env(:loopyard, :crash_backoff_base_ms, 0)
    Application.put_env(:loopyard, :pending_drain_settle_ms, 10)

    on_exit(fn ->
      Application.delete_env(:loopyard, :crash_backoff_base_ms)
      Application.delete_env(:loopyard, :pending_drain_settle_ms)
    end)

    %{a: account!("a"), b: account!("b")}
  end

  # RecordingBackend is a named Agent LINKED to whichever test started it; one
  # inherited from the previous module's test process dies under us once that
  # process's exit lands. Start our own, linked to this test.
  defp own_recording_backend do
    case Process.whereis(RecordingBackend) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)
        Process.unlink(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, _, _, _}, 1_000

      nil ->
        :ok
    end

    {:ok, _} = RecordingBackend.start_link()
  end

  # A workstation; `cred?` writes a Claude credential into its env store.
  defp account!(tag, cred? \\ true) do
    id = "pl#{tag}-#{System.unique_integer([:positive])}"
    :ok = Workstation.create(id)

    if cred? do
      File.write!(
        Path.join(Workstation.dir(id), "env.json"),
        Jason.encode!(%{"CLAUDE_CODE_OAUTH_TOKEN" => "test-token"})
      )
    end

    on_exit(fn -> File.rm_rf(Workstation.dir(id)) end)
    id
  end

  defp start!(identity) do
    id = "pl-agent-#{System.unique_integer([:positive])}"

    opts = [
      id: id,
      name: "Plan Limit Test",
      started_by: "test",
      backend: RecordingBackend,
      workstation_identity: identity
    ]

    # Only the FIRST agent of a test goes through start_agent/1: it
    # re-ensures the workspace, which restarts the group (taking any agent
    # already in it down) when its ServiceManager is gone, as it is here.
    {:ok, pid} =
      case Process.get(:pl_started) do
        nil ->
          Process.put(:pl_started, true)
          Loopyard.TestHelpers.start_agent(opts)

        _ ->
          Loopyard.WorkspaceGroup.start_agent(
            Process.get(:loopyard_test_module_workspace_id),
            Keyword.put(opts, :working_dir, module_workspace())
          )
      end

    ChatAgent.subscribe(id)

    on_exit(fn ->
      try do
        ChatAgent.stop_agent(id)
      catch
        :exit, _ -> :ok
      end

      Process.sleep(20)
    end)

    {id, pid}
  end

  # A turn in flight on `prompt`, refused by the plan.
  defp refuse!(pid, id, resets_at, prompt \\ "do the thing") do
    ref = make_ref()

    :sys.replace_state(pid, fn s ->
      user = %{
        id: "u-#{System.unique_integer([:positive])}",
        role: :user,
        content: prompt,
        timestamp: DateTime.utc_now()
      }

      %{s | stream_ref: ref, status: :thinking, messages: [user | s.messages]}
    end)

    send(
      pid,
      {:stream_event, id, ref,
       %Event.RateLimitStatus{
         status: :rejected,
         resets_at_ms: resets_at,
         rate_limit_type: "five_hour",
         utilization: 1.0
       }}
    )

    :sys.get_state(pid)
  end

  defp later(ms), do: System.system_time(:millisecond) + ms

  defp eventually(fun, tries \\ 150) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  defp lines(pid),
    do: pid |> :sys.get_state() |> Map.get(:messages, []) |> Enum.filter(&(&1[:role] == :system))

  defp limit_items(id) do
    Notifications.sync()
    Enum.filter(Notifications.all(), &(&1.agent_id == id and &1.kind == :plan_limit))
  end

  describe "the limit is the account's" do
    test "one agent's refusal holds a sibling's send without a turn, until the reset",
         %{a: a} do
      {id1, pid1} = start!(a)
      {id2, pid2} = start!(a)
      RecordingBackend.reset()

      refuse!(pid1, id1, later(400))
      assert AccountLimits.limited?(a, :claude)

      ChatAgent.send_message(id2, "hello sibling")
      state2 = :sys.get_state(pid2)

      assert state2.status == :rate_limited
      assert state2.pending_sends == ["hello sibling"]
      refute "hello sibling" in RecordingBackend.streamed_prompts()

      # The reset: the sibling drains its held message itself, and the
      # account forgets the limit.
      eventually(fn -> "hello sibling" in RecordingBackend.streamed_prompts() end)
      refute AccountLimits.limited?(a, :claude)
      eventually(fn -> :sys.get_state(pid1).status == :idle end)
    end

    test "an allowed turn on the account clears what a refusal taught it", %{a: a} do
      {id, pid} = start!(a)
      refuse!(pid, id, later(60_000))
      assert AccountLimits.limited?(a, :claude)

      ref = make_ref()
      :sys.replace_state(pid, &%{&1 | stream_ref: ref})
      send(pid, {:stream_event, id, ref, %Event.RateLimitStatus{status: :allowed}})
      :sys.get_state(pid)

      refute AccountLimits.limited?(a, :claude)
    end
  end

  describe "choosing where to go" do
    test "only a permitted, credentialed, unlimited account", %{a: a, b: b} do
      nocred = account!("n", false)
      limited = account!("l")
      AccountLimits.mark(limited, :claude, later(60_000))
      state = %{id: "x", workspace_id: "ws", workstation_identity: a, session_opts: []}

      # Off by default: nothing named, nowhere to go.
      assert PlanLimit.target(state) == nil

      :ok = Failover.put(a, [nocred, limited, b])
      assert PlanLimit.target(state) == b

      :ok = Failover.put(a, [nocred, limited])
      assert PlanLimit.target(state) == nil

      # A system agent's identity is where it lives.
      :ok = Failover.put(a, [b])
      assert PlanLimit.target(Map.put(state, :scope, :system)) == nil
    end
  end

  describe "failover" do
    test "moves to the permitted account, re-drives the interrupted prompt once, says so once",
         %{a: a, b: b} do
      :ok = Failover.put(a, [b])
      {id, pid} = start!(a)
      RecordingBackend.reset()

      test_pid = self()
      handler = "pl-#{id}"

      :telemetry.attach(
        handler,
        [:loopyard, :agent, :account_failover],
        fn _e, _m, meta, _ -> send(test_pid, {:failover, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      refuse!(pid, id, later(60_000))

      assert_receive {:failover, %{direction: :failover, from: ^a, to: ^b}}, 1_000
      eventually(fn -> RecordingBackend.starts() != [] end)
      assert :sys.get_state(pid).workstation_identity == b

      [opts | _] = Enum.reverse(RecordingBackend.starts())
      assert Keyword.get(opts, :workstation_identity) == b
      refute Keyword.has_key?(opts, :resume)

      # The interrupted turn runs on the new account — exactly once.
      eventually(fn -> "do the thing" in RecordingBackend.streamed_prompts() end)
      eventually(fn -> :sys.get_state(pid).status == :idle end)
      assert Enum.count(RecordingBackend.streamed_prompts(), &(&1 == "do the thing")) == 1

      # One quiet line, and not the "Hit your limit" one.
      contents = Enum.map(lines(pid), & &1.content)
      assert Enum.count(contents, &(&1 =~ "Moved to #{b} — #{a} is at its plan limit until")) == 1
      refute Enum.any?(contents, &(&1 =~ "Hit your"))
      assert limit_items(id) == []

      state = :sys.get_state(pid)
      assert state.failover_origin == a
      assert state.rate_limit_status == :ok

      # A stale second signal for the same refusal does nothing.
      starts = length(RecordingBackend.starts())
      send(pid, {:plan_limit_failover, id})
      :sys.get_state(pid)
      assert length(RecordingBackend.starts()) == starts
      refute_received {:failover, _}
    end

    test "no ping-pong: the account it left is still limited, so it stays and says so once",
         %{a: a, b: b} do
      :ok = Failover.put(a, [b])
      :ok = Failover.put(b, [a])
      {id, pid} = start!(a)

      refuse!(pid, id, later(60_000))
      eventually(fn -> :sys.get_state(pid).workstation_identity == b end)
      eventually(fn -> :sys.get_state(pid).status == :idle end)
      starts = length(RecordingBackend.starts())

      # Now B's plan runs out too. A is still limited: no move back.
      refuse!(pid, id, later(60_000))
      refuse!(pid, id, later(60_000))

      state = :sys.get_state(pid)
      assert state.workstation_identity == b
      assert state.status == :rate_limited
      assert length(RecordingBackend.starts()) == starts
      assert [%{status: :open, label: label}] = limit_items(id)
      assert label =~ "#{b}'s Claude Code plan limit"
    end

    test "goes home when the original account's window resets and the agent is idle",
         %{a: a, b: b} do
      :ok = Failover.put(a, [b])
      {id, pid} = start!(a)

      refuse!(pid, id, later(400))
      eventually(fn -> :sys.get_state(pid).workstation_identity == b end)

      eventually(fn -> :sys.get_state(pid).workstation_identity == a end)
      assert Enum.any?(lines(pid), &(&1.content == "Back on #{a} — its plan limit has reset."))
      refute Map.has_key?(:sys.get_state(pid), :failover_origin)
    end
  end

  describe "nowhere to go" do
    test "stays limited as before, raises ONE inbox item, settles it at the reset", %{a: a} do
      {id, pid} = start!(a)

      refuse!(pid, id, later(400))
      refuse!(pid, id, later(400))

      assert :sys.get_state(pid).status == :rate_limited
      assert Enum.any?(lines(pid), &(&1.content =~ "Hit your"))

      assert [%{status: :open, label: label, meta: %{account: ^a}}] = limit_items(id)
      assert label =~ "no permitted account can take the work"
      assert label =~ "open #{a}"

      eventually(fn -> :sys.get_state(pid).status == :idle end)
      eventually(fn -> match?([%{status: :settled}], limit_items(id)) end)
    end
  end

  describe "the chief of staff's overview" do
    test "shows each account's limit and its fallbacks", %{a: a, b: b} do
      :ok = Failover.put(a, [b])
      AccountLimits.mark(a, :claude, later(60_000))

      {:ok, text} = Loopyard.Tools.ControlPlane.Overview.execute(%{}, %{})

      # The first account's entry follows the "Accounts: " label on its line.
      [line] =
        text
        |> String.split(["\n", "; ", "Accounts: "])
        |> Enum.filter(&String.starts_with?(&1, a))

      assert line =~ "Claude Code limited until"
      assert line =~ "falls back to #{b}"
    end
  end
end
