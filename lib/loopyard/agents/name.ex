defmodule Loopyard.Agents.Name do
  @moduledoc """
  Random two-word agent names (e.g. "Swift Fern"). Lives backend-side so both
  the LiveView spawn path and the fork/onboarding spawn path share one source.
  """
  @adjectives ~w(Swift Bright Calm Deep Quick Sharp Keen Bold Clear True)
  @nouns ~w(Spark Drift Pulse Wave Bloom Forge Sage Fern Tide Mesa)

  @doc "A fresh random two-word name."
  @spec generate() :: String.t()
  def generate, do: "#{Enum.random(@adjectives)} #{Enum.random(@nouns)}"
end
