defmodule Loopyard.ChatAgent.WorkstationIdentityTest do
  # async: false — touches the :chat_agents ETS table + LOOPYARD_HOME (current/0).
  use ExUnit.Case, async: false

  alias Loopyard.ChatAgent
  alias Loopyard.Workstation

  setup do
    Loopyard.StateKeeper.ensure_tables!()

    prev = System.get_env("LOOPYARD_HOME")
    tmp = Path.join(System.tmp_dir!(), "loopyard-test-#{System.unique_integer([:positive])}")
    System.put_env("LOOPYARD_HOME", tmp)
    :ok = Workstation.create("brad")
    :ok = Workstation.set_current("brad")

    on_exit(fn ->
      if prev, do: System.put_env("LOOPYARD_HOME", prev), else: System.delete_env("LOOPYARD_HOME")
      File.rm_rf(tmp)
    end)

    :ok
  end

  defp uid, do: "wsid-test-#{System.unique_integer([:positive])}"

  test "a booting agent is stamped with the identity you're operating as" do
    summary = ChatAgent.register_booting(uid(), "T", "/tmp/x", workspace_id: "ws1")
    assert summary.workstation_identity == "brad"
  end

  test "an explicit :workstation_identity opt wins over current/0" do
    :ok = Workstation.create("jamie")
    summary = ChatAgent.register_booting(uid(), "T", "/tmp/x", workspace_id: "ws1", workstation_identity: "jamie")
    assert summary.workstation_identity == "jamie"
  end

  test "the stamp persists into the ETS summary (so list/count can read it)" do
    id = uid()
    _ = ChatAgent.register_booting(id, "T", "/tmp/x", workspace_id: "ws1")
    summary = ChatAgent.get_state(id)
    assert summary.workstation_identity == "brad"
  end
end
