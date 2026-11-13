defmodule LoopyardWeb.Showcase.Scenes.StuckCard do
  @moduledoc false
  use LoopyardWeb.Showcase.Scene,
    name: "stuck-card",
    description: "An agent a restart cut off — the inbox card with Continue and Dismiss"

  use Phoenix.Component

  alias Loopyard.Fleet.Conditions
  alias Loopyard.Notifications.Item

  @impl true
  def frame, do: :flow

  @impl true
  def component, do: &render/1

  @impl true
  def assigns do
    {act, words} = Conditions.action(:interrupted, "brad")

    %{
      item: %Item{
        id: Conditions.item_id("a1", :interrupted),
        kind: :stuck,
        agent_id: "a1",
        agent_name: "Claude",
        path: "/agents/a1",
        label: Conditions.label(:interrupted, "Claude", "brad"),
        raised_at: DateTime.utc_now(),
        meta: %{condition: :interrupted, action: act, action_text: words, account: "brad"}
      }
    }
  end

  defp render(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-2xl px-4 md:px-6 pt-6">
      <LoopyardWeb.NotificationsLive.StuckCard.card item={@item} pending?={true} />
    </div>
    """
  end
end
