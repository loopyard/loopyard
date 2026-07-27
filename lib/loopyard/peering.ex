defmodule Loopyard.Peering do
  @moduledoc """
  Workspace PEERING — human-approved grants that let one workspace's agents
  message another workspace's agents directly (`send_to_workspace`), instead of
  relaying everything through the operator.

  The security model mirrors the rest of the consent architecture: an agent may
  PROPOSE a peering (`propose_peering` → approval card), only a human approves,
  and every delivered message carries its provenance. Grants are DIRECTED
  (from_ws → to_ws); the standard proposal asks for the pair (both directions)
  because coordination is usually a conversation.

  Persistence: `~/.loopyard/peering.json` — tiny, read per send (low traffic),
  no ETS to own. Revocation: delete the entry (UI affordance is future work;
  `revoke/2` exists for the console).
  """

  def path, do: Path.join(Loopyard.Workspace.home_dir(), "peering.json")

  @doc "All grants: a list of %{\"from\" => ws_id, \"to\" => ws_id}."
  def load do
    case File.read(path()) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, list} when is_list(list) -> list
          _ -> []
        end

      _ ->
        []
    end
  end

  def granted?(from_ws, to_ws) when is_binary(from_ws) and is_binary(to_ws) do
    Enum.any?(load(), &(&1["from"] == from_ws and &1["to"] == to_ws))
  end

  @doc "Grant both directions between two workspaces (the standard approval outcome)."
  def grant_pair(ws_a, ws_b) when is_binary(ws_a) and is_binary(ws_b) do
    locked(fn ->
      load()
      |> Kernel.++([%{"from" => ws_a, "to" => ws_b}, %{"from" => ws_b, "to" => ws_a}])
      |> Enum.uniq()
      |> write()
    end)
  end

  def revoke(from_ws, to_ws) do
    locked(fn ->
      load()
      |> Enum.reject(&(&1["from"] == from_ws and &1["to"] == to_ws))
      |> write()
    end)
  end

  # Serialize read-modify-write cycles: two concurrent grants (or a grant
  # racing a revoke) were last-writer-wins — one mutation silently vanished.
  # Single-node app; a global lock is ownership enough without a GenServer.
  defp locked(fun), do: :global.trans({{__MODULE__, :store}, self()}, fun)

  @doc "Workspace ids this workspace may send to."
  def peers_of(ws_id), do: load() |> Enum.filter(&(&1["from"] == ws_id)) |> Enum.map(& &1["to"])

  defp write(grants) do
    File.mkdir_p!(Path.dirname(path()))
    File.write!(path(), Jason.encode!(grants, pretty: true))
    :ok
  end
end
