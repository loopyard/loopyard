defmodule LoopyardWeb.Showcase.Scenes.Agent do
  @moduledoc false
  use LoopyardWeb.Showcase.Scene,
    name: "agent",
    description:
      "A system agent's chat: the chief-of-staff conversation — overview, " <>
        "dispatch, a returning result — one bar, no rail"

  alias LoopyardWeb.Showcase.Mock

  @impl true
  def component, do: &LoopyardWeb.AgentLive.render/1

  @impl true
  def assigns do
    messages = [
      Mock.user_msg(101, "Anything break overnight?", -1200),
      Mock.assistant_msg(
        102,
        "One thing: **gardenparty · main**'s dev server went down at 2:14 AM on " <>
          "a bad migration. Its agent rolled the migration back and restarted the " <>
          "server; it's been green since. The full trail is in the workspace if " <>
          "you want the weeds.",
        -1150
      ),
      Mock.user_msg(1, "Morning. Where do we stand?", 0),
      Mock.assistant_msg(
        2,
        "Three projects up.\n\n" <>
          "- **storefront · checkout-fix** — Claude is mid-fix on the cart " <>
          "flicker; tests were green on the last run. One question is waiting " <>
          "on you (staging deploy target).\n" <>
          "- **gardenparty · main** — dev server running on :4003, agent idle.\n" <>
          "- **mobile-api · main** — quiet since yesterday.",
        20
      ),
      Mock.user_msg(3, "Ship the checkout fix to staging once the suite is green.", 200),
      Mock.assistant_msg(
        4,
        "Dispatched to **storefront · checkout-fix**. It'll run the full suite, " <>
          "then deploy to staging and report back here. I'll only interrupt you " <>
          "if something needs a human.",
        215
      )
    ]

    operator =
      Mock.agent(%{
        id: "operator",
        name: "Operator",
        status: :idle,
        alive?: true,
        messages: messages
      })

    %{
      static?: true,
      flash: %{},
      mobile_view: :chat,
      host: "loopyard.local",
      messages: messages,
      streaming_text: "",
      streaming_thinking: "",
      thinking_word: nil,
      has_more_messages: false,
      window_tail?: true,
      selected_agent: operator,
      agent_id: "operator",
      agent_name: "Operator"
    }
  end
end
