defmodule BoomLooper.WorkspaceRegistry do
  @moduledoc """
  Simple registry of workspace paths. Each workspace is a directory
  on disk that agents can be launched against.

  Stored in ETS — no persistence across restarts.
  """

  @ets_table :workspace_registry

  def ensure_ets_table do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:named_table, :public, :set])
    end

    :ok
  end

  @doc "Add a workspace by path. Returns {:ok, workspace} or {:error, reason}"
  def add(path) do
    path = Path.expand(path)

    if File.dir?(path) do
      ensure_ets_table()
      id = BoomLooper.Workspace.workspace_id(path)

      name =
        case BoomLooper.Workspace.load(path) do
          {:ok, ws} when ws.name != nil -> ws.name
          _ -> Path.basename(path)
        end

      workspace = %{
        id: id,
        path: path,
        name: name,
        added_at: DateTime.utc_now()
      }

      :ets.insert(@ets_table, {id, workspace})
      {:ok, workspace}
    else
      {:error, "Directory does not exist: #{path}"}
    end
  end

  @doc "Remove a workspace by ID"
  def remove(id) do
    ensure_ets_table()
    :ets.delete(@ets_table, id)
    :ok
  end

  @doc "List all workspaces"
  def list do
    ensure_ets_table()

    :ets.tab2list(@ets_table)
    |> Enum.map(fn {_id, ws} -> ws end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Get a workspace by ID"
  def get(id) do
    ensure_ets_table()

    case :ets.lookup(@ets_table, id) do
      [{^id, ws}] -> ws
      [] -> nil
    end
  end
end
