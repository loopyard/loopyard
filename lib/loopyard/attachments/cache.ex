defmodule Loopyard.Attachments.Cache do
  @moduledoc """
  A small in-memory cache of attachment bytes for the thumbnail route.

  Stored names are unique and never rewritten, so a hit is always right.
  Without it, every thumbnail on a transcript for a STOPPED workspace costs a
  throwaway container launch (`VolumeIO` falls back to `docker run … cat`),
  eight thumbnails = eight containers per page load.

  Bounded crudely: when the table passes `@max_bytes` the whole thing is
  dropped — misses are cheap, bookkeeping isn't worth it. The ETS table is
  owned by `Loopyard.StateKeeper` (`:attachment_cache`).
  """

  @table :attachment_cache
  @max_bytes 32 * 1024 * 1024

  @doc "Read-through: the cached bytes for `key`, else `fun.()` (cached on `{:ok, bytes}`)."
  @spec fetch(term(), (-> {:ok, binary()} | {:error, term()})) ::
          {:ok, binary()} | {:error, term()}
  def fetch(key, fun) when is_function(fun, 0) do
    case lookup(key) do
      {:ok, _} = hit ->
        hit

      :miss ->
        case fun.() do
          {:ok, bytes} = ok when is_binary(bytes) ->
            put(key, bytes)
            ok

          other ->
            other
        end
    end
  end

  @doc false
  def lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, bytes}] -> {:ok, bytes}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc false
  def put(key, bytes) do
    if bytes_used() + byte_size(bytes) > @max_bytes, do: :ets.delete_all_objects(@table)
    :ets.insert(@table, {key, bytes})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drop everything (tests)."
  def clear, do: :ets.delete_all_objects(@table)

  defp bytes_used do
    case :ets.info(@table, :memory) do
      words when is_integer(words) -> words * :erlang.system_info(:wordsize)
      _ -> 0
    end
  end
end
