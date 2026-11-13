defmodule LoopyardWeb.AgentLiveTest do
  # async: false — mounts a real agent surface against shared registries.
  use LoopyardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    Loopyard.StateKeeper.ensure_tables!()
    id = "al-#{System.unique_integer([:positive])}"

    :ets.insert(
      :chat_agents,
      {id,
       %{
         id: id,
         name: "Ops",
         status: :idle,
         scope: :system,
         template_id: "system",
         workstation_identity: "al-ident",
         workspace_id: nil,
         messages: [],
         pending_messages: []
       }}
    )

    on_exit(fn -> :ets.delete(:chat_agents, id) end)
    {:ok, id: id}
  end

  test "mounts one agent's chat under its name, with the mode nav", %{conn: conn, id: id} do
    {:ok, view, html} = live(conn, "/agents/#{id}")
    assert html =~ "Ops"
    # The label carries the waiting count when the inbox isn't empty ("Notifications
    # — 2 waiting"), and other tests' items share the store.
    assert has_element?(view, "a[href='/notifications'][aria-label^='Notifications']")
    refute html =~ "In motion", "the rail is gone"
    assert Process.alive?(view.pid)
  end

  test "the composer's Discuss/Build switch renders off the row and its event is wired",
       %{conn: conn, id: id} do
    # No plan mode advertised → no switch.
    {:ok, view, html} = live(conn, "/agents/#{id}")
    refute html =~ "Agent mode"

    # A row that advertises one gets the switch, showing the persisted setting.
    :ets.update_element(:chat_agents, id, {2, row(id, %{plan_mode_id: "plan", mode: :discuss})})
    send(view.pid, %Loopyard.Events.ChatAgent.StatusChanged{id: id, status: :idle})
    assert has_element?(view, "button[phx-value-mode=discuss][aria-pressed=true]")

    # The event reaches the agent API without a live GenServer crashing the LV.
    render_click(view, "set_agent_mode", %{"id" => id, "mode" => "build"})
    render_click(view, "set_agent_mode", %{"id" => id, "mode" => "bogus"})
    assert Process.alive?(view.pid)
  end

  defp row(id, extra) do
    Map.merge(
      %{
        id: id,
        name: "Ops",
        status: :idle,
        scope: :system,
        template_id: "system",
        workstation_identity: "al-ident",
        workspace_id: nil,
        messages: [],
        pending_messages: []
      },
      extra
    )
  end

  test "an unknown id sends you home", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/agents/nope-nope")
  end

  test "a workspace agent's id redirects to its workspace chat", %{conn: conn} do
    wid = "al-ws-#{System.unique_integer([:positive])}"

    :ets.insert(
      :chat_agents,
      {wid, %{id: wid, name: "Claude", status: :idle, workspace_id: "ws-x", messages: []}}
    )

    on_exit(fn -> :ets.delete(:chat_agents, wid) end)

    assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/agents/#{wid}")
    assert to =~ "/workspaces"
  end

  test "question events route through ConsentUI without crashing the LV", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, "/agents/#{id}")

    render_hook(view, "draft_question_option", %{
      "question_id" => "nope",
      "q" => "q1",
      "option" => "X"
    })

    render_hook(view, "answer_question_text", %{
      "question_id" => "nope",
      "q" => "q1",
      "text" => ""
    })

    render_hook(view, "perf_sample", %{"max_gap_ms" => 10})

    assert Process.alive?(view.pid)
  end
end
