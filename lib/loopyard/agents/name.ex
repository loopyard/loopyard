defmodule Loopyard.Agents.Name do
  @moduledoc """
  Agent names are the harness brand — "Claude", "Codex" — because the
  agent *is* the harness, not a mascot. A workspace usually has exactly
  one agent; a second of the same harness gets a numeric suffix
  ("Claude 2"). Users can rename freely afterward (`ChatAgent.rename/2`).

  Lives backend-side so both the LiveView spawn path and the
  fork/onboarding spawn path share one source of truth.
  """

  alias Loopyard.Harness

  @doc """
  A name for a new agent in `ws_id`, derived from its harness `backend`
  module and deduped against agents already in that workspace. `nil`
  backend falls back to the default harness label ("Claude").
  """
  @spec for_workspace(String.t() | nil, module() | nil) :: String.t()
  def for_workspace(ws_id, backend \\ nil) do
    backend
    |> label_for()
    |> dedupe(existing_names(ws_id))
  end

  @doc "The human harness label for a backend module."
  @spec label_for(module() | nil) :: String.t()
  def label_for(Harness.Claude), do: "Claude"
  def label_for(Harness.ACP), do: "Claude"
  def label_for(Harness.Fake), do: "Claude"
  # Any future harness module (e.g. Backend.Codex) → its last name segment.
  def label_for(mod) when is_atom(mod) and not is_nil(mod), do: mod |> Module.split() |> List.last()
  def label_for(_), do: "Claude"

  @doc """
  Return `base` if free in `taken`, else the first `"base N"` (N≥2)
  that isn't taken. Public for testing.
  """
  @spec dedupe(String.t(), [String.t()]) :: String.t()
  def dedupe(base, taken) do
    if base in taken do
      n = Stream.iterate(2, &(&1 + 1)) |> Enum.find(&("#{base} #{&1}" not in taken))
      "#{base} #{n}"
    else
      base
    end
  end

  defp existing_names(nil), do: []

  defp existing_names(ws_id) do
    Loopyard.ChatAgent.list_agents()
    |> Enum.filter(&(&1[:workspace_id] == ws_id))
    |> Enum.map(& &1[:name])
    |> Enum.reject(&is_nil/1)
  end
end
