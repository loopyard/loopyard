defmodule Loopyard.Harness.ACP.Connection.Modes do
  @moduledoc """
  Session-mode helpers for `Loopyard.Harness.ACP.Connection`: the two wire
  shapes a session's modes arrive in, and the switch request for each.

  ACP session modes (`modes.availableModes` / `modes.currentModeId` on the
  `session/new` and `session/load` results, switched with `session/set_mode`,
  pushed back as a `current_mode_update`) are how a harness exposes Claude
  Code's permission modes — `default`, `acceptEdits`, `plan`, … — to a
  client. claude-agent-acp also mirrors the same list as the `"mode"`
  config option (`category: "mode"`, switched with `session/set_config_option`).
  `extract_modes/1` normalizes either into one shape and reports which
  dialect to speak; the `modes` map wins when both are present because it's
  the spec'd one.

  Loopyard uses exactly one of these modes: the PLAN mode behind the
  composer's Discuss switch. `plan_mode_id/1` is the one place that
  vocabulary is known — a harness that names it differently is handled here,
  never in the UI.
  """

  alias Loopyard.Harness.ACP.Connection

  @typedoc ~S|One advertised mode, normalized: `%{"id", "name", "description"}`.|
  @type mode :: %{required(String.t()) => String.t() | nil}

  @doc """
  `{modes, current_id, dialect}` from a session result (or a
  `config_option_update` payload wrapped as `%{"configOptions" => …}`).
  Absent/malformed → `{[], nil, :set_mode}`.
  """
  @spec extract_modes(term()) :: {[mode()], String.t() | nil, :set_mode | :config_option}
  def extract_modes(%{"modes" => %{"availableModes" => available} = modes})
      when is_list(available) and available != [] do
    {Enum.map(available, &normalize_mode/1), modes["currentModeId"], :set_mode}
  end

  def extract_modes(result) when is_map(result) do
    case find_mode_config_option(result["configOptions"]) do
      %{"options" => opts} = opt when is_list(opts) and opts != [] ->
        modes =
          Enum.map(opts, fn o ->
            %{"id" => o["value"], "name" => o["name"], "description" => o["description"]}
          end)

        {modes, opt["currentValue"], :config_option}

      _ ->
        {[], nil, :set_mode}
    end
  end

  def extract_modes(_result), do: {[], nil, :set_mode}

  defp normalize_mode(m) when is_map(m),
    do: %{"id" => m["id"], "name" => m["name"], "description" => m["description"]}

  defp normalize_mode(_), do: %{"id" => nil, "name" => nil, "description" => nil}

  defp find_mode_config_option(options) when is_list(options),
    do: Enum.find(options, &(is_map(&1) and (&1["id"] == "mode" or &1["category"] == "mode")))

  defp find_mode_config_option(_), do: nil

  @doc """
  The id of the advertised PLAN mode (the harness reads and talks, never
  edits), or nil when the session has none. Matched by id first, then by a
  name that says "plan" — the vocabulary lives here, not in the UI.
  """
  @spec plan_mode_id([mode()]) :: String.t() | nil
  def plan_mode_id(modes) when is_list(modes) do
    by_id = Enum.find(modes, &(&1["id"] == "plan"))

    by_name =
      Enum.find(modes, fn m ->
        is_binary(m["name"]) and String.downcase(m["name"]) =~ "plan"
      end)

    case by_id || by_name do
      %{"id" => id} when is_binary(id) -> id
      _ -> nil
    end
  end

  def plan_mode_id(_), do: nil

  @doc "Whether `mode_id` is one the session advertises."
  def available?(modes, mode_id) when is_list(modes) and is_binary(mode_id),
    do: Enum.any?(modes, &(&1["id"] == mode_id))

  def available?(_modes, _mode_id), do: false

  # The dialect-appropriate mode-switch request. Response handling is shared
  # (pending tag :set_mode): success needs nothing, error reverts the display.
  def request_mode_switch(%{mode_dialect: :config_option} = state, mode_id) do
    Connection.request(state, "session/set_config_option", %{
      "sessionId" => state.session_id,
      "configId" => "mode",
      "value" => mode_id
    })
  end

  def request_mode_switch(state, mode_id) do
    Connection.request(state, "session/set_mode", %{
      "sessionId" => state.session_id,
      "modeId" => mode_id
    })
  end
end
