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

  test "an unknown identity redirects to the current one with a flash", %{conn: conn, id: id} do
    assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
             live(conn, "/workstations/no-such-identity")

    assert to == "/workstations/#{id}"
    assert flash["error"] =~ "No workstation"
  end
end
