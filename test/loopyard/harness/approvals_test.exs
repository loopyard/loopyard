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
