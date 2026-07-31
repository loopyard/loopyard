defmodule LoopyardWeb.DashboardFirstRunTest do
  @moduledoc """
  The first-run gate on `/`.

  A fresh install has no credential, so no agent can run — every downstream
  step (Dockerfile, services, dev server) is blocked. The dashboard must say so
  and offer the one action that fixes it, then get out of the way the moment a
  token exists.

  Regression guard for the onboarding walkthrough (plans/onboarding.md, F4/F8):
  the dashboard used to render "All 3 subsystems healthy" on an install that
  could not do anything at all.
  """
  use LoopyardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Loopyard.Workstation

  setup do
    ws = Workstation.current()
    before = Workstation.Env.all(ws)

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

  test "the gate disappears once a token exists", %{conn: conn, ws: ws} do
    Workstation.Env.put("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-test", ws)

    {:ok, _lv, html} = live(conn, "/")

    refute html =~ "Start here"
  end

  test "a raw API key counts as ready too", %{conn: conn, ws: ws} do
    Workstation.Env.put("ANTHROPIC_API_KEY", "sk-ant-test", ws)

    {:ok, _lv, html} = live(conn, "/")

    refute html =~ "Start here"
  end
end
