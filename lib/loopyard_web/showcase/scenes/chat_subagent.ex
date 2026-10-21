defmodule LoopyardWeb.Showcase.Scenes.ChatSubagent do
  @moduledoc false
  use LoopyardWeb.Showcase.Scene,
    name: "chat-subagent",
    description:
      "Harness-native sub-agents: a settled delegation with its calls folded under it and its report as prose, then a second one still working — count, latest call, elapsed"

  alias LoopyardWeb.Showcase.Mock

  @impl true
  def component, do: &LoopyardWeb.Live.WorkspaceLive.Components.Chat.chat_panel/1

  # A sub-agent's call: same shape as any tool message plus the delegating
  # call's id — exactly what StreamHandler records from `parent_id`.
  defp child(id, tool, kind, input, parent_id, secs),
    do: Mock.tool_msg(id, tool, kind, input, secs) |> Map.put(:parent_tool_id, "tc-#{parent_id}")

  @impl true
  def assigns do
    messages = [
      Mock.user_msg(
        1,
        "Before you touch the stepper, find every caller of `CartTotal.recompute` and where the flicker comes from.",
        320
      ),
      Mock.assistant_msg(2, "Delegating the search so I keep my context for the fix.", 314),
      # Settled delegation: an Explore sub-agent, three calls, its report.
      Mock.tool_msg(
        3,
        "Agent",
        :agent,
        %{"description" => "Find callers of CartTotal.recompute", "subagent_type" => "Explore"},
        312
      ),
      child(4, "Grep", :grep, %{"pattern" => "CartTotal.recompute", "path" => "app"}, 3, 310),
      Mock.tool_result_msg(
        5,
        4,
        "app/controllers/cart_controller.rb:41:    CartTotal.recompute(cart)\n" <>
          "app/javascript/controllers/stepper_controller.js:18:  fetch(`/cart/${id}/recompute`)\n" <>
          "app/models/line_item.rb:27:    CartTotal.recompute(cart) if saved_change_to_quantity?",
        309
      ),
      child(6, "Read", :read, %{"file_path" => "/workspace/app/models/line_item.rb"}, 3, 306),
      Mock.tool_result_msg(
        5,
        6,
        "class LineItem < ApplicationRecord\n  after_save :recompute_cart\n…",
        305
      ),
      child(
        7,
        "Read",
        :read,
        %{"file_path" => "/workspace/app/controllers/cart_controller.rb"},
        3,
        302
      ),
      Mock.tool_result_msg(
        8,
        7,
        "class CartController < ApplicationController\n  def update\n…",
        301
      ),
      Mock.tool_result_msg(
        9,
        3,
        "## Callers of `CartTotal.recompute`\n\n" <>
          "1. `app/controllers/cart_controller.rb:41` — the update action, after `line_item.save`.\n" <>
          "2. `app/models/line_item.rb:27` — an `after_save` callback on quantity changes.\n\n" <>
          "**The flicker:** both fire on one stepper click — the callback recomputes, then the controller " <>
          "recomputes again and re-renders with the intermediate total. The JS fetch in " <>
          "`stepper_controller.js:18` is a third, redundant trigger.",
        296
      ),
      Mock.assistant_msg(
        10,
        "Two real callers and a redundant fetch. The double recompute is the flicker — I'll drop the controller call and keep the callback.",
        290
      ),
      Mock.user_msg(
        11,
        "Good. Check the test suite covers the stepper before you change it.",
        40
      ),
      # Working delegation: calls landing, no report yet.
      Mock.tool_msg(
        12,
        "Agent",
        :agent,
        %{"description" => "Audit stepper test coverage", "subagent_type" => "Explore"},
        34
      ),
      child(13, "Grep", :grep, %{"pattern" => "stepper", "path" => "test"}, 12, 31),
      Mock.tool_result_msg(
        14,
        13,
        "test/system/cart_test.rb:52:  test \"stepper updates the total\" do",
        30
      ),
      child(15, "Read", :read, %{"file_path" => "/workspace/test/system/cart_test.rb"}, 12, 12),
      Mock.tool_result_msg(16, 15, "require \"application_system_test_case\"\n…", 11),
      child(
        17,
        "Bash",
        :command,
        %{"command" => "bin/rails test test/system/cart_test.rb -n /stepper/"},
        12,
        4
      )
    ]

    %{
      static?: true,
      messages: messages,
      streaming_text: "",
      streaming_thinking: "",
      agent: Mock.agent(%{status: :thinking, last_activity_at: Mock.at(4), messages: messages}),
      workspace_id: "checkout-fix",
      host: "loopyard.local",
      thinking_word: "Working",
      has_more_messages: false,
      window_tail?: true,
      detail_level: :everything,
      expanded_results: MapSet.new()
    }
  end
end
