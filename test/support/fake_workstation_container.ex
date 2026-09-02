defmodule Loopyard.Test.FakeWorkstationContainer do
  @moduledoc """
  Stands in for `Loopyard.Workstation.Container` in tests: "ensuring" a
  workstation container is instant and needs no Docker. Configured via
  `config :loopyard, workstation_container: Loopyard.Test.FakeWorkstationContainer`.
  """

  def ensure_up(identity), do: {:ok, "fake-ws-" <> identity}
  def name(identity), do: "fake-ws-" <> identity
  def running?(_identity), do: true
end
