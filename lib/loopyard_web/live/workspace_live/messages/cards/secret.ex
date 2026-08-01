defmodule LoopyardWeb.Live.WorkspaceLive.Messages.Cards.Secret do
  @moduledoc """
  The `request_secret` **secret** card. Split out of
  `LoopyardWeb.Live.WorkspaceLive.Messages.Cards` — see that module for the
  card family overview. Template-only; no socket/PubSub.
  """
  use Phoenix.Component

  @doc """
  The agent asked for a SECRET (api key / token) via `request_secret`. A masked
  input card: the value goes straight to the on-disk secret store and NEVER into
  the chat — every viewer sees the request and that it was submitted, never the
  value. Submitting flips the card to "Submitted" for the whole room.
  """
  def secret_card(assigns) do
    ~H"""
    <div class="py-2">
      <LoopyardWeb.Components.StreamCard.band tone={
        (@msg.status == :pending && :needs_you) || :neutral
      }>
        <LoopyardWeb.Components.StreamCard.header
          state={:needs_you}
          label_class={
            (@msg.status == :pending && "text-orange-700 dark:text-orange-400") ||
              "text-zinc-500 dark:text-zinc-400"
          }
        >
          <:label>
            <svg
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 16 16"
              fill="currentColor"
              class="w-3.5 h-3.5"
            >
              <path
                fill-rule="evenodd"
                d="M8 1a3 3 0 0 0-3 3v2H4.5A1.5 1.5 0 0 0 3 7.5v5A1.5 1.5 0 0 0 4.5 14h7a1.5 1.5 0 0 0 1.5-1.5v-5A1.5 1.5 0 0 0 11.5 6H11V4a3 3 0 0 0-3-3Zm1.5 5V4a1.5 1.5 0 1 0-3 0v2h3Z"
                clip-rule="evenodd"
              />
            </svg>
            {case @msg.status do
              :pending -> "Needs a secret"
              :timeout -> "No secret"
              _ -> "Secret received"
            end}
          </:label>
        </LoopyardWeb.Components.StreamCard.header>

        <div class="text-lead font-medium leading-snug text-zinc-800 dark:text-zinc-200">
          <span class="font-mono">{@msg.name}</span>
        </div>
        <div
          :if={@msg[:why] not in [nil, ""]}
          class="text-lead mt-0.5 text-zinc-500 dark:text-zinc-400"
        >
          {@msg.why}
        </div>

        <%!-- The whole room sees this field, but only the submitter's browser sends
    the value, and it goes straight to disk — never into the transcript. The
    field is named "secret", which is in `filter_parameters` so it's redacted
    from server logs too. --%>
        <div :if={@msg.status == :pending}>
          <form phx-submit="submit_secret" autocomplete="off" class="mt-3 flex items-center gap-2">
            <input type="hidden" name="request_id" value={@msg.request_id} />
            <input
              type="password"
              name="secret"
              autocomplete="off"
              spellcheck="false"
              placeholder={"Paste #{@msg.name}…"}
              aria-label={"Secret value for #{@msg.name}"}
              class="flex-1 min-w-0 rounded-sm border border-orange-300 dark:border-orange-700/60 bg-brand-paper dark:bg-brand-ink px-3 py-2 text-lead font-mono text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 focus:outline-none focus:ring-2 focus:ring-orange-500/30"
            />
            <button
              type="submit"
              class="focus-ring flex-none rounded-sm bg-orange-600 hover:bg-orange-700 px-3.5 py-2 text-lead font-medium text-white transition-colors"
            >
              Submit
            </button>
          </form>
          <%!-- Escape hatch: you don't have it / won't provide it. Resumes the
    agent's turn so it stops waiting and moves on. --%>
          <button
            type="button"
            phx-click="cancel_secret"
            phx-value-request_id={@msg.request_id}
            class="focus-ring mt-2 text-lead text-zinc-500 dark:text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200"
          >
            I don't have it — skip
          </button>
        </div>

        <div
          :if={@msg.status == :declined}
          class="mt-3 text-lead text-zinc-500 dark:text-zinc-400"
        >
          Declined — the agent will proceed without it.
        </div>

        <div
          :if={@msg.status == :submitted}
          class="mt-3 inline-flex items-center gap-1.5 rounded-sm bg-emerald-500/15 px-3 py-1.5 text-lead font-medium text-emerald-600 dark:text-emerald-400"
        >
          <span>✓</span>
          {if @msg[:submitted_by] in [nil, ""],
            do: "Submitted — stored securely, not shown in chat.",
            else: "Submitted by #{@msg.submitted_by} — kept out of chat."}
        </div>

        <div :if={@msg.status == :timeout} class="mt-3 text-lead text-zinc-500 dark:text-zinc-400">
          No secret submitted — the agent moved on.
        </div>
      </LoopyardWeb.Components.StreamCard.band>
    </div>
    """
  end
end
