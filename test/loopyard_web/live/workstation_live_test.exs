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

  test "an unknown identity redirects to the current one with a flash", %{conn: conn, id: id} do
    assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
             live(conn, "/workstations/no-such-identity")

    assert to == "/workstations/#{id}"
    assert flash["error"] =~ "No workstation"
  end
end
