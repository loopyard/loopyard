defmodule Loopyard.Test.FakeContainerIO do
  @moduledoc """
  Process-dictionary stand-in for `Loopyard.ContainerIO` (the operator's
  attachment store). Same-process only — fine for unit and controller tests.
  Wired in `config/test.exs` via `:container_io`.
  """

  def copy_in(container, host_path, dest) do
    case File.read(host_path) do
      {:ok, bytes} ->
        Process.put({__MODULE__, container, dest}, bytes)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def write_file(container, path, content) do
    Process.put({__MODULE__, container, path}, content)
    :ok
  end

  def read_file(container, path) do
    case Process.get({__MODULE__, container, path}) do
      nil -> {:error, :not_found}
      bytes -> {:ok, bytes}
    end
  end

  @doc "Seed a file as if it were already in the container."
  def seed(container, path, bytes), do: write_file(container, path, bytes)
end
