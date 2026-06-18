defmodule Loopyard.TurnTest do
  use ExUnit.Case, async: true

  alias Loopyard.Turn

  describe "new/0" do
    test "starts on the human's turn with nothing queued" do
      assert %Turn{phase: :human, queue: [], blocked_on: nil} = Turn.new()
    end
  end

  describe ":send" do
    test "from :human starts the agent's turn" do
      assert {:ok, %Turn{phase: :agent, queue: []}, [{:start_turn, "hi"}]} =
               Turn.step(Turn.new(), {:send, "hi"})
    end

    test "from :agent parks the message in the queue (no stream pollution)" do
      t = %Turn{phase: :agent}
      assert {:ok, %Turn{phase: :agent, queue: ["a"]}, [{:queued, "a"}]} = Turn.step(t, {:send, "a"})
    end

    test "parks in order while the agent works" do
      t = %Turn{phase: :agent}
      {:ok, t, _} = Turn.step(t, {:send, "a"})
      {:ok, t, _} = Turn.step(t, {:send, "b"})
      assert t.queue == ["a", "b"]
    end

    test "from :agent_blocked parks too (answer is a separate event)" do
      t = %Turn{phase: :agent_blocked, blocked_on: %{kind: :question, id: 1, payload: %{}}}
      assert {:ok, %Turn{phase: :agent_blocked, queue: ["x"]}, [{:queued, "x"}]} =
               Turn.step(t, {:send, "x"})
    end
  end

  describe ":input_requested (agent yields mid-turn)" do
    test "question moves to :agent_blocked with a typed payload" do
      t = %Turn{phase: :agent}

      assert {:ok, %Turn{phase: :agent_blocked, blocked_on: %{kind: :question, id: "q1"}}, []} =
               Turn.step(t, {:input_requested, :question, "q1", %{prompt: "which?"}})
    end

    test "permission moves to :agent_blocked, same machine, different kind" do
      t = %Turn{phase: :agent}

      assert {:ok, %Turn{phase: :agent_blocked, blocked_on: %{kind: :permission, id: "p1"}}, []} =
               Turn.step(t, {:input_requested, :permission, "p1", %{tool: "rm"}})
    end

    test "is invalid when the agent doesn't hold the turn" do
      assert {:error, {:invalid_transition, :human, _}} =
               Turn.step(Turn.new(), {:input_requested, :question, "q", %{}})
    end
  end

  describe ":answer" do
    setup do
      {:ok,
       blocked: %Turn{phase: :agent_blocked, blocked_on: %{kind: :question, id: "q1", payload: %{}}}}
    end

    test "matching id resumes the turn and emits the harness reply", %{blocked: t} do
      assert {:ok, %Turn{phase: :agent, blocked_on: nil}, [{:answer_input, "q1", "yes"}]} =
               Turn.step(t, {:answer, "q1", "yes"})
    end

    test "stale id (a replaced/expired request) is rejected", %{blocked: t} do
      assert {:error, :stale_answer} = Turn.step(t, {:answer, "old", "yes"})
    end

    test "answering when not blocked is invalid" do
      assert {:error, {:invalid_transition, :agent, _}} =
               Turn.step(%Turn{phase: :agent}, {:answer, "q1", "yes"})
    end
  end

  describe ":turn_complete" do
    test "with an empty queue settles to the human's turn" do
      assert {:ok, %Turn{phase: :human, queue: []}, []} =
               Turn.step(%Turn{phase: :agent}, :turn_complete)
    end

    test "batch-drains a parked flurry into ONE framed next turn" do
      t = %Turn{phase: :agent, queue: ["first", "second", "third"]}

      assert {:ok, %Turn{phase: :agent, queue: []}, [{:start_turn, prompt}]} =
               Turn.step(t, :turn_complete)

      # Framed as an ordered sequence so later messages can refine earlier ones.
      assert prompt =~ "You sent 3 messages while I was working, in order:"
      assert prompt =~ "1. first"
      assert prompt =~ "2. second"
      assert prompt =~ "3. third"
      assert prompt =~ "later ones may refine or correct earlier ones"
    end

    test "a single parked message drains as-is (no framing)" do
      t = %Turn{phase: :agent, queue: ["just one"]}
      assert {:ok, %Turn{phase: :human, queue: []}, []} = Turn.step(%{t | queue: []}, :turn_complete)
      assert {:ok, _, [{:start_turn, "just one"}]} = Turn.step(t, :turn_complete)
    end

    test "completing while blocked clears the block and settles" do
      t = %Turn{phase: :agent_blocked, blocked_on: %{kind: :question, id: 1, payload: %{}}}
      assert {:ok, %Turn{phase: :human, blocked_on: nil}, []} = Turn.step(t, :turn_complete)
    end

    test "is invalid on the human's turn" do
      assert {:error, {:invalid_transition, :human, :turn_complete}} =
               Turn.step(Turn.new(), :turn_complete)
    end
  end

  describe ":interrupt (Stop)" do
    test "from :agent cancels the turn, drops the queue, hands control back" do
      t = %Turn{phase: :agent, queue: ["x", "y"]}
      assert {:ok, %Turn{phase: :human, queue: [], blocked_on: nil}, [:cancel_turn]} =
               Turn.step(t, :interrupt)
    end

    test "from :agent_blocked also cancels" do
      t = %Turn{phase: :agent_blocked, blocked_on: %{kind: :permission, id: 1, payload: %{}}}
      assert {:ok, %Turn{phase: :human, blocked_on: nil}, [:cancel_turn]} =
               Turn.step(t, :interrupt)
    end

    test "is invalid on the human's turn (nothing to interrupt)" do
      assert {:error, {:invalid_transition, :human, :interrupt}} =
               Turn.step(Turn.new(), :interrupt)
    end
  end

  describe "queue management (any phase)" do
    test "clear_queue empties the queue without changing the phase" do
      t = %Turn{phase: :agent, queue: ["a", "b"]}
      assert {:ok, %Turn{phase: :agent, queue: []}, []} = Turn.step(t, :clear_queue)
    end

    test "remove_queued drops one by index" do
      t = %Turn{phase: :agent, queue: ["a", "b", "c"]}
      assert {:ok, %Turn{queue: ["a", "c"]}, []} = Turn.step(t, {:remove_queued, 1})
    end

    test "remove_queued out of range is a no-op" do
      t = %Turn{phase: :agent, queue: ["a"]}
      assert {:ok, %Turn{queue: ["a"]}, []} = Turn.step(t, {:remove_queued, 9})
    end
  end

  describe "full scenarios" do
    test "ask → answer → complete round-trip" do
      effects = run(Turn.new(), [
        {:send, "build it"},
        {:input_requested, :permission, "p1", %{tool: "write"}},
        {:answer, "p1", :approve},
        :turn_complete
      ])

      assert {:start_turn, "build it"} in effects
      assert {:answer_input, "p1", :approve} in effects
      # ends back on the human's turn
      {final, _} = run_state(Turn.new(), [
        {:send, "build it"},
        {:input_requested, :permission, "p1", %{tool: "write"}},
        {:answer, "p1", :approve},
        :turn_complete
      ])

      assert final.phase == :human
    end

    test "a flurry mid-turn drains as one batched turn after completion" do
      {final, effects} = run_state(Turn.new(), [
        {:send, "go"},
        {:send, "also this"},
        {:send, "and this"},
        :turn_complete
      ])

      # one initial turn + one batched, framed drain
      starts = Enum.filter(effects, &match?({:start_turn, _}, &1))
      assert [{:start_turn, "go"}, {:start_turn, batched}] = starts
      assert batched =~ "1. also this"
      assert batched =~ "2. and this"
      assert final.phase == :agent
      assert final.queue == []
    end

    test "interrupt mid-flurry drops everything and yields to the human" do
      {final, _} = run_state(Turn.new(), [
        {:send, "go"},
        {:send, "queued"},
        :interrupt
      ])

      assert final.phase == :human
      assert final.queue == []
    end
  end

  # --- helpers: fold a list of events, collecting effects / final state ---

  defp run(turn, events) do
    {_state, effects} = run_state(turn, events)
    effects
  end

  defp run_state(turn, events) do
    Enum.reduce(events, {turn, []}, fn event, {t, acc} ->
      case Turn.step(t, event) do
        {:ok, t2, effects} -> {t2, acc ++ effects}
        {:error, _} -> {t, acc}
      end
    end)
  end
end
