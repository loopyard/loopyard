defmodule Loopyard.Harness.ACP.Connection.Models do
  @moduledoc """
  Model/session helpers for `Loopyard.Harness.ACP.Connection`: wire-method
  classification, capability checks, and the two model-list wire dialects.

  Two dialects: legacy claude-code-acp puts a `models` map
  (`availableModels`/`currentModelId`) in the session result and switches
  via `session/set_model`; claude-agent-acp (0.60+) reports `configOptions`
  (the `"model"` entry: `options`/`currentValue`) and switches via
  `session/set_config_option`. `extract_models/1` normalizes both into the
  legacy internal shape and reports which dialect to speak.
  """

  alias Loopyard.Harness.ACP.Connection

  def method_kind("initialize"), do: :initialize
  def method_kind("session/new"), do: :session_new
  def method_kind("session/load"), do: :session_load
  def method_kind("session/prompt"), do: :session_prompt
  def method_kind(other), do: other

  # Whether the adapter advertised it can replay a saved session (session/load).
  # Absent → false → we use session/new. Guards against booting session/load
  # against an adapter that doesn't support it.
  def load_supported?(msg) do
    caps = get_in(msg, ["result", "agentCapabilities"]) || %{}
    caps["loadSession"] == true
  end

  def extract_models(result) when is_map(result) do
    case find_model_config_option(result["configOptions"]) do
      %{"options" => opts} = opt when is_list(opts) ->
        models =
          Enum.map(opts, fn o ->
            %{"modelId" => o["value"], "name" => o["name"], "description" => o["description"]}
          end)

        {models, opt["currentValue"], :config_option}

      _ ->
        {get_in(result, ["models", "availableModels"]) || [],
         get_in(result, ["models", "currentModelId"]), :set_model}
    end
  end

  def extract_models(_result), do: {[], nil, :set_model}

  defp find_model_config_option(options) when is_list(options),
    do: Enum.find(options, &(is_map(&1) and &1["id"] == "model"))

  defp find_model_config_option(_), do: nil

  # The dialect-appropriate model-switch request. Response handling is shared
  # (pending tag :set_model): success needs nothing, error reverts the display.
  def request_model_switch(%{model_dialect: :config_option} = state, model_id) do
    Connection.request(state, "session/set_config_option", %{
      "sessionId" => state.session_id,
      "configId" => "model",
      "value" => model_id
    })
  end

  def request_model_switch(state, model_id) do
    Connection.request(state, "session/set_model", %{
      "sessionId" => state.session_id,
      "modelId" => model_id
    })
  end

  # id → human name from the adapter's model list (description's leading
  # segment before "·", else the entry's name). nil when unknown.
  def model_name(models, id) when is_list(models) and is_binary(id) do
    case Enum.find(models, &(&1["modelId"] == id)) do
      %{"description" => d} when is_binary(d) and d != "" ->
        d |> String.split("·") |> hd() |> String.trim()

      %{"name" => n} when is_binary(n) and n != "" ->
        n

      _ ->
        nil
    end
  end

  def model_name(_models, _id), do: nil
end
