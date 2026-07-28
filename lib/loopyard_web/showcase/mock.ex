defmodule LoopyardWeb.Showcase.Mock do
  @moduledoc """
  Mock-data factories for showcase scenes. One believable fictional project —
  "storefront", a Rails shop — threaded through every scene so the marketing
  shots tell a coherent story. All maps mirror the REAL runtime shapes
  (StreamHandler message maps, agent summary maps); if a shape drifts here the
  scene render breaks loudly, which is the point — scenes double as a shape
  contract check for the views.
  """

  # Deterministic timestamps: scenes must render identically run-to-run so
  # re-shot marketing images don't diff. A fixed "yesterday afternoon".
  @t0 ~U[2026-07-27 21:04:00Z]

  def at(seconds_after), do: DateTime.add(@t0, seconds_after)

  @doc "An agent summary map the chat components read (loose `agent[:key]` access)."
  def agent(overrides \\ %{}) do
    Map.merge(
      %{
        id: "demo-agent",
        name: "Claude",
        status: :idle,
        workstation_identity: "maya",
        model: "claude-opus-4-8",
        pending_count: 0,
        last_activity_at: at(600),
        messages: []
      },
      overrides
    )
  end

  def user_msg(id, content, secs) do
    %{id: id, role: :user, content: content, timestamp: at(secs)}
  end

  def assistant_msg(id, content, secs) do
    %{id: id, role: :assistant, content: content, timestamp: at(secs)}
  end

  def tool_msg(id, tool, kind, input, secs) do
    %{
      id: id,
      role: :tool,
      tool: tool,
      tool_kind: kind,
      tool_id: "tc-#{id}",
      input: input,
      timestamp: at(secs)
    }
  end

  def tool_result_msg(id, for_tool_id, content, secs) do
    %{
      id: id,
      role: :tool_result,
      tool_id: "tc-#{for_tool_id}",
      content: content,
      is_error: false,
      timestamp: at(secs)
    }
  end

  @doc "A pending multi-option question card, exactly as `Harness.Questions.ask/3` appends it."
  def question_msg(id, questions, secs, overrides \\ %{}) do
    Map.merge(
      %{
        id: id,
        role: :question,
        question_id: "q-demo",
        questions: questions,
        source: "storefront · checkout-fix",
        status: :pending,
        timestamp: at(secs)
      },
      overrides
    )
  end

  @doc """
  The demo conversation: a bug report driven to a fix. Reads like real work —
  prompt band, a short plan, tool calls a human can follow, green tests.
  """
  def checkout_conversation do
    [
      user_msg(
        1,
        "Customers say the cart total flickers when they change quantity. Can you find it and fix it?",
        0
      ),
      assistant_msg(
        2,
        "Found it. `CartTotal` renders an optimistic subtotal, then re-renders when " <>
          "the server confirms about 300ms later. When the two disagree on tax " <>
          "rounding you get the flicker.\n\nTwo changes: debounce the quantity " <>
          "input, and key the total off the server payload only.",
        95
      ),
      tool_msg(
        3,
        "Grep",
        :grep,
        %{"pattern" => "optimistic_subtotal", "path" => "app/javascript"},
        110
      ),
      tool_result_msg(4, 3, "app/javascript/controllers/cart_controller.js:41", 112),
      tool_msg(
        5,
        "Edit",
        :edit,
        %{
          "file_path" => "app/javascript/controllers/cart_controller.js",
          "old_string" => "this.render(this.optimisticSubtotal())",
          "new_string" => "this.render(payload.subtotal)"
        },
        140
      ),
      tool_result_msg(6, 5, "ok", 141),
      tool_msg(7, "Bash", :command, %{"command" => "bin/rails test test/system/cart_test.rb"}, 170),
      tool_result_msg(8, 7, "12 runs, 34 assertions, 0 failures, 0 errors, 0 skips", 214),
      assistant_msg(
        9,
        "Fixed. The total now renders once, from the server's number. All 12 cart " <>
          "system tests pass — including the two I added for rapid quantity changes.",
        230
      )
    ]
  end
end
