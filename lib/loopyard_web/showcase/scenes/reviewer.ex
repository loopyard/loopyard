defmodule LoopyardWeb.Showcase.Scenes.Reviewer do
  @moduledoc false
  use LoopyardWeb.Showcase.Scene,
    name: "reviewer",
    description:
      "The Reviewer deck: every decision waiting on you, one per slide — a deploy question and a test-suite question from two workspaces, with an answered receipt below"

  alias LoopyardWeb.Showcase.Mock

  @impl true
  def component, do: &LoopyardWeb.ReviewLive.review_deck/1

  @impl true
  def assigns do
    %{cards: [deploy_card(), flaky_card(), answered_card()], focused?: false, history?: false}
  end

  # The same deploy-target ask the chat scenes show — here it's a slide.
  defp deploy_card do
    q = %{
      id: "q1",
      header: "Deploy target",
      prompt: "Where should staging deploys go?",
      multi: false,
      options: [
        %{
          label: "Fly.io (Recommended)",
          description: "You already have fly.toml in the repo — fastest path."
        },
        %{label: "Render", description: "Managed Postgres included, slower cold starts."},
        %{label: "Bare VPS over SSH", description: "Full control; I'll write the systemd units."}
      ]
    }

    card(
      msg_id: 12,
      workspace: "checkout-fix",
      path: "/projects/storefront/workspaces/checkout-fix",
      asked_secs: 540,
      q: q,
      msg: Mock.question_msg(12, [q], 540)
    )
  end

  defp flaky_card do
    q = %{
      id: "q1",
      header: "Test suite",
      prompt: "Two geolocation specs fail only in CI. Ship the fix now or hold for a real repro?",
      multi: false,
      options: [
        %{
          label: "Quarantine and ship (Recommended)",
          description: "Tag them flaky, open an issue, land the cart fix today."
        },
        %{label: "Hold the merge", description: "I'll keep digging for the CI-only repro first."}
      ]
    }

    card(
      msg_id: 31,
      workspace: "mobile-api",
      path: "/projects/storefront/workspaces/mobile-api",
      asked_secs: 420,
      q: q,
      msg: Mock.question_msg(31, [q], 420, %{source: "storefront · mobile-api"})
    )
  end

  # A settled receipt under the pending pair: answered questions stay
  # traversable — the deck is a record, not a graveyard.
  defp answered_card do
    q = %{
      id: "q1",
      header: "Schema change",
      prompt: "Rename the ambiguous `total` column while I'm in the migration?",
      multi: false,
      options: [
        %{label: "Yes, rename to subtotal_cents", description: "One migration, I'll fix call sites."},
        %{label: "Leave it", description: "Out of scope for this fix."}
      ]
    }

    card(
      msg_id: 8,
      workspace: "checkout-fix",
      path: "/projects/storefront/workspaces/checkout-fix",
      asked_secs: 120,
      q: q,
      msg:
        Mock.question_msg(8, [q], 120, %{
          status: :answered,
          selections: %{"q1" => ["Yes, rename to subtotal_cents"]}
        })
    )
  end

  defp card(opts) do
    %{
      slide: %{
        project_name: "storefront",
        workspace_name: opts[:workspace],
        agent_id: "demo-agent",
        agent_name: "Claude",
        msg_id: opts[:msg_id],
        q_id: opts[:q].id,
        path: opts[:path],
        asked_at: Mock.at(opts[:asked_secs])
      },
      msg: opts[:msg],
      q: opts[:q],
      dom_id: "demo-#{opts[:msg_id]}-q1"
    }
  end
end
