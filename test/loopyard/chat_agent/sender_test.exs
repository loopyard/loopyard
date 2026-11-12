defmodule Loopyard.ChatAgent.SenderTest do
  @moduledoc """
  A message another agent (or Loopyard itself) sends into an agent's inbox is
  NOT the human speaking. It must never be delivered as the human's answer to
  a decision the agent parked on them — the chief of staff dispatching "carry
  on" used to resolve the card it was supposed to surface — and it is recorded
  with its sender so the chat doesn't show it under the human's name.
  """
  use Loopyard.AgentCase

  alias Loopyard.ChatAgent
  alias Loopyard.ChatAgent.Thread
  alias Loopyard.Harness.QuestionAdapter.ClaudeCode
  alias Loopyard.Harness.Questions
  alias Loopyard.TestSupport.RecordingBackend

  @moduletag timeout: 10_000

  setup do
    RecordingBackend.reset()
    id = "sender-test-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Loopyard.TestHelpers.start_agent(
        id: id,
        name: "Sender Test",
        started_by: "test",
        backend: RecordingBackend
      )

    on_exit(fn ->
      try do
        ChatAgent.stop_agent(id)
      catch
        :exit, _ -> :ok
      end
    end)

    %{id: id, pid: pid}
  end

  defp park_on_question(id, pid) do
    {:ok, questions} =
      ClaudeCode.parse([%{"question" => "Ship it?", "options" => [%{"label" => "Yes"}]}])

    task = Task.async(fn -> Questions.ask(id, questions) end)

    assert Enum.any?(1..100, fn _ ->
             Questions.pending_for_agent?(id) or (Process.sleep(10) && false)
           end)

    # A live ask parks the turn INSIDE the tool call: the agent is mid-turn.
    :sys.replace_state(pid, fn s -> %{s | status: :thinking} end)
    task
  end

  test "a dispatched message does not answer the human's pending decision", %{id: id, pid: pid} do
    task = park_on_question(id, pid)

    assert :ok =
             ChatAgent.enqueue_message(
               id,
               Thread.tag_from("carry on with the plan", "chief-of-staff")
             )

    # Still the human's to answer…
    assert Questions.pending_for_agent?(id)
    assert Task.yield(task, 150) == nil
    # …and the message waits its turn in the queue instead of being swallowed.
    assert :sys.get_state(pid).pending_sends == [
             Thread.tag_from("carry on with the plan", "chief-of-staff")
           ]

    # The human's own words still do answer it.
    assert :ok = ChatAgent.enqueue_message(id, "yes, ship it")
    assert {:ok, %{"q0" => ["yes, ship it"]}} = Task.await(task, 2_000)
  end

  test "a machine-sent recovery note doesn't answer it either", %{id: id, pid: pid} do
    task = park_on_question(id, pid)

    note =
      Thread.tag_from("Docker was restarted — bring the services up.", Thread.system_sender())

    assert :ok = ChatAgent.enqueue_message(id, note)
    assert Questions.pending_for_agent?(id)
    assert Task.yield(task, 150) == nil

    Questions.answer_with_text(id, "later")
    assert {:ok, _} = Task.await(task, 2_000)
  end

  test "an idle agent takes it as a turn, recorded with its sender and framed for the model",
       %{id: id, pid: pid} do
    assert :ok = ChatAgent.enqueue_message(id, Thread.tag_from("run the suite", "chief-of-staff"))

    state = :sys.get_state(pid)

    assert %{role: :user, content: "run the suite", from: "chief-of-staff"} =
             Enum.find(state.messages, &(&1[:role] == :user))

    # The model got the framing, not the raw marker.
    [prompt | _] = Agent.get(RecordingBackend, & &1.streamed)
    text = if is_binary(prompt), do: prompt, else: inspect(prompt)
    assert text =~ "NOT typed by the user"
    assert text =~ "run the suite"
    refute text =~ "[[from:"
  end
end
