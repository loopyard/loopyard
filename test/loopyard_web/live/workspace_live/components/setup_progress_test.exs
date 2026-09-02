defmodule LoopyardWeb.Live.WorkspaceLive.Components.SetupProgressTest do
  @moduledoc """
  The workspace-setup takeover screen: three phases, a live seeding progress
  block, and a failure state with the retry the user is told to press.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias LoopyardWeb.Live.WorkspaceLive.Components.SetupProgress

  test "mid-seeding shows every phase, the branch name, and the live transfer figures" do
    html =
      render_component(&SetupProgress.setup_progress/1, %{
        setup: %{
          phase: :seeding,
          error: nil,
          progress: %{
            bytes: 12_500_000,
            current_file: "lib/app/router.ex",
            eta_seconds: 42,
            rate_bps: 2_000_000
          }
        },
        workspace_id: "ws-1",
        workspace_name: "feature/attachments"
      })

    assert html =~ "Setting up workspace"
    assert html =~ "feature/attachments"
    assert html =~ "Set up host git worktree"
    assert html =~ "Create Docker volume"
    assert html =~ "Copy project files into workspace volume"
    assert html =~ "lib/app/router.ex"
  end

  test "a failed phase shows the error and offers Retry with the workspace id" do
    html =
      render_component(&SetupProgress.setup_progress/1, %{
        setup: %{
          phase: :failed,
          error: %{
            phase: :volume,
            why: "docker: daemon not running",
            action: "Start Docker, then retry.",
            consequence: "The workspace has no volume to put files in."
          },
          progress: nil
        },
        workspace_id: "ws-1"
      })

    assert html =~ "docker: daemon not running"
    assert html =~ "Start Docker, then retry."
    assert html =~ "The workspace has no volume to put files in."
    assert html =~ "ws-1"
    assert html =~ ~r/Retry/i
  end
end
