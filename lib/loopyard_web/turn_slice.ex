defmodule LoopyardWeb.TurnSlice do
  @moduledoc """
  Resolves a message id to what its permalink should show.

  Two shapes, decided by the anchor's role:

  * the anchor is a `:user` prompt → a whole **turn**: that prompt through
  everything below it, up to (not including) the next user prompt. This is
  the shareable "prompt → result" link.
  * the anchor is anything else → just that **single** message. Linking a
  specific reply / mini-app / tool output shares only that artifact.

  Shared by `LoopyardWeb.MessageLive` (the streaming turn page) and
  `LoopyardWeb.OutputController` (the raw-text download) so both agree on what a
  link resolves to.
  """
  alias Loopyard.ChatAgent

  @type mode :: :turn | :single

  @doc """
  Resolve `msg_id` within `agent_id` to `{mode, messages, anchor}`.

  `messages` is oldest→newest (the turn, or the single message). Returns
  `{:single, [], nil}` when the id isn't found.
  """
  @spec resolve(String.t(), String.t()) :: {mode, list(), map() | nil}
  def resolve(agent_id, msg_id) do
    msgs = (ChatAgent.get_state(agent_id) || %{})[:messages] || []

    case Enum.find_index(msgs, &(&1[:id] == msg_id)) do
      nil ->
        {:single, [], nil}

      idx ->
        anchor = Enum.at(msgs, idx)

        if anchor[:role] == :user do
          tail_len =
            msgs
            |> Enum.drop(idx + 1)
            |> Enum.find_index(&(&1[:role] == :user))
            |> case do
              nil -> length(msgs) - idx - 1
              n -> n
            end

          {:turn, Enum.slice(msgs, idx, tail_len + 1), anchor}
        else
          {:single, [anchor], anchor}
        end
    end
  end
end
