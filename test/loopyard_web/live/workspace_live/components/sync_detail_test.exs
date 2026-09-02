defmodule LoopyardWeb.Live.WorkspaceLive.Components.SyncDetailTest do
  @moduledoc "The local-workspace sync card: status, last error, and the host path."
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias LoopyardWeb.Live.WorkspaceLive.Components.SyncDetail

  test "no sync status yet renders as stopped, with the host path" do
    html =
      render_component(&SyncDetail.sync_detail/1, %{
        sync_status: nil,
        workspace_id: "ws-1",
        workspace: %{path: "/Users/me/code/app"}
      })

    assert html =~ "/Users/me/code/app"
  end

  test "a watching session shows its status and a last error when there is one" do
    html =
      render_component(&SyncDetail.sync_detail/1, %{
        sync_status: %{status: :watching, last_error: "mutagen: connection refused"},
        workspace_id: "ws-1",
        workspace: %{path: "/Users/me/code/app"}
      })

    assert html =~ "mutagen: connection refused"
  end
end
