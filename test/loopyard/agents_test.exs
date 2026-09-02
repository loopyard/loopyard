defmodule Loopyard.AgentsTest do
  @moduledoc """
  The system-agent registry: the operator migrates in place (id + history
  kept), a fresh identity gets an "Operator" stamped from the system template
  through the boot saga, several system agents coexist, and a restart brings
  them back from the identity's agents log.
  """
  use ExUnit.Case, async: false

  alias Loopyard.{AgentLog, Agents, Workstation}
  alias Loopyard.Agents.SystemGroup

  setup do
    Loopyard.StateKeeper.ensure_tables!()
    identity = "agt-#{System.unique_integer([:positive])}"
    File.mkdir_p!(Workstation.dir(identity))

    on_exit(fn ->
      for %{id: id} <- Agents.system(identity) do
        if pid = registry_pid(id), do: GenServer.stop(pid, :normal, 5_000)
        :ets.delete(:chat_agents, id)
      end

      if pid = SystemGroup.whereis(identity), do: Supervisor.stop(pid, :normal)
      File.rm_rf!(Workstation.dir(identity))
    end)

    {:ok, identity: identity}
  end

  defp registry_pid(id) do
    case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(50) && wait_until(fun, tries - 1)
    end
  end

  test "the pre-registry operator migrates: same id, same transcript, stamped system",
       %{identity: identity} do
    dir = Workstation.dir(identity)
    File.write!(Path.join(dir, "operator.json"), Jason.encode!(%{"agent_id" => "op-legacy"}))
    old_log = Path.join(dir, "operator-agent.log")
    now = DateTime.utc_now()

    AgentLog.append(
      {:agent, "op-legacy",
       %{
         id: "op-legacy",
         name: "Operator",
         working_dir: dir,
         workspace_id: nil,
         container: "loopyard-ws-#{identity}",
         workstation_identity: identity,
         started_at: now,
         status: :idle
       }},
      log_path: old_log,
      version: 1
    )

    for i <- 1..2 do
      AgentLog.append(
        {:msg, "op-legacy", %{id: "m#{i}", role: :user, content: "hello #{i}", timestamp: now}},
        log_path: old_log,
        version: 1
      )
    end

    assert Agents.restore(identity) == 1
    refute File.exists?(old_log)
    assert File.exists?(Agents.log_path(identity))
    assert Agents.default_id(identity) == "op-legacy"

    row = Agents.get("op-legacy")
    assert row.scope == :system
    assert row.template_id == "system"
    assert row.workstation_identity == identity
    assert length(row.messages) == 2
    assert Agents.scope_key(row) == {:system, identity}

    assert Agents.attachment_target("op-legacy") ==
             {:container, "loopyard-ws-#{identity}", "/home/#{identity}"}

    # Idempotent: a second restore neither duplicates nor re-migrates.
    assert Agents.restore(identity) == 1
  end

  @tag timeout: 60_000
  test "a fresh identity gets an Operator stamped from the system template, booted by the saga",
       %{identity: identity} do
    assert Agents.default_id(identity) == nil
    assert {:ok, %{agent_id: id}} = Agents.ensure_default(identity)
    assert Agents.default_id(identity) == id

    wait_until(fn -> match?(%{status: :idle}, Agents.get(id)) end)

    row = Agents.get(id)
    assert row.name == "Operator"
    assert row.scope == :system
    assert row.template_id == "system"
    assert row.workspace_id == nil
    assert row.container == "fake-ws-" <> identity
    assert Agents.alive?(id)
    assert SystemGroup.whereis(identity)

    # Its log is the identity's agents log, written through the group's Checkpointer.
    assert [{_, _}] = Registry.lookup(Loopyard.AgentLog.CheckpointerRegistry, {:system, identity})

    # Ensuring again is a no-op on a live agent.
    assert {:ok, %{agent_id: ^id}} = Agents.ensure_default(identity)
  end

  @tag timeout: 60_000
  test "several system agents coexist with distinct ids and deduped names", %{identity: identity} do
    assert {:ok, a} = Agents.create_system(workstation_identity: identity)
    assert {:ok, b} = Agents.create_system(workstation_identity: identity)
    assert a != b

    wait_until(fn ->
      match?(%{status: :idle}, Agents.get(a)) and match?(%{status: :idle}, Agents.get(b))
    end)

    names = Agents.system(identity) |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ["System", "System 2"]
    assert Enum.all?(Agents.summaries() |> Enum.take(2), &(Agents.scope(&1) == :system))
  end

  @tag timeout: 60_000
  test "a stopped system agent comes back via ensure_running/1 with its transcript",
       %{identity: identity} do
    assert {:ok, %{agent_id: id}} = Agents.ensure_default(identity)
    wait_until(fn -> match?(%{status: :idle}, Agents.get(id)) end)

    :ok = Loopyard.ChatAgent.enqueue_message(id, "remember me")
    wait_until(fn -> Enum.any?(Agents.get(id).messages, &(&1[:content] == "remember me")) end)

    GenServer.stop(registry_pid(id), :normal, 5_000)
    wait_until(fn -> not Agents.alive?(id) end)

    assert :ok = Agents.ensure_running(id)
    wait_until(fn -> Agents.alive?(id) end)
    assert Enum.any?(Agents.get(id).messages, &(&1[:content] == "remember me"))
  end
end
