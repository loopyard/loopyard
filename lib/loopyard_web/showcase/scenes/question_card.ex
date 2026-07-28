defmodule LoopyardWeb.Showcase.Scenes.QuestionCard do
  @moduledoc false
  use LoopyardWeb.Showcase.Scene,
    name: "question-card",
    description: "The agent parks and asks — the needs-you card with tappable options"

  alias LoopyardWeb.Showcase.Mock

  @impl true
  def component, do: &LoopyardWeb.Live.WorkspaceLive.Components.Chat.chat_panel/1

  @impl true
  def assigns do
    # The tail of the checkout fix leads in, so the desktop frame shows a
    # working transcript above the card instead of bottom-anchored blank
    # space. Same workspace, next task — a natural handoff.
    prior = Enum.take(Mock.checkout_conversation(), -3)

    messages =
      prior ++
        [
          Mock.user_msg(10, "Set up staging deploys for this app.", 300),
          Mock.assistant_msg(
            11,
            "The app is ready to deploy — one decision before I wire it up.",
            360
          ),
          Mock.question_msg(
            12,
            [
              %{
                id: "q1",
                header: "Deploy target",
                prompt: "Where should staging deploys go?",
                multi: false,
                options: [
                  %{
                    label: "Fly.io (Recommended)",
                    description: "You already have fly.toml in the repo — fastest path."
                  },
                  %{
                    label: "Render",
                    description: "Managed Postgres included, slower cold starts."
                  },
                  %{
                    label: "Bare VPS over SSH",
                    description: "Full control; I'll write the systemd units."
                  }
                ]
              }
            ],
            65
          )
        ]

    %{
      messages: messages,
      streaming_text: "",
      streaming_thinking: "",
      agent: Mock.agent(%{status: :thinking, messages: messages}),
      workspace_id: "checkout-fix",
      host: "loopyard.local",
      thinking_word: nil,
      has_more_messages: false,
      window_tail?: true,
      detail_level: :chat,
      expanded_results: MapSet.new()
    }
  end
end
