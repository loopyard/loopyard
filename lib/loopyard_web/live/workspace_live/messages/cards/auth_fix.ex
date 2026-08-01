defmodule LoopyardWeb.Live.WorkspaceLive.Messages.Cards.AuthFix do
  @moduledoc """
  The auth-recovery mini-app card. Appended ONCE per outage when the harness
  can't authenticate: calm instructions + the copyable one-line setup command
  (mints a 1-year token via browser OAuth and pushes it to the workstation),
  plus the Claude-page link for the manual path. The card is LIVE: when a turn
  finally completes — proof the new token works — it flips to a green
  "Authenticated" receipt in place. No banners, no red walls: the chat tells
  you what to do, you do it, the same card goes green.
  """
  use Phoenix.Component

  attr :msg, :map, required: true

  def auth_fix_card(assigns) do
    ~H"""
    <div class="py-2">
      <LoopyardWeb.Components.StreamCard.band tone={
        (@msg.status == :pending && :needs_you) || :neutral
      }>
        <LoopyardWeb.Components.StreamCard.header
          state={:needs_you}
          label_class={
            (@msg.status == :pending && "text-orange-700 dark:text-orange-400") ||
              "text-emerald-700 dark:text-emerald-400"
          }
        >
          <:label>
            {(@msg.status == :pending && "Needs a fresh Claude token") || "Authenticated"}
          </:label>
        </LoopyardWeb.Components.StreamCard.header>

        <div :if={@msg.status == :pending}>
          <p class="text-lead text-zinc-800 dark:text-zinc-100 mb-2.5">
            Claude can't authenticate, so agents are paused. Run this on your Mac —
            it opens a browser to authorize and pushes a 1-year token here:
          </p>
          <LoopyardWeb.Components.Workstation.command_box
            id={"auth-fix-#{@msg.id}"}
            command={"curl -fsS \"__ORIGIN__/workstations/#{@msg.workstation_id}/claude/setup.sh?token=#{Loopyard.PushToken.get()}\" | sh"}
          />
          <p class="text-lead text-zinc-500 dark:text-zinc-400 mt-2">
            Everything resumes on its own once the token lands — this card turns green.
            No terminal handy?
            <.link
              navigate={"/workstations/#{@msg.workstation_id}/claude"}
              class="text-violet-600 dark:text-violet-400 hover:underline"
            >
              paste a token on the Claude page →
            </.link>
          </p>
        </div>

        <div :if={@msg.status != :pending} class="flex items-center gap-2">
          <span
            aria-hidden="true"
            class="flex h-[18px] w-[18px] flex-none items-center justify-center rounded-full border-2 border-emerald-500 bg-emerald-500 text-white"
          >
            <svg
              viewBox="0 0 12 12"
              fill="none"
              stroke="currentColor"
              stroke-width="2.25"
              class="h-3 w-3"
            >
              <path d="M2.5 6.5 5 9l4.5-5.5" stroke-linecap="round" stroke-linejoin="round" />
            </svg>
          </span>
          <span class="text-lead text-emerald-800 dark:text-emerald-200">
            Token landed — agents are back and queued messages are sending.
          </span>
        </div>
      </LoopyardWeb.Components.StreamCard.band>
    </div>
    """
  end
end
