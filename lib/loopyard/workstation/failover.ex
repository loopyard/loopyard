defmodule Loopyard.Workstation.Failover do
  @moduledoc """
  Which accounts a workstation's agents may continue on when its plan is at its
  limit — an ordered list, set by a human on the workstation page, persisted as
  `<LOOPYARD_HOME>/workstations/<id>/failover.json` (`{"fallbacks": [...]}`).

  Whose plan pays for work matters, so this is OPT-IN and explicit: empty (the
  default) means failover is off for the account, and an agent is never moved
  onto an account that isn't named here. The list belongs to the account that
  is out of quota ("when `brad` is spent, `brad`'s agents may bill `jamie`"),
  so a chain only goes where each hop's own owner allowed.

  Reads tolerate a missing or corrupt file (no fallbacks) and drop names that
  no longer exist, so a deleted workstation can't be moved onto.
  """

  alias Loopyard.Workstation

  @doc "The ordered fallbacks of `id` (existing workstations only, never itself)."
  @spec fallbacks(String.t()) :: [String.t()]
  def fallbacks(id) when is_binary(id) do
    with true <- Workstation.valid_id?(id),
         {:ok, body} <- File.read(path(id)),
         {:ok, %{"fallbacks" => list}} when is_list(list) <- Jason.decode(body) do
      clean(id, list)
    else
      _ -> []
    end
  end

  def fallbacks(_), do: []

  @doc "Replace `id`'s fallbacks. Unknown names, duplicates and `id` itself are dropped."
  @spec put(String.t(), [String.t()]) :: :ok | {:error, :not_found}
  def put(id, list) when is_list(list) do
    if Workstation.exists?(id) do
      tmp = path(id) <> ".tmp"
      File.write!(tmp, Jason.encode!(%{"fallbacks" => clean(id, list)}))
      File.rename!(tmp, path(id))
      :ok
    else
      {:error, :not_found}
    end
  end

  @doc "Append `other` to `id`'s fallbacks (no-op if already there)."
  def add(id, other), do: put(id, fallbacks(id) ++ [other])

  @doc "Remove `other` from `id`'s fallbacks."
  def remove(id, other), do: put(id, List.delete(fallbacks(id), other))

  @doc "Move `other` one place earlier in `id`'s fallbacks."
  def raise_priority(id, other) do
    list = fallbacks(id)

    case Enum.find_index(list, &(&1 == other)) do
      i when is_integer(i) and i > 0 ->
        put(id, list |> List.delete_at(i) |> List.insert_at(i - 1, other))

      _ ->
        :ok
    end
  end

  @doc "A workstation was renamed: carry every list that named it to the new name."
  def rename_references(old, new) do
    Enum.each(Workstation.list(), fn id ->
      raw = raw(id)
      if old in raw, do: put(id, Enum.map(raw, &if(&1 == old, do: new, else: &1)))
    end)
  rescue
    _ -> :ok
  end

  defp raw(id) do
    with {:ok, body} <- File.read(path(id)),
         {:ok, %{"fallbacks" => list}} when is_list(list) <- Jason.decode(body) do
      list
    else
      _ -> []
    end
  end

  defp clean(id, list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == id))
    |> Enum.uniq()
    |> Enum.filter(&Workstation.exists?/1)
  end

  defp path(id), do: Path.join(Workstation.dir(id), "failover.json")
end
