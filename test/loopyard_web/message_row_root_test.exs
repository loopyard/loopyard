defmodule LoopyardWeb.MessageRowRootTest do
  @moduledoc """
  Every `chat_msg/1` clause is the ROOT of a stateful LiveComponent.

  `MessageRowComponent.render/1` delegates straight to `Messages.chat_msg/1`,
  and LiveView requires a stateful component's root to be a single STATIC HTML
  tag. A clause whose root is a function component (`<.log_inline …>`) compiles
  fine and renders fine in isolation — it only blows up when a message of that
  role actually reaches the stream, and then it doesn't degrade: it raises
  during diff and takes the whole page down with a 500.

  That is exactly what happened. The `:build_done` clause carried a wrapper and
  a comment explaining this rule; the `:build` clause right above it didn't. The
  first build message rendered `/operator` unusable.

  Rendering each clause proves the root is acceptable to LiveView, which is
  stricter than reading the source for a `<` — a function component starts with
  `<` too.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias LoopyardWeb.Live.WorkspaceLive.MessageRowComponent

  @base %{
    id: "m1",
    timestamp: ~U[2026-01-01 00:00:00Z],
    content: "hello"
  }

  # One message per role the stream can carry. A new role with a bad root fails
  # here instead of in front of someone.
  defp roles do
    [
      %{role: :user},
      %{role: :assistant},
      %{role: :build, title: "Building"},
      %{role: :build_done, title: "Built"},
      %{role: :system},
      %{role: :tool, tool: "Bash", input: %{}, tool_id: "t1", tool_kind: :command},
      %{role: :tool_result, tool_id: "t1", is_error: false}
    ]
  end

  test "every message role renders with a root LiveView will accept" do
    for extra <- roles() do
      msg = Map.merge(@base, extra)

      html =
        render_component(MessageRowComponent,
          id: "mr-#{msg.role}",
          msg: msg,
          detail_level: :normal,
          agent_id: "a1",
          base_path: "/projects/p/workspaces/w"
        )

      assert is_binary(html),
             "role #{inspect(msg.role)} failed to render as a stateful component root"
    end
  end
end
