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

  # Auto-compaction is house-keeping the user shouldn't have to care about:
  # no pre-warning at all, and only a tiny muted "Compacting…" marker WHILE
  # it's actually happening (>=92%). See the comment in Chat.chat_panel/1.
  test "no marker below the 92% threshold" do
    refute render(0.5) =~ "Compacting"
    refute render(0.88) =~ "Compacting"
  end

  test "compacting marker at/above 92%" do
    html = render(0.95)
    assert html =~ "Compacting"
  end
end
