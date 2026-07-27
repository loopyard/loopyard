defmodule LoopyardWeb.Live.WorkspaceLive.Messages.Cards do
  @moduledoc """
  The two interactive mini-app cards rendered inline in the chat — the
  `ask_user` **question** card and the boundary-crossing **approval** card
  (fork / integrate / delete-workspace). Extracted from
  `LoopyardWeb.Live.WorkspaceLive.Messages` to keep that file under its line
  cap; `chat_msg/1` delegates the `:question` and `:approval` roles here.

  Both are persisted + broadcast (multiplayer): the card — and its resolved
  outcome — shows for the whole room. Template-only; no socket/PubSub.

  This module is now a facade: each card lives in its own submodule under
  `cards/` (`Cards.Question`, `Cards.Secret`, `Cards.Approval`,
  `Cards.AgentEmbed`, with cross-card helpers in `Cards.Shared`). Callers
  keep using `Cards.*` via the delegates below.
  """

  alias LoopyardWeb.Live.WorkspaceLive.Messages.Cards.{
    AgentEmbed,
    Approval,
    Question,
    Secret
  }

  defdelegate question_card(assigns), to: Question
  defdelegate question_block(assigns), to: Question
  defdelegate secret_card(assigns), to: Secret
  defdelegate approval_card(assigns), to: Approval
  defdelegate agent_embed(assigns), to: AgentEmbed
end
