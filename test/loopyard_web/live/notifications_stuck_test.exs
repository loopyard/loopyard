defmodule LoopyardWeb.NotificationsStuckTest do
  @moduledoc """
  The slide for an agent that stopped without asking (#119): its word, the
  decisive sentence, the ONE action (Continue / Open <account> / Open chat)
  and Dismiss; dismissing an interruption clears the agent's mark; a settled
  one reads as a receipt.
  """
  use LoopyardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Loopyard.Fleet.Conditions
  alias Loopyard.Notifications
  alias Loopyard.Notifications.Item

  defp seed(name, fields) do
    Loopyard.StateKeeper.ensure_tables!()
    id = "stuck-#{System.unique_integer([:positive])}"
    row = Map.merge(%{id: id, name: name, status: :idle, messages: []}, fields)
    :ets.insert(:chat_agents, {id, row})

    on_exit(fn ->
      :ets.delete(:chat_agents, id)
      for %{agent_id: ^id, id: nid} <- Notifications.all(), do: :ets.delete(:notifications, nid)
    end)

    id
  end

  defp raise!(id, c, account \\ "brad") do
    {act, words} = Conditions.action(c, account)
    label = Conditions.label(c, Loopyard.Agents.get(id).name, account)

    Notifications.raise_item(
      Item.stuck(id, c, label, %{action: act, action_text: words, account: account})
    )

    Notifications.sync()
    Conditions.item_id(id, c)
  end

  test "an interruption: Continue and Dismiss; dismissing clears the mark", %{conn: conn} do
    aid = seed("Builder", %{interrupted?: true})
    item = raise!(aid, :interrupted)

    {:ok, view, html} = live(conn, "/notifications/#{aid}/#{Conditions.msg_id(:interrupted)}")

    assert html =~ "Interrupted"
    assert html =~ "A server restart cut Builder&#39;s last turn off"
    assert html =~ "Continue re-runs the unanswered prompt."
    assert has_element?(view, "button[phx-click=continue_stuck][phx-value-id='#{item}']")
    assert has_element?(view, "button[phx-click=dismiss_stuck][phx-value-id='#{item}']")
    # Nothing to chat about with a stopped agent here: no composer.
    refute html =~ "Chat about this decision"

    render_click(view, "dismiss_stuck", %{"id" => item})
    Notifications.sync()

    assert %{status: :dismissed} = Notifications.get(item)
    assert Loopyard.Agents.get(aid)[:interrupted?] == false
    assert render(view) =~ "Dismissed — it comes back if it happens again."
  end

  test "signed out: the one action is the account's page", %{conn: conn} do
    aid = seed("Docs", %{status: :auth_expired})
    raise!(aid, :signed_out, "rocketship")

    {:ok, view, html} = live(conn, "/notifications/#{aid}/#{Conditions.msg_id(:signed_out)}")

    assert html =~ "Signed out"
    assert has_element?(view, ~s(a[href="/workstations/rocketship"]), "Open rocketship")
    refute has_element?(view, "button[phx-click=continue_stuck]")
  end

  test "quarantined: open its chat; a cleared one reads as a receipt", %{conn: conn} do
    aid = seed("Runner", %{quarantined: true})
    item = raise!(aid, :quarantined)

    {:ok, view, _html} = live(conn, "/notifications/#{aid}/#{Conditions.msg_id(:quarantined)}")
    assert has_element?(view, ~s(a[href="/agents/#{aid}"]), "Open chat")

    Notifications.settle(item, :cleared)
    Notifications.sync()
    assert render(view) =~ "Cleared — Runner is moving again."
  end

  test "a Continue that couldn't wake the agent says so on the card", %{conn: conn} do
    aid = seed("Sleeper", %{interrupted?: true})
    item = raise!(aid, :interrupted)
    open = Notifications.get(item)
    Notifications.upsert(%{open | meta: Map.put(open.meta, :note, "Couldn't wake Sleeper.")})
    Notifications.sync()

    {:ok, _view, html} = live(conn, "/notifications/#{aid}/#{Conditions.msg_id(:interrupted)}")
    assert html =~ "Couldn&#39;t wake Sleeper."
  end
end
