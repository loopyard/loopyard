defmodule LoopyardWeb.Live.WorkspaceLive.HarnessStatusActionTest do
  @moduledoc """
  A problem state that names a page must LINK to it.

  The sign-in-expired card read "reconnect it on the Workstation page" as plain
  prose — a sign pointing at a door instead of the door. In a mini-app the fix
  should be one tap away from where the problem is reported.
  """
  use LoopyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias LoopyardWeb.Live.WorkspaceLive.Components.ContextPanel

  defp agent(overrides) do
    Map.merge(
      %{
        id: "a1",
        name: "Claude",
        status: :idle,
        alive?: true,
        errors: 0,
        total_tokens: 0,
        input_tokens: 0,
        output_tokens: 0,
        cache_read_tokens: 0,
        cost: 0.0,
        started_at: DateTime.utc_now(),
        last_activity_at: DateTime.utc_now()
      },
      overrides
    )
  end

  test "sign-in expired offers a link to reconnect, not just instructions" do
    html =
      render_component(&ContextPanel.context_panel/1,
        agent: agent(%{auth_error: "Authentication required"})
      )

    assert html =~ "Sign-in expired"
    assert html =~ "Reconnect Claude"

    # It has to go to the Claude connect page — the place that can actually fix
    # it — not merely mention it.
    assert html =~ ~r{href="/workstations/[^"]+/claude"}
  end

  test "a healthy agent shows no problem card and no action" do
    html = render_component(&ContextPanel.context_panel/1, agent: agent(%{}))

    refute html =~ "Sign-in expired"
    refute html =~ "Reconnect Claude"
  end
end
