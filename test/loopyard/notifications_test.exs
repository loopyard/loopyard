defmodule Loopyard.NotificationsTest do
  @moduledoc """
  The inbox store: a decision card raised through the message funnel becomes
  an open item; its status flip settles it; both are broadcast; the log
  replays; the attention line is a read of it.
  """
  use ExUnit.Case, async: false

  alias Loopyard.Notifications
  alias Loopyard.Notifications.{Item, Log, Priority}
  alias Loopyard.ChatAgent.MessageWindow

  setup do
    Loopyard.StateKeeper.ensure_tables!()
    aid = "notif-test-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    # A bare ETS agent row: the funnels write to it when no GenServer runs.
    :ets.insert(:chat_agents, {aid, %{id: aid, name: "Tester", workspace_id: nil, messages: []}})

    on_exit(fn ->
      :ets.delete(:chat_agents, aid)

      for %Item{agent_id: ^aid, id: id} <- Notifications.all(),
          do: :ets.delete(:notifications, id)
    end)

    {:ok, aid: aid}
  end

  defp question(qid) do
    %{
      role: :question,
      status: :pending,
      question_id: qid,
      questions: [%{id: "q1", prompt: "Where should this repo live?"}],
      timestamp: DateTime.utc_now()
    }
  end

  test "a question card appended through the funnel is an open item; its answer settles it",
       %{aid: aid} do
    Loopyard.Events.Notifications.subscribe()
    qid = "q-" <> aid

    msg = MessageWindow.append_message_ets(aid, question(qid))
    Notifications.sync()

    assert %Item{
             kind: :question,
             status: :open,
             agent_id: ^aid,
             label: "Where should this repo live?"
           } =
             Notifications.get(qid)

    assert_receive %Loopyard.Events.Notifications.Added{item: %Item{id: ^qid}}
    assert Enum.any?(Notifications.open(:decisions), &(&1.id == qid))

    MessageWindow.update_message_now(aid, msg.id, %{status: :answered})
    Notifications.sync()

    assert %Item{status: :settled, outcome: :answered, settled_at: %DateTime{}} =
             Notifications.get(qid)

    assert_receive %Loopyard.Events.Notifications.Changed{item: %Item{id: ^qid}, from: :open}
    refute Enum.any?(Notifications.open(), &(&1.id == qid))
  end

  test "the attention line is a read of the store, same item shape", %{aid: aid} do
    qid = "q-line-" <> aid
    msg = MessageWindow.append_message_ets(aid, question(qid))
    Notifications.sync()

    item = Enum.find(Loopyard.Attention.line(), &(&1.id == qid))

    assert %{kind: :question, agent_id: ^aid, agent_name: "Tester", path: "/agents/" <> ^aid} =
             item

    assert item.msg.id == msg.id
    assert %DateTime{} = item.asked_at
    assert Loopyard.Attention.count() >= 1
  end

  test "the reconcile sweep raises a pending card that bypassed the funnel and settles a stale item",
       %{aid: aid} do
    qid = "q-recon-" <> aid
    # Card written straight into ETS — no funnel call.
    [{^aid, row}] = :ets.lookup(:chat_agents, aid)

    :ets.insert(
      :chat_agents,
      {aid, %{row | messages: row.messages ++ [Map.put(question(qid), :id, "m-" <> qid)]}}
    )

    Notifications.reconcile()
    Notifications.sync()
    assert %Item{status: :open} = Notifications.get(qid)

    # The card flips behind the store's back; the sweep settles the item.
    [{^aid, row}] = :ets.lookup(:chat_agents, aid)

    msgs =
      Enum.map(row.messages, &if(&1[:question_id] == qid, do: %{&1 | status: :timeout}, else: &1))

    :ets.insert(:chat_agents, {aid, %{row | messages: msgs}})

    Notifications.reconcile()
    Notifications.sync()
    assert %Item{status: :settled, outcome: :timeout} = Notifications.get(qid)
  end

  test "a workspace agent's turn end raises ONE finished item, replaced by the next, cleared by work",
       %{aid: aid} do
    Loopyard.Events.Notifications.subscribe()

    turn_end = fn summary ->
      Loopyard.Events.Activity.publish(%Loopyard.Events.Activity.Event{
        agent_id: aid,
        agent_name: "Tester",
        workspace_id: "ws-" <> aid,
        project_id: nil,
        kind: :turn_end,
        summary: summary,
        at: DateTime.utc_now()
      })
    end

    turn_end.("Wired the images in.")
    Notifications.sync()
    fid = "fin:" <> aid

    assert %Item{kind: :finished, status: :open, label: "Wired the images in."} =
             Notifications.get(fid)

    assert_receive %Loopyard.Events.Notifications.Added{item: %Item{id: ^fid}}

    turn_end.("Fixed the creds bag.")
    Notifications.sync()
    assert %Item{status: :open, label: "Fixed the creds bag."} = Notifications.get(fid)
    assert Enum.count(Notifications.open([:finished]), &(&1.agent_id == aid)) == 1

    # Nothing to say and nothing changed: not an item (the summary stays).
    turn_end.("")
    Notifications.sync()
    assert %Item{label: "Fixed the creds bag."} = Notifications.get(fid)

    Loopyard.Events.Activity.publish(%Loopyard.Events.Activity.Event{
      agent_id: aid,
      workspace_id: "ws-" <> aid,
      kind: :status,
      summary: "thinking",
      at: DateTime.utc_now()
    })

    Notifications.sync()
    assert %Item{status: :settled, outcome: :resumed} = Notifications.get(fid)

    refute Enum.any?(Loopyard.Attention.line(), &(&1.id == fid)),
           "finished items are not decisions"
  end

  test "the turn summary is the last assistant paragraph's first sentence, clipped on a word" do
    alias Loopyard.ChatAgent.TurnSummary

    msgs = [
      %{role: :user, content: "go"},
      %{role: :assistant, content: "## Done\n\nI **wired** the images in. Next I'd add the key."},
      %{role: :tool, content: "ignored"}
    ]

    assert TurnSummary.of_transcript(msgs) == "I wired the images in."
    assert TurnSummary.of_messages(Enum.reverse(msgs)) == "I wired the images in."
    assert TurnSummary.of_transcript([%{role: :user, content: "x"}]) == nil

    long = %{role: :assistant, content: String.duplicate("word ", 60) <> "end"}
    s = TurnSummary.of_transcript([long])
    assert String.ends_with?(s, "…") and byte_size(s) <= TurnSummary.max() + 3
  end

  test "retract withdraws the card mid-ask: the blocked ask returns, the card says why",
       %{aid: aid} do
    # A real blocked ask, the way the harness does it.
    task =
      Task.async(fn ->
        Loopyard.Harness.Questions.ask(aid, [
          %{id: "q1", prompt: "Public or private?", options: []}
        ])
      end)

    qid =
      wait_for(fn ->
        Enum.find_value(Notifications.open(:decisions), &(&1.agent_id == aid and &1.id))
      end)

    Notifications.retract(qid, "the repo was made public in the meantime")
    assert {:ok, %{}} = Task.await(task, 2_000)
    Notifications.sync()

    assert %Item{status: :retracted, outcome: "the repo was made public in the meantime"} =
             Notifications.get(qid)

    [{^aid, row}] = :ets.lookup(:chat_agents, aid)
    card = Enum.find(row.messages, &(&1[:question_id] == qid))
    assert card.status == :retracted
    assert card.retract_reason =~ "made public"
  end

  defp wait_for(fun, tries \\ 50) do
    case fun.() do
      nil when tries > 0 ->
        Process.sleep(20)
        wait_for(fun, tries - 1)

      val ->
        val
    end
  end

  test "inbox order: approvals before questions before secrets, newest first within a tier" do
    now = DateTime.utc_now()
    at = fn secs -> DateTime.add(now, -secs, :second) end

    items = [
      %Item{id: "s", kind: :secret, raised_at: at.(10)},
      %Item{id: "q-old", kind: :question, raised_at: at.(100)},
      %Item{id: "a", kind: :approval, raised_at: at.(500)},
      %Item{id: "q-new", kind: :question, raised_at: at.(1)},
      %Item{id: "pinned", kind: :secret, raised_at: at.(900), priority: :pinned}
    ]

    assert Enum.map(Priority.order(items), & &1.id) == ["pinned", "a", "q-new", "q-old", "s"]
  end

  test "the log replays the newest record per id and a snapshot resets it" do
    tmp = Path.join(System.tmp_dir!(), "notif-log-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = System.get_env("LOOPYARD_HOME")
    System.put_env("LOOPYARD_HOME", tmp)
    Application.put_env(:loopyard, :notifications_log?, true)

    try do
      a = %Item{id: "a", kind: :question, raised_at: DateTime.utc_now()}
      Log.append(a)
      Log.append(%{a | status: :settled, outcome: :answered})
      Log.append(%Item{id: "b", kind: :approval, raised_at: DateTime.utc_now()})

      assert {%{"a" => %Item{status: :settled}, "b" => %Item{status: :open}}, 3} = Log.replay()

      Log.compact([%Item{id: "b", kind: :approval, raised_at: DateTime.utc_now()}])
      assert {%{"b" => _} = items, 1} = Log.replay()
      refute Map.has_key?(items, "a")
    after
      Application.put_env(:loopyard, :notifications_log?, false)
      if prev, do: System.put_env("LOOPYARD_HOME", prev), else: System.delete_env("LOOPYARD_HOME")
      File.rm_rf!(tmp)
    end
  end
end
