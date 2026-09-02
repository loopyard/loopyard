defmodule Loopyard.Notifications.Retract do
  @moduledoc """
  Withdrawing a DECISION that no longer needs making — without a kill.

  The review found the only cancel primitive (`Questions.cancel_for_agent/1`)
  kills waiter tasks and stamps `:timeout`, and only fires once the agent is
  already idle. A retract has to work mid-turn, while the agent is blocked
  inside `ask_user` / `propose_*` / `request_secret`: it answers the ask
  through the broker's own reply path (the way a timeout does) so the turn
  continues, and flips the card to `:retracted` with the reason, so every
  viewer sees WHY it went away. The inbox item settles as `:retracted` after
  this succeeds (`Loopyard.Notifications.retract/2`).
  """

  alias Loopyard.Harness.{Approvals, Questions, SecretRequests}
  alias Loopyard.Notifications.Item

  @doc "Retract the card behind a decision item. Idempotent; never raises."
  @spec card(Item.t(), String.t()) :: :ok
  def card(%Item{kind: :question, id: qid}, reason), do: Questions.retract(qid, reason)

  def card(%Item{kind: :approval, id: id, agent_id: aid, msg_id: mid}, reason),
    do: Approvals.retract(id, aid, mid, reason)

  def card(%Item{kind: :secret, id: rid}, reason) do
    SecretRequests.cancel(rid, "retracted — " <> reason)
    :ok
  end

  def card(_, _), do: :ok
end
