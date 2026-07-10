defmodule Loopyard.ChatAgent.PartialText do
  @moduledoc """
  Preserve partial assistant text when a turn's stream is interrupted.

  When a stream errors, times out, is stopped by the user, or the CLI crashes
  mid-turn, any text accumulated from TextDelta events (`in_flight_partial`)
  was shown live in the browser but would vanish on refresh. `finalize/3`
  persists it as a truncated assistant message tagged `partial: true` with a
  "⚠ Truncated — …" marker, so what the viewer saw survives.

  Extracted from `StreamHandler` (which delegates to it) to keep that module
  under its size cap.
  """
  alias Loopyard.ChatAgent.Persistence
  alias Loopyard.Events

  @max_messages 1000

  @doc """
  Persist the in-flight partial as a truncated assistant message. No-op when
  there's no partial. Returns the state with `in_flight_partial` cleared.
  """
  def finalize(%{in_flight_partial: ""} = state, _id, _reason), do: state

  def finalize(%{in_flight_partial: partial} = state, id, reason)
      when is_binary(partial) and partial != "" do
    marker =
      case reason do
        :error -> "⚠ Truncated — CLI stream errored mid-response."
        :timeout -> "⚠ Truncated — CLI stopped responding mid-stream."
        :stopped_by_user -> "⚠ Truncated — user stopped the agent mid-response."
        other -> "⚠ Truncated — stream ended unexpectedly (#{inspect(other)})."
      end

    partial_msg = %{
      role: :assistant,
      content: partial <> "\n\n" <> marker,
      partial: true,
      timestamp: DateTime.utc_now()
    }

    {state, partial_msg} = append(state, partial_msg)
    Persistence.persist_message(state, partial_msg)

    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
      agent_id: id,
      msg: partial_msg
    })

    :telemetry.execute(
      [:loopyard, :agent, :partial_finalized],
      %{bytes: byte_size(partial)},
      %{agent_id: id, reason: reason}
    )

    %{state | in_flight_partial: ""}
  end

  def finalize(state, _id, _reason), do: state

  # Same O(1) prepend + cap as ChatAgent.append_message (the shared-helper
  # dedup across the ChatAgent modules is separately tracked).
  defp append(state, msg) do
    msg =
      Map.put_new_lazy(msg, :id, fn ->
        :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
      end)

    reversed = [msg | state.messages]

    reversed =
      if length(reversed) > @max_messages, do: Enum.take(reversed, @max_messages), else: reversed

    {%{state | messages: reversed}, msg}
  end
end
