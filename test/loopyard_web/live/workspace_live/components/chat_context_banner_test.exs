defmodule LoopyardWeb.Live.WorkspaceLive.Components.ChatContextBannerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias LoopyardWeb.Live.WorkspaceLive.Components.Chat

  defp agent(util) do
    %{
      id: "a1",
      name: "Claude",
      status: :idle,
      context_utilization: util,
      pending_count: 0,
      pending_messages: [],
      alive?: true
    }
  end

  defp render(util) do
    render_component(&Chat.chat_panel/1, %{
      messages: [],
      streaming_text: "",
      streaming_thinking: "",
      agent: agent(util),
      workspace_id: "w1",
      host: "localhost",
      thinking_word: nil,
      has_more_messages: false,
      detail_level: :trace
    })
  end

  test "no banner below 85%" do
    html = render(0.5)
    refute html =~ "Context"
  end

  test "warning banner between 85% and 92%" do
    html = render(0.88)
    assert html =~ "88% full"
    assert html =~ "auto-compact"
  end

  test "compacting banner at/above 92%" do
    html = render(0.95)
    assert html =~ "compacting"
    refute html =~ "auto-compact soon"
  end
end
