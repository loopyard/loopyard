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
         harness: :claude,
         workstation_identity: "rocketship",
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
    # Other tests leave agents in ETS; only the shape of the line is ours.
    assert html =~ ~r/\d+ agents? · .*\d+ working/

    # Whose account each agent runs under — who pays — on the row's meta line.
    assert html =~ "Claude Code · Rocketship"
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

  test "a row says what the agent is doing beside its name, and what it runs on beneath", %{
    conn: conn,
    sid: sid
  } do
    {:ok, _view, html} = live(conn, "/agents")
    {row_at, _} = :binary.match(html, "/agents/#{sid}")
    row = String.slice(html, row_at, 1800)

    assert row =~ "Working"
    # The model by its short name, not the raw id.
    assert row =~ "Opus 4.8"
    refute row =~ "claude-opus-4-8"
    # The facts line wraps on a phone instead of losing its end.
    assert row =~ "line-clamp-2"
  end

  test "an agent restored mid-turn reads Interrupted, sorts up, and is not counted as working",
       %{conn: conn, sid: sid, wid: wid} do
    [{^wid, row}] = :ets.lookup(:chat_agents, wid)
    :ets.insert(:chat_agents, {wid, Loopyard.AgentLog.at_rest(%{row | status: :thinking})})

    {:ok, _view, html} = live(conn, "/agents")

    assert html =~ "Interrupted"
    assert html =~ ~r/\d+ interrupted/
    # It wants a human's eye, so it leads the system agent that is merely working.
    {ws_at, _} = :binary.match(html, "/agents/#{wid}")
    {sys_at, _} = :binary.match(html, "/agents/#{sid}")
    assert ws_at < sys_at
    assert String.slice(html, ws_at, 1500) =~ "bg-amber-500"
  end

  test "a signed-out agent and one at its plan limit say so in words", %{
    conn: conn,
    sid: sid,
    wid: wid
  } do
    [{^sid, sys}] = :ets.lookup(:chat_agents, sid)
    [{^wid, ws}] = :ets.lookup(:chat_agents, wid)
    :ets.insert(:chat_agents, {sid, %{sys | status: :auth_expired}})
    :ets.insert(:chat_agents, {wid, %{ws | status: :rate_limited}})

    {:ok, _view, html} = live(conn, "/agents")

    assert html =~ "Signed out"
    assert html =~ "At plan limit"
    assert html =~ ~r/\d+ at a plan limit/
  end

  test "/agents/new shows the form with the system templates", %{conn: conn} do
    {:ok, view, html} = live(conn, "/agents/new")
    assert html =~ "New system agent"
    assert has_element?(view, "select[name=template_id] option[value=system]")
    refute has_element?(view, "select[name=template_id] option[value=coding]")
  end
end
