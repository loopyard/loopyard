defmodule LoopyardWeb.WorkstationLiveTest do
  @moduledoc """
  `/workstations` and `/workstations/:id` mount and render — the identity
  pages had no test at all (14% coverage), so a template KeyError only
  showed up in a browser.
  """
  use LoopyardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Loopyard.Workstation

  setup do
    id = Workstation.current()
    %{id: id}
  end

  test "the index lists the identities and marks the current one", %{conn: conn, id: id} do
    {:ok, _view, html} = live(conn, "/workstations")
    assert html =~ id
  end

  test "an identity's page mounts with its console and integrations", %{conn: conn, id: id} do
    {:ok, _view, html} = live(conn, "/workstations/#{id}")
    assert html =~ id
  end

  test "looking at another identity never changes the default; \"Make default\" does",
       %{conn: conn, id: id} do
    other = "acct-#{System.unique_integer([:positive])}"
    :ok = Workstation.create(other)

    on_exit(fn ->
      Workstation.set_current(id)
      File.rm_rf(Workstation.dir(other))
    end)

    # Opening its hub, and its Claude page to sign it in, is just looking. The
    # default used to follow the last page opened — global state moved by a
    # page view, which re-pointed every new workspace at a second account the
    # moment you went to sign that account in.
    {:ok, hub, html} = live(conn, "/workstations/#{other}")
    assert Workstation.current() == id
    {:ok, _tool, _html} = live(conn, "/workstations/#{other}/claude")
    assert Workstation.current() == id

    # The page says so, and offers the switch as an explicit action.
    assert html =~ "Not the default"
    assert html =~ "start on #{id}"

    html = hub |> element("button[phx-click=make_default]") |> render_click()
    assert Workstation.current() == other
    refute html =~ "Not the default"

    # The default's own page has nothing to offer.
    {:ok, _view, html} = live(conn, "/workstations/#{other}")
    refute html =~ "Not the default"
  end

  test "the failover list: opt-in, ordered, and the account's live limit shown",
       %{conn: conn} do
    [a, b, c] =
      for tag <- ~w(fa fb fc) do
        id = "#{tag}-#{System.unique_integer([:positive])}"
        :ok = Workstation.create(id)
        on_exit(fn -> File.rm_rf(Workstation.dir(id)) end)
        id
      end

    on_exit(&Loopyard.AccountLimits.clear_all/0)
    Loopyard.AccountLimits.mark(a, :claude, System.system_time(:millisecond) + 60_000)

    {:ok, view, html} = live(conn, "/workstations/#{a}")

    # Off by default: nothing listed, every other account offered.
    assert Loopyard.Workstation.Failover.fallbacks(a) == []
    refute html =~ ~s(id="ws-fallbacks")
    assert html =~ "At its plan limit now: Claude Code until"

    view |> form("#ws-add-fallback", %{"account" => b}) |> render_submit()
    view |> form("#ws-add-fallback", %{"account" => c}) |> render_submit()
    assert Loopyard.Workstation.Failover.fallbacks(a) == [b, c]

    html =
      view
      |> element(~s(button[phx-click=raise_fallback][phx-value-account="#{c}"]))
      |> render_click()

    assert Loopyard.Workstation.Failover.fallbacks(a) == [c, b]
    assert html =~ ~s(id="ws-fallbacks")

    view
    |> element(~s(button[phx-click=remove_fallback][phx-value-account="#{c}"]))
    |> render_click()

    assert Loopyard.Workstation.Failover.fallbacks(a) == [b]

    # The account's own name is never an option for itself.
    refute has_element?(view, ~s(#ws-add-fallback option[value="#{a}"]))
  end

  test "an unknown identity redirects to the current one with a flash", %{conn: conn, id: id} do
    assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
             live(conn, "/workstations/no-such-identity")

    assert to == "/workstations/#{id}"
    assert flash["error"] =~ "No workstation"
  end
end
