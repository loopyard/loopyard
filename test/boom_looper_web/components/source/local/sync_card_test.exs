defmodule BoomLooperWeb.Components.Source.Local.SyncCardTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  alias BoomLooperWeb.Components.Source.Local.SyncCard

  defp render_card(sync, workspace_id \\ "abcd") do
    render_component(&SyncCard.sync_card/1, workspace_id: workspace_id, sync: sync)
  end

  test "renders the running state" do
    html = render_card(%{status: :running, last_error: nil, last_checked_at: nil})
    assert html =~ "running"
    assert html =~ "bg-emerald-500"
    assert html =~ "Restart"
    assert html =~ "Pause"
    refute html =~ "Resume"
  end

  test "shows Resume button when paused" do
    html = render_card(%{status: :paused, last_error: nil, last_checked_at: nil})
    assert html =~ "paused"
    assert html =~ "bg-amber-400"
    assert html =~ "Resume"
    refute html =~ "Pause</button>"
  end

  test "surfaces error message when errored" do
    html =
      render_card(%{status: :errored, last_error: "worktree missing", last_checked_at: nil})

    assert html =~ "error"
    assert html =~ "bg-red-500"
    assert html =~ "worktree missing"
  end

  test "handles missing sync data (nil-safe)" do
    html = render_card(%{})
    assert html =~ "stopped"
    assert html =~ "bg-zinc-400"
  end

  test "wires restart button to the workspace id" do
    html = render_card(%{status: :running}, "ws-123")
    assert html =~ ~s(phx-click="sync_restart")
    assert html =~ ~s(phx-value-workspace-id="ws-123")
  end
end
