defmodule LoopyardWeb.Live.ConsentUI do
  @moduledoc """
  The shared **consent surface** for any agent chat stream — the interactive
  cards where a human answers the agent: `ask_user`/AskUserQuestion **question
  cards** and `request_secret` **secret cards**. Both the workspace chat
  (`WorkspaceLive`) and the operator chat (`OperatorLive`) render the SAME cards
  (`workspace_live/messages/cards.ex`) and now answer them through the SAME
  handlers, attached here ONCE via `attach_hook/4` so the two streams can't
  drift. Add a new chat surface later → `attach/2` and it inherits every consent
  card for free.

  ## Usage

  In the LiveView's `mount/3`, after the base socket is assigned:

  socket = LoopyardWeb.Live.ConsentUI.attach(socket, secret_scope: workspace.id)

  `:secret_scope` is the workspace id a submitted secret is stored under — pass
  the workspace id in a workspace chat, or omit it (nil) for the operator, which
  has no workspace. The hook owns every consent event the cards emit:

  * question round-trip — `answer_question` (single-select), `toggle_question_option`
  (multi-select draft), `confirm_question` (multi Done), `answer_question_text`
  (Other…), `skip_question`;
  * secret round-trip — `submit_secret`, `cancel_secret`.

  Everything else falls through (`{:cont, socket}`) to the LiveView's own
  `handle_event/3`.

  Approval cards (`decide_approval`) are intentionally NOT shared here: the
  workspace uses the durable *queued* approval model (`Approvals.run/resolve`
  off the persisted card) and the operator the *blocking* one (`Approvals.decide`
  to a waiting tool). Those are different mechanisms, not drift — each LiveView
  keeps its own `decide_approval`. Only the harness-agnostic surfaces are shared.
  """
  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3]
  import Phoenix.Component, only: [assign: 3]

  alias Loopyard.Harness.{Questions, SecretRequests}

  @doc """
  Attach the consent `handle_event` hook + record the secret scope. Call once in
  `mount/3`. `:secret_scope` (a workspace id, or nil for the operator) is what
  `submit_secret` stores the masked value under.
  """
  def attach(socket, opts \\ []) do
    socket
    |> assign(:consent_secret_scope, Keyword.get(opts, :secret_scope))
    |> attach_hook(:consent_ui, :handle_event, &handle_consent/3)
  end

  # --- Question cards: the multi-question AskUserQuestion round-trip. Each button
  # settles ONE question via the broker (which broadcasts the per-question lock to
  # every viewer); the whole ask resolves — and the card flips to :answered — only
  # when every question is answered or skipped. ---

  defp handle_consent(
         "answer_question",
         %{"question_id" => qid, "q" => q_id, "option" => option},
         socket
       ),
       do: settle(socket, Questions.answer_partial(qid, q_id, [option]))

  # Single-select tap = DRAFT (highlight, broadcast) — commits only via the
  # Answer button. Tap-to-commit dropped typed Other text; never again.
  #
  # This arrives as the option form's phx-change, so it reports the CURRENT
  # state of the inputs rather than a click. The browser has already drawn the
  # selection by the time this lands — the draft exists for the other viewers
  # and for durability, and nothing on this screen waits for the reply.
  defp handle_consent(
         "draft_question_option",
         %{"question_id" => qid, "q" => q_id, "option" => option},
         socket
       ),
       do: settle(socket, Questions.draft_option(qid, q_id, option))

  defp handle_consent(
         "draft_question_option",
         %{"question_id" => qid, "q" => q_id, "options" => options},
         socket
       )
       when is_list(options),
       do: settle(socket, Questions.set_draft(qid, q_id, options))

  # Every box cleared — a change event with no option key at all.
  defp handle_consent(
         "draft_question_option",
         %{"question_id" => qid, "q" => q_id},
         socket
       ),
       do: settle(socket, Questions.set_draft(qid, q_id, []))

  # Focusing the "Other" box IS selecting it: clear any drafted option so the
  # rows deselect (broadcast — every viewer sees the switch).
  defp handle_consent(
         "draft_question_other",
         %{"question_id" => qid, "q" => q_id},
         socket
       ),
       do: settle(socket, Loopyard.Harness.Questions.clear_draft(qid, q_id))

  defp handle_consent("skip_question", %{"question_id" => qid, "q" => q_id}, socket),
    do: settle(socket, Questions.answer_partial(qid, q_id, []))

  defp handle_consent(
         "toggle_question_option",
         %{"question_id" => qid, "q" => q_id, "option" => option},
         socket
       ),
       # Multi-select draft toggle — broadcast, but the question stays open until
       # its Done button confirms.
       do: settle(socket, Questions.toggle_option(qid, q_id, option))

  defp handle_consent("confirm_question", %{"question_id" => qid, "q" => q_id}, socket),
    do: settle(socket, Questions.confirm_question(qid, q_id))

  defp handle_consent(
         "answer_question_text",
         %{"question_id" => qid, "q" => q_id, "text" => text},
         socket
       ) do
    # The Answer button: typed text wins; BLANK text commits the drafted
    # option (still a no-op when nothing is drafted — Skip stays explicit).
    case String.trim(text) do
      "" -> settle(socket, Questions.commit_draft(qid, q_id))
      trimmed -> settle(socket, Questions.answer_partial(qid, q_id, [trimmed]))
    end
  end

  # --- Secret cards: the masked value goes straight to the scoped on-disk store
  # and the broker signals the blocked agent with only the KEY — the value is
  # never assigned, broadcast, or returned here, so it stays out of the
  # transcript. `value` is dropped immediately after this call. ---

  defp handle_consent("submit_secret", %{"request_id" => rid, "secret" => value}, socket) do
    case SecretRequests.submit(rid, value, socket.assigns[:consent_secret_scope], nil) do
      {:ok, _key} ->
        {:halt, socket}

      {:error, :not_found} ->
        {:halt, put_flash(socket, :info, "That secret request is no longer waiting.")}
    end
  end

  defp handle_consent("cancel_secret", %{"request_id" => rid}, socket) do
    # The human declined — flip the card to :declined for everyone and let the
    # agent's turn resume so it stops asking.
    SecretRequests.cancel(rid, nil)
    {:halt, socket}
  end

  # Not a consent event — let the LiveView's own handle_event/3 take it.
  defp handle_consent(_event, _params, socket), do: {:cont, socket}

  defp settle(socket, :ok), do: {:halt, socket}

  defp settle(socket, :noop),
    do:
      {:halt,
       put_flash(
         socket,
         :info,
         "Nothing selected yet — tap an option (or type your own), then Answer."
       )}

  defp settle(socket, {:error, :not_found}),
    do: {:halt, put_flash(socket, :info, "That question was already answered.")}
end
