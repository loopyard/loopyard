defmodule LoopyardWeb.AgentsLiveTest do
  use LoopyardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    Loopyard.StateKeeper.ensure_tables!()
    sid = "agents-sys-#{System.unique_integer([:positive])}"
    wid = "agents-ws-#{System.unique_integer([:positive])}"

    :ets.insert(
      :chat_agents,
      {sid,
       %{
         id: sid,
         name: "Operator",
         status: :thinking,
         scope: :system,
         template_id: "system",
         workstation_identity: "brad",
         workspace_id: nil,
         harness: :claude,
         model: "claude-opus-4-8",
         messages: [],
         pending_messages: [],
         last_activity_at: DateTime.utc_now()
       }}
    )

    :ets.insert(
      :chat_agents,
      {wid,
       %{
         id: wid,
         name: "Claude",
         status: :idle,
         workspace_id: "ws-nope",
         messages: [],
         pending_messages: [],
         last_activity_at: DateTime.utc_now()
       }}
    )

    on_exit(fn ->
      :ets.delete(:chat_agents, sid)
      :ets.delete(:chat_agents, wid)
    end)

    {:ok, sid: sid, wid: wid}
  end

  test "lists every agent, system first, each row a link to its chat", %{
    conn: conn,
    sid: sid,
    wid: wid
  } do
    {:ok, view, html} = live(conn, "/agents")

    assert html =~ "System"
    assert html =~ "Operator"
    assert html =~ "Claude"
    assert has_element?(view, "a[href='/agents/#{sid}']")
    # A workspace agent whose workspace is unknown still gets a working link.
    assert has_element?(view, "a[href='/agents/#{wid}']")

    # System before workspaces.
    {sys_at, _} = :binary.match(html, "/agents/#{sid}")
    {ws_at, _} = :binary.match(html, "/agents/#{wid}")
    assert sys_at < ws_at
    # Other tests leave agents in ETS; only the shape of the count is ours.
    assert html =~ ~r/\d+ agents? · \d+ working/
  end

  test "a status change re-renders the row", %{conn: conn, sid: sid} do
    {:ok, view, _html} = live(conn, "/agents")
    [{^sid, row}] = :ets.lookup(:chat_agents, sid)
    :ets.insert(:chat_agents, {sid, %{row | status: :idle}})

    Loopyard.Events.ChatAgent.publish(%Loopyard.Events.ChatAgent.StatusChanged{
      id: sid,
      status: :idle
    })

    html = render(view)
    {row_at, _} = :binary.match(html, "/agents/#{sid}")
    # The row's state light: working (violet, pulsing) → ready (green).
    assert String.slice(html, row_at, 1500) =~ "bg-emerald-500"
  end

  test "/agents/new shows the form with the system templates", %{conn: conn} do
    {:ok, view, html} = live(conn, "/agents/new")
    assert html =~ "New system agent"
    assert has_element?(view, "select[name=template_id] option[value=system]")
    refute has_element?(view, "select[name=template_id] option[value=coding]")
  end
end
