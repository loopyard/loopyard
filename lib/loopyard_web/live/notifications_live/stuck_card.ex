defmodule LoopyardWeb.NotificationsLive.StuckCard do
  @moduledoc """
  The card for a `:stuck` item (#119): an agent that stopped without asking.
  The condition's word, the decisive sentence, the one action in words, then
  two moves — the action (filled) and Dismiss (furthest away). The action is
  Continue (re-drive here, `Loopyard.Fleet.continue/1`), Open <account> (its
  sign-in), or Open chat. It settles on its own when the condition clears, so
  a settled one reads as a receipt.
  """
  use Phoenix.Component

  alias Loopyard.Fleet.Conditions
  alias LoopyardWeb.Components.StreamCard

  attr :item, :map, required: true
  attr :pending?, :boolean, required: true

  def card(assigns) do
    meta = assigns.item.meta || %{}

    assigns =
      assign(assigns,
        condition: meta[:condition],
        action: meta[:action],
        account: meta[:account],
        words: meta[:note] || meta[:action_text]
      )

    ~H"""
    <StreamCard.band tone={(@pending? && :needs_you) || :neutral} chrome={:desktop}>
      <div class="text-meta font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400">
        {(@pending? && (Conditions.word(@condition) || "Stopped")) || settled_word(@item)}
      </div>
      <p class="mt-2 text-lead text-zinc-900 dark:text-zinc-50">{@item.label}</p>
      <p :if={@pending? && @words} class="mt-2 text-body text-zinc-600 dark:text-zinc-300">
        {@words}
      </p>

      <div :if={@pending?} class="mt-4 flex flex-col sm:flex-row sm:items-center gap-2">
        <button
          :if={@action == :continue}
          type="button"
          phx-click="continue_stuck"
          phx-value-id={@item.id}
          class={StreamCard.action_class(variant: :primary)}
        >
          Continue
        </button>
        <.link
          :if={@action == :account && @account}
          navigate={"/workstations/#{@account}"}
          class={StreamCard.action_class(variant: :primary)}
        >
          Open {@account}
        </.link>
        <.link
          :if={@action not in [:continue, :account] or (@action == :account and is_nil(@account))}
          navigate={@item.path}
          class={StreamCard.action_class(variant: :primary)}
        >
          Open chat
        </.link>
        <button
          type="button"
          phx-click="dismiss_stuck"
          phx-value-id={@item.id}
          class={[StreamCard.action_class(), "sm:ml-auto"]}
        >
          Dismiss
        </button>
      </div>
      <p :if={!@pending?} class="mt-3 text-lead text-zinc-500 dark:text-zinc-400">
        {receipt(@item)}
      </p>
    </StreamCard.band>
    """
  end

  defp settled_word(%{status: :dismissed}), do: "Dismissed"
  defp settled_word(%{outcome: :continued}), do: "Continued"
  defp settled_word(_), do: "Cleared"

  defp receipt(%{status: :dismissed}), do: "Dismissed — it comes back if it happens again."
  defp receipt(%{outcome: :continued, agent_name: a}), do: "Continued — #{a} is back on it."
  defp receipt(%{outcome: :answered}), do: "Nothing was left to continue."
  defp receipt(%{agent_name: a}), do: "Cleared — #{a} is moving again."
end
