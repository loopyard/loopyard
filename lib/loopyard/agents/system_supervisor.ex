defmodule Loopyard.Agents.SystemSupervisor do
  @moduledoc """
  Top-level DynamicSupervisor for the per-identity `Loopyard.Agents.SystemGroup`s
  — the system-agent counterpart of `Loopyard.WorkspaceSupervisor`.
  """
  use DynamicSupervisor

  alias Loopyard.Agents.SystemGroup

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Ensure the group for `identity` is up. Serialised per identity (two
  concurrent boots of the same identity's agents must not race to start two
  groups). Returns `{:ok, pid}`.
  """
  def ensure_group(identity) when is_binary(identity) do
    :global.trans({{__MODULE__, identity}, self()}, fn ->
      case SystemGroup.whereis(identity) do
        nil ->
          case DynamicSupervisor.start_child(__MODULE__, {SystemGroup, identity: identity}) do
            {:ok, pid} -> {:ok, pid}
            {:error, {:already_started, pid}} -> {:ok, pid}
            {:error, reason} -> {:error, reason}
          end

        pid ->
          {:ok, pid}
      end
    end)
  end
end
