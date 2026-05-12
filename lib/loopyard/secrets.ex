defmodule Loopyard.Secrets do
  @moduledoc """
  Named secret storage for Loopyard agents.

  Secrets are stored in `~/.loopyard/secrets.json` — a dedicated Loopyard config
  directory in the user's home, separate from any project directory.
  Secrets are never committed to version control.

  Agents request secrets at runtime via MCP tools rather than having
  them pre-injected into containers as environment variables.

  ## Scoping

  Each secret may carry an optional `scope` field — a list of workspace
  IDs and/or project IDs that are allowed to see the secret. When the
  list is empty or absent the secret is **global** (visible to every
  agent). When present, only agents whose workspace or project matches
  an entry in the list may `list` or `get` the secret.

  This prevents the "GitHub token for project X leaks into project Y"
  class of quiet cross-project secret drift. Callers that know the
  requesting agent's context pass `scope/2` to filter; callers that
  don't (admin/CLI/tests) use the unfiltered `list/0` and `get/1`.
  """

  defp storage_dir, do: Loopyard.Workspace.home_dir()
  @storage_file "secrets.json"

  @doc "Returns the path to the secrets storage file"
  def storage_path, do: Path.join(storage_dir(), @storage_file)

  @doc """
  List all secret keys and names (not values). Unscoped — returns every
  secret including scoped ones. Intended for admin UIs and tests.
  Agent-facing code should use `list/2`.
  """
  def list do
    case read_store() do
      {:ok, store} ->
        Enum.map(store, fn {key, entry} ->
          %{key: key, name: entry["name"] || key, scope: entry["scope"] || []}
        end)

      {:error, reason} ->
        log_store_error("list", reason)
        []
    end
  end

  @doc """
  List secrets visible to the agent at `workspace_id` / `project_id`.

  Returns globally-scoped secrets plus any secret whose `scope` list
  contains the workspace_id or project_id. A `nil` identifier means
  "this axis is unknown" — such secrets won't match on that axis.
  """
  def list(workspace_id, project_id) do
    Enum.filter(list(), fn entry ->
      visible_to?(entry.scope, workspace_id, project_id)
    end)
  end

  @doc """
  Unscoped `get` — returns the value regardless of scope. Intended for
  admin/CLI/tests. Agent-facing code should use `get/3`.
  """
  def get(key) do
    case read_store() do
      {:ok, store} ->
        case Map.get(store, key) do
          %{"value" => value} -> {:ok, value}
          nil -> :not_found
        end

      {:error, reason} ->
        log_store_error("get/1", reason)
        :not_found
    end
  end

  @doc """
  Get a secret value, scoped to the agent's workspace/project.

  Returns `:not_found` both when the secret doesn't exist AND when it
  exists but is scoped to other workspaces/projects — indistinguishable
  on purpose, so one agent can't probe for secret names belonging to
  another.
  """
  def get(key, workspace_id, project_id) do
    case read_store() do
      {:ok, store} ->
        case Map.get(store, key) do
          %{"value" => value} = entry ->
            scope = entry["scope"] || []

            if visible_to?(scope, workspace_id, project_id),
              do: {:ok, value},
              else: :not_found

          nil ->
            :not_found
        end

      {:error, reason} ->
        log_store_error("get/3", reason)
        :not_found
    end
  end

  @doc """
  Store a secret. Optional `scope` restricts visibility to a list of
  workspace IDs and/or project IDs. An empty list (the default) means
  the secret is global.
  """
  def put(key, name, value, scope \\ []) when is_list(scope) do
    store =
      case read_store() do
        {:ok, s} -> s
        _ -> %{}
      end

    entry = %{"name" => name, "value" => value, "scope" => scope}
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

  # If the secrets file is present but unreadable or invalid JSON, an
  # agent would otherwise see "no secrets" or "not found" and have no
  # way to know why its credentials are missing. Log once per call so
  # the user/operator can investigate.
  defp log_store_error(op, reason) do
    Loopyard.EventLog.error(
      "secrets",
      "Failed to read secrets store (#{op}): #{inspect(reason)}. " <>
        "Path: #{storage_path()}. Secrets appear empty until this is fixed."
    )
  end

  defp visible_to?(scope, _workspace_id, _project_id) when scope in [nil, []], do: true

  defp visible_to?(scope, workspace_id, project_id) when is_list(scope) do
    Enum.any?(scope, fn id ->
      (is_binary(workspace_id) and id == workspace_id) or
        (is_binary(project_id) and id == project_id)
    end)
  end

  defp visible_to?(_, _, _), do: false

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
    File.mkdir_p!(storage_dir())
    File.write!(path, Jason.encode!(store, pretty: true))
    :ok
  end
end
