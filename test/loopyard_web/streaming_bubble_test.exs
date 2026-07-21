defmodule LoopyardWeb.StreamingBubbleTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias LoopyardWeb.Live.WorkspaceLive.Messages

  test "streamdown renders live markdown and remends an unclosed tail construct" do
    html =
      render_component(&Messages.streaming_bubble/1,
        streaming_text:
          "## Heading\n\nA para with **bold**, `code`.\n\n- one\n- two\n\nUNCLOSED **bold at the tail"
      )

    assert html =~ "<h2"
    assert html =~ "<strong>bold</strong>"
    assert html =~ "<code>code</code>"
    assert html =~ "<li"
    # Remend: the dangling "**bold at the tail" renders as bold, not raw asterisks.
    assert html =~ "at the tail"
    refute html =~ "**bold at the tail"
  end

  test "empty streaming_text renders without crashing" do
    html = render_component(&Messages.streaming_bubble/1, streaming_text: "")
    assert is_binary(html)
  end
end
