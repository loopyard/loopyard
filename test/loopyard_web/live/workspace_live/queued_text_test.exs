defmodule LoopyardWeb.Live.WorkspaceLive.QueuedTextTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Loopyard.Attachments
  alias LoopyardWeb.Live.WorkspaceLive.Components.Chat

  @shot %{
    path: "/workspace/.loopyard/uploads/20260902T061913-9608-riddle.png",
    name: "20260902T061913-9608-riddle.png",
    mime: "image/png",
    size: 3208
  }

  test "a queued line shows the human's words and a chip per file — never the marker line" do
    html =
      render_component(&Chat.queued_text/1, %{
        text: Attachments.annotate("Why is this off?", [@shot])
      })

    assert html =~ "Why is this off?"
    assert html =~ "riddle.png"
    refute html =~ "20260902T061913"
    refute html =~ "📎 Attached:"
    refute html =~ "open the file to view it"
  end

  test "attachments alone queue as chips only" do
    html = render_component(&Chat.queued_text/1, %{text: Attachments.annotate("", [@shot])})
    assert html =~ "riddle.png"
    refute html =~ "<p class"
  end
end
