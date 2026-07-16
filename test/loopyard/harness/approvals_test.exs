defmodule Loopyard.Harness.ApprovalsTest do
  use ExUnit.Case, async: false

  alias Loopyard.Harness.Approvals

  setup do
    Loopyard.StateKeeper.ensure_tables!()
    :ok
  end

  test "request blocks until decided, returns the decision + msg_id" do
    action = %{verb: :fork, project_id: "p1", base: "main", branch: "feature", reason: "try it"}
    task = Task.async(fn -> Approvals.request("appr-test-agent", action) end)

    id = wait_for_pending()
    assert Approvals.pending?(id)

    assert :ok = Approvals.decide(id, :approve)
    assert {:approve, _msg_id} = Task.await(task, 2_000)
    refute Approvals.pending?(id)
  end

  test "deny round-trips" do
    task =
      Task.async(fn -> Approvals.request("appr-test-agent2", %{verb: :fork, branch: "x"}) end)

    id = wait_for_pending()
    assert :ok = Approvals.decide(id, :deny)
    assert {:deny, _} = Task.await(task, 2_000)
  end

  test "deciding an unknown proposal is a clean error" do
    assert {:error, :not_found} = Approvals.decide("nope-#{System.unique_integer()}", :approve)
  end

  describe "dead-waiter guard" do
    test "decide after the waiter died returns {:error, :not_found} and doesn't crash" do
      agent = "appr-dead-agent-#{System.unique_integer([:positive])}"

      {pid, ref} =
        spawn_monitor(fn -> Approvals.request(agent, %{verb: :fork, branch: "x"}) end)

      id = wait_for_pending()
      assert Approvals.pending?(id)

      # Kill the waiter — the receive in request/2 never delivers, entry leaks.
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

      # The decision can't reach a dead pid — reap + clean error, no crash.
      assert {:error, :not_found} = Approvals.decide(id, :approve)
      refute Approvals.pending?(id)
    end

    test "pending_for_agent? reflects liveness and reaps a dead waiter" do
      agent = "appr-live-agent-#{System.unique_integer([:positive])}"

      {pid, ref} =
        spawn_monitor(fn -> Approvals.request(agent, %{verb: :fork, branch: "y"}) end)

      id = wait_for_pending()
      # Live waiter → reported pending.
      assert Approvals.pending_for_agent?(agent)

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

      # Dead waiter → reaped on the liveness check.
      refute Approvals.pending_for_agent?(agent)
      refute Approvals.pending?(id)
    end
  end

  describe "queued model (post + run)" do
    test "post/2 returns immediately and registers NO blocking waiter (no TTL)" do
      agent = "appr-queued-#{System.unique_integer([:positive])}"
      action = %{verb: :delete_workspace, workspace_id: "w1", project_id: "p1"}

      before = length(:ets.tab2list(:harness_approvals))

      # Unlike request/2, post/2 does not block — it returns right away.
      assert :ok = Approvals.post(agent, action)

      # ...and it registers NO waiter, so there's nothing that can time out. This
      # is the whole point of the queued model: the decision lives in the durable
      # card, not a blocked process on a 30-min clock.
      assert length(:ets.tab2list(:harness_approvals)) == before
    end

    test "run/3 with an unknown verb is a clean no-op" do
      assert :ok = Approvals.run("a", "m", %{verb: :bogus})
    end
  end

  defp wait_for_pending(tries \\ 50) do
    case :ets.tab2list(:harness_approvals) do
      [{id, _} | _] ->
        id

      [] when tries > 0 ->
        Process.sleep(10)
        wait_for_pending(tries - 1)
    end
  end
end
