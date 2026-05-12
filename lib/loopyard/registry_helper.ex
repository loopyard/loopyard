defmodule Loopyard.RegistryHelper do
  @moduledoc """
  Thin wrappers around Registry.lookup to reduce boilerplate.
  """

  @doc "Look up a single process in a unique registry."
  def whereis(registry, key) do
    case Registry.lookup(registry, key) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "GenServer.call through a registry, returning {:ok, result} or {:error, :not_found}."
  def call(registry, key, message, timeout \\ 5_000) do
    case whereis(registry, key) do
      {:ok, pid} ->
        try do
          {:ok, GenServer.call(pid, message, timeout)}
        catch
          :exit, _ -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc "GenServer.cast through a registry. Returns :ok whether the process exists or not."
  def cast(registry, key, message) do
    case whereis(registry, key) do
      {:ok, pid} -> GenServer.cast(pid, message)
      :error -> :ok
    end
  end
end
