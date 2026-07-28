defmodule LoopyardWeb.Showcase.Scenes.Operator do
  @moduledoc false
  use LoopyardWeb.Showcase.Scene,
    name: "operator",
    description:
      "The operator cockpit: chief-of-staff chat on the left (overview, " <>
        "dispatch), the For-You rail on the right with running work, a " <>
        "question waiting, and recently wrapped jobs"

  alias LoopyardWeb.Showcase.Mock

  @impl true
  def component, do: &LoopyardWeb.OperatorLive.render/1

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
      operator_attention: [],
      attention_groups: [],
      attention_by_ws: %{
        "checkout-fix" => [
          %{
            agent_id: "demo-agent",
            msg: %{id: 12},
            label: "Where should staging deploys go?"
          }
        ]
      },
      active_jobs: [
        %{
          id: "checkout-fix",
          project_id: "storefront",
          agent_id: "demo-agent",
          project_name: "storefront",
          workspace_name: "checkout-fix",
          state: :chugging,
          delta: 3
        }
      ],
      done_buckets: [
        {"Recently",
         [
           %{
             id: "gp-main",
             project_id: "gardenparty",
             agent_id: "gp-agent",
             project_name: "gardenparty",
             workspace_name: "main",
             state: :done,
             delta: 0
           }
         ]},
        {"Today",
         [
           %{
             id: "ma-main",
             project_id: "mobile-api",
             agent_id: "ma-agent",
             project_name: "mobile-api",
             workspace_name: "main",
             state: :done,
             delta: 0
           }
         ]}
      ],
      vapid_key: nil,
      tracks: [
        {:serene, "Serene"},
        {:nocturne, "Nocturne"},
        {:cascade, "Cascade"},
        {:hum, "Hum"},
        {:pink, "Pink"}
      ],
      current_track: :serene
    }
  end
end
