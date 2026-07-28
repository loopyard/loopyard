defmodule LoopyardWeb.Showcase.Scenes.ChatWorking do
  @moduledoc false
  use LoopyardWeb.Showcase.Scene,
    name: "chat-working",
    description: "An agent mid-turn: prompt band, plan, tool calls, live thinking tail"

  alias LoopyardWeb.Showcase.Mock

  @impl true
  def component, do: &LoopyardWeb.Live.WorkspaceLive.Components.Chat.chat_panel/1

  @impl true
  def assigns do
    messages =
      Mock.checkout_conversation() ++
        [
          Mock.user_msg(
            10,
            "Nice. While you're in there, make the quantity stepper keyboard-accessible too.",
            300
          )
        ]

    %{
      # Static render: lets hook-owned regions (the live thinking tail)
      # server-render their text instead of waiting for deltas.
      static?: true,
      messages: messages,
      streaming_text: "",
      streaming_thinking:
        "The stepper is two <button> elements with click handlers — no keydown. " <>
          "Arrow keys should adjust quantity when the input has focus; that's the " <>
          "native number-input behavior, so the real fix is using the platform…",
      agent:
        Mock.agent(%{status: :thinking, last_activity_at: Mock.at(310), messages: messages}),
      workspace_id: "checkout-fix",
      host: "loopyard.local",
      thinking_word: "Reasoning",
      has_more_messages: false,
      window_tail?: true,
      detail_level: :everything,
      expanded_results: MapSet.new()
    }
  end
end
