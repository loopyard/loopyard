defmodule Loopyard.ChatAgent.ModelControl do
  @moduledoc """
  Model switching for a ChatAgent — the UI's Usage-panel Model row.

  `switch/2` applies a new model to the LIVE session (via the backend's
  `set_model/2`, a no-op for backends that don't support it), persists the
  choice into `session_opts` so restarts/resumes keep it, and returns the
  updated state (ETS + ETF-log + broadcast side effects done). Split out of
  `Loopyard.ChatAgent` for the module-size invariant; the `{:set_model, id}`
  cast is a 1-liner that delegates here.
  """

  alias Loopyard.ChatAgent.Persistence
  alias Loopyard.Events

  @ets_table :chat_agents

  @doc "Switch `state`'s model to `model_id`. Returns the updated state."
  def switch(state, model_id) do
    # Live switch on the running session (backends without set_model no-op),
    # persisted into session_opts so every future spawn/resume keeps it.
    if state.session && function_exported?(state.backend, :set_model, 2) do
      state.backend.set_model(state.session, model_id)
    end

    label = model_label(state, model_id)

    state = %{
      state
      | model: label,
        session_opts: Keyword.put(state.session_opts || [], :model, model_id)
    }

    :ets.insert(@ets_table, {state.id, Loopyard.ChatAgent.summary(state)})
    Persistence.persist_agent(state, &Loopyard.ChatAgent.summary/1)
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: state.status})
    Loopyard.EventLog.info("agent:#{state.name}", "Model switched to #{label}")
    state
  end

  # Display value for a model id. When the backend's model list carries a
  # description (adapter aliases like "opus" → "Opus 4.6"), use it. Otherwise
  # return the id VERBATIM — full frontier ids ("claude-opus-4-8") aren't in the
  # adapter list, and the UI's short_model/1 maps them to "Opus 4.8". Do NOT
  # capitalize (that produced the ugly "Claude-opus-4-8").
  defp model_label(state, model_id) do
    with true <- state.session != nil,
         true <- function_exported?(state.backend, :available_models, 1),
         models when is_list(models) <- state.backend.available_models(state.session),
         %{description: d} when is_binary(d) and d != "" <-
           Enum.find(models, &(&1.id == model_id)) do
      d |> String.split("·") |> hd() |> String.trim()
    else
      _ -> model_id
    end
  end
end
