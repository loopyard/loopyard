defmodule Loopyard.Operator.DigestTest do
  @moduledoc """
  The operator's completion digest — the bounded ring the `recent_activity`
  tool reads — and the watch reactions that turn an agent's idle/awaiting/exit
  into a wake for the operator. The GenServer is config-gated OFF in test, so
  these drive its callbacks directly with the state shape `init/1` builds.
  """
  use ExUnit.Case, async: false

  alias Loopyard.Events.Activity.Event
  alias Loopyard.Operator.Digest

  setup do
    :ets.delete_all_objects(:operator_digest)
    on_exit(fn -> :ets.delete_all_objects(:operator_digest) end)
    {:ok, state} = Digest.init([])
    %{state: state}
  end

  defp idle(agent_id, opts \\ []) do
    %Event{
      kind: :status,
      agent_id: agent_id,
      agent_name: Keyword.get(opts, :name, "Claude"),
      workspace_id: Keyword.get(opts, :workspace_id, "ws-1"),
      project_id: Keyword.get(opts, :project_id, "p-1"),
      summary: Keyword.get(opts, :summary, "idle"),
      at: DateTime.utc_now()
    }
  end

  describe "the digest ring" do
    test "an agent going idle lands as one entry, newest first", %{state: state} do
      {:noreply, state} = Digest.handle_info(idle("a1", name: "Alpha"), state)
      {:noreply, _state} = Digest.handle_info(idle("a2", name: "Beta"), state)

      assert [%{agent_name: "Beta"}, %{agent_name: "Alpha", workspace_id: "ws-1"}] =
               Digest.recent(10)
    end

    test "a repeated idle from the same agent (no new turn) is not a new entry", %{state: state} do
      {:noreply, state} = Digest.handle_info(idle("a1"), state)
      {:noreply, _} = Digest.handle_info(idle("a1"), state)
      assert length(Digest.recent(10)) == 1
    end

    test "only idle counts; thinking/awaiting and workspace-less agents are not digested",
         %{state: state} do
      {:noreply, state} = Digest.handle_info(idle("a1", summary: "thinking"), state)
      {:noreply, state} = Digest.handle_info(idle("a1", summary: "awaiting"), state)
      {:noreply, _} = Digest.handle_info(idle("op", workspace_id: nil), state)
      assert Digest.recent(10) == []
    end

    test "the ring is bounded and recent/1 honours its limit", %{state: state} do
      state =
        Enum.reduce(1..120, state, fn i, st ->
          {:noreply, st} = Digest.handle_info(idle("agent-#{i}"), st)
          st
        end)

      assert state.seq == 120
      assert length(:ets.tab2list(:operator_digest)) == 100
      assert [%{agent_id: "agent-120"} | _] = Digest.recent(3)
      assert length(Digest.recent(3)) == 3
    end

    test "an agent with no live state reads as 'finished a turn'", %{state: state} do
      {:noreply, _} = Digest.handle_info(idle("ghost"), state)
      assert [%{summary: "finished a turn"}] = Digest.recent(1)
    end
  end

  describe "watches" do
    test "arming a watch monitors the agent and shows up in watches/0", %{state: state} do
      agent = spawn(fn -> Process.sleep(:infinity) end)
      Registry.register(Loopyard.ChatAgentRegistry, "w-agent", nil)

      {:noreply, state} = Digest.handle_cast({:watch, "ws-1", "w-agent", "op-1", "fix CI"}, state)
      assert %{"w-agent" => %{operator_id: "op-1", name: "fix CI", ws_id: "ws-1"}} = state.watches
      Process.exit(agent, :kill)
    end

    test "an unknown agent's idle with no watch is a no-op for watches", %{state: state} do
      {:noreply, state} = Digest.handle_info(idle("nobody"), state)
      assert state.watches == %{}
      assert state.pending == %{}
    end

    test "the watched agent going idle resolves the watch and stashes a wake for a busy operator",
         %{state: state} do
      {:noreply, state} = Digest.handle_cast({:watch, "ws-1", "w1", "op-1", "fix CI"}, state)
      {:noreply, state} = Digest.handle_info(idle("w1"), state)

      # No live operator to deliver to → the wake waits in `pending`.
      assert state.watches == %{}
      assert [text] = state.pending["op-1"]
      assert text =~ "fix CI"
    end

    test "the watched agent asking a question surfaces along the way but keeps the watch",
         %{state: state} do
      {:noreply, state} = Digest.handle_cast({:watch, "ws-1", "w1", "op-1", "fix CI"}, state)
      {:noreply, state} = Digest.handle_info(idle("w1", summary: "awaiting"), state)

      assert Map.has_key?(state.watches, "w1")
      assert [text] = state.pending["op-1"]
      assert text =~ "fix CI"
    end

    test "unknown messages never crash the server", %{state: state} do
      assert {:noreply, ^state} = Digest.handle_info(:whatever, state)
      assert {:noreply, ^state} = Digest.handle_cast(:whatever, state)
    end
  end
end
