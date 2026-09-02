defmodule LoopyardWeb.DashboardFirstRunTest do
  @moduledoc """
  The first-run gate on `/`.

  A fresh install has no credential, so no agent can run — every downstream
  step (Dockerfile, services, dev server) is blocked. The dashboard must say so
  and offer the one action that fixes it, then get out of the way the moment a
  token exists.

  Regression guard for the onboarding walkthrough (plans/archive/onboarding.md, F4/F8):
  the dashboard used to render "All 3 subsystems healthy" on an install that
  could not do anything at all.
  """
  use LoopyardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Loopyard.Workstation

  setup do
    ws = Workstation.current()
    before = Workstation.Env.all(ws)

    # The first-run step depends on whether ANY project exists, which is global
    # ETS shared with whatever else has run. Snapshot and clear so these assert
    # against a genuine fresh install rather than leftovers from another test
    # (or, when run against a live dev box, real projects).
    projects_before = :ets.tab2list(:project_registry)
    :ets.delete_all_objects(:project_registry)

    on_exit(fn ->
      :ets.delete_all_objects(:project_registry)
      for row <- projects_before, do: :ets.insert(:project_registry, row)
    end)

    on_exit(fn ->
      # Restore whatever was there — these tests mutate the shared env store.
      for {k, _} <- Workstation.Env.all(ws), not Map.has_key?(before, k) do
        Workstation.Env.delete(k, ws)
      end

      for {k, v} <- before, do: Workstation.Env.put(k, v, ws)
    end)

    for {k, _} <- before, k in ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"] do
      Workstation.Env.delete(k, ws)
    end

    %{ws: ws}
  end

  test "with no credential, the dashboard leads with one action", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/")

    assert html =~ "Start here"
    assert html =~ "connect Claude"

    # The action must be present and self-targeting: __ORIGIN__ is swapped for
    # the real browser origin client-side, because a self-hosted server can't
    # know the host the user actually reached.
    assert html =~ "__ORIGIN__/workstations/"
    assert html =~ "claude/setup.sh"
  end

  test "connecting Claude advances to the next step, it does not dead-end", %{
    conn: conn,
    ws: ws
  } do
    Workstation.Env.put("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-test", ws)

    # Assert the PRECONDITION, not just the symptom. The dashboard reads the
    # credential off `Workstation.current()`; if that store isn't what this
    # test just wrote to, the page is right and the setup is wrong — and the
    # failure should say so instead of pointing at the banner.
    assert "CLAUDE_CODE_OAUTH_TOKEN" in Workstation.Env.keys(Workstation.current()),
           "setup did not land: current=#{Workstation.current()} wrote-to=#{ws} " <>
             "keys=#{inspect(Workstation.Env.keys(Workstation.current()))}"

    {:ok, _lv, html} = live(conn, "/")

    # The blocked-on-a-human band is gone...
    refute html =~ "Start here"

    # ...and the entrance names the NEXT step rather than going quiet. On a
    # fresh install there are no projects, so that is what it asks for.
    assert html =~ "now add a project"
    assert html =~ "/projects/new"
  end

  test "a raw API key counts as ready too", %{conn: conn, ws: ws} do
    Workstation.Env.put("ANTHROPIC_API_KEY", "sk-ant-test", ws)

    {:ok, _lv, html} = live(conn, "/")

    refute html =~ "Start here"
  end
end
