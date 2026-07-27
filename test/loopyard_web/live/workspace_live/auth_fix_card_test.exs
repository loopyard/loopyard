defmodule LoopyardWeb.Live.WorkspaceLive.AuthFixCardTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias LoopyardWeb.Live.WorkspaceLive.Messages.Cards

  defp msg(status) do
    %{id: "af1", role: :auth_fix, status: status, workstation_id: "brad"}
  end

  test "pending: calm instructions + the copyable setup curl + the Claude-page link" do
    html = render_component(&Cards.auth_fix_card/1, %{msg: msg(:pending)})

    assert html =~ "Needs a fresh Claude token"
    assert html =~ "workstations/brad/claude/setup.sh"
    assert html =~ "/workstations/brad/claude"
    # Copyable via the Clip hook (origin substituted client-side).
    assert html =~ ~s(phx-hook="Clip")
    assert html =~ "__ORIGIN__"
  end

  test "resolved: the same card is a green receipt — no instructions" do
    html = render_component(&Cards.auth_fix_card/1, %{msg: msg(:resolved)})

    assert html =~ "Authenticated"
    assert html =~ "agents are back"
    refute html =~ "setup.sh"
  end
end
