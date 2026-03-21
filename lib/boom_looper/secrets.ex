defmodule BoomLooper.Secrets do
  @moduledoc """
  Named secret storage for BoomLooper agents.

  Secrets are stored in `~/.boomlooper/secrets.json` — a dedicated BoomLooper config
  directory in the user's home, separate from any project directory.
  Secrets are never committed to version control.

  Agents request secrets at runtime via MCP tools rather than having
  them pre-injected into containers as environment variables.
  """

  @storage_dir Path.join(System.user_home!(), ".boomlooper")
  @storage_file "secrets.json"

  @doc "Returns the path to the secrets storage file"
  def storage_path, do: Path.join(@storage_dir, @storage_file)

  @doc "List all secret keys and names (not values)"
  def list do
    case read_store() do
      {:ok, store} ->
        Enum.map(store, fn {key, entry} ->
          %{key: key, name: entry["name"] || key}
        end)

      _ ->
        []
    end
  end

  @doc "Get a secret value by key"
  def get(key) do
    case read_store() do
      {:ok, store} ->
        case Map.get(store, key) do
          %{"value" => value} -> {:ok, value}
          nil -> :not_found
        end

      _ ->
        :not_found
    end
  end

  @doc "Store a secret"
  def put(key, name, value) do
    store = case read_store() do
      {:ok, s} -> s
      _ -> %{}
    end

    entry = %{"name" => name, "value" => value}
    store = Map.put(store, key, entry)
    write_store(store)
  end

  @doc "Delete a secret by key"
  def delete(key) do
    case read_store() do
      {:ok, store} ->
        store = Map.delete(store, key)
        write_store(store)

      _ ->
        :ok
    end
  end

  # --- Private ---

  defp read_store do
    path = storage_path()

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, store} when is_map(store) -> {:ok, store}
          _ -> {:error, :invalid_json}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_store(store) do
    path = storage_path()
    File.mkdir_p!(@storage_dir)
    File.write!(path, Jason.encode!(store, pretty: true))
    :ok
  end
end
