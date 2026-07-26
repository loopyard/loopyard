defmodule LoopyardWeb.StreamingBubbleTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias LoopyardWeb.Live.WorkspaceLive.Messages

  test "streaming bubble is a client-rendered shell (StreamMarkdown owns the markdown)" do
    html =
      render_component(&Messages.streaming_bubble/1,
        streaming_text:
          "## Heading\n\nA para with **bold**, `code`.\n\n- one\n- two\n\nUNCLOSED **bold at the tail"
      )

    # Markdown (incl. tail remending) renders CLIENT-side: the server ships an
    # empty phx-update="ignore" shell the StreamMarkdown hook fills from delta
    # pushes — re-rendering server HTML per delta re-diffed the whole bubble.
    assert html =~ ~s(phx-hook="StreamMarkdown")
    assert html =~ ~s(phx-update="ignore")
    assert html =~ "data-stream-blocks"
    assert html =~ "data-stream-tail"
    # No server-rendered markdown or raw text leaks into the shell.
    refute html =~ "<h2"
    refute html =~ "bold at the tail"
  end

  test "empty streaming_text renders without crashing" do
    html = render_component(&Messages.streaming_bubble/1, streaming_text: "")
    assert is_binary(html)
  end
end
