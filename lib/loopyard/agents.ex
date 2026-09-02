defmodule Loopyard.Agents do
  @moduledoc """
  Every agent Loopyard runs, whatever its scope. An agent is stamped from a
  `Loopyard.Agents.Template`; its SCOPE is where it lives:

    * `:workspace` — bound to one project workspace (the work container on the
      code volume, the workspace's agent log, the workspace's supervision group).
    * `:system` — workspace-less, bound to a workstation identity (the
      workstation container, the identity's agents log). The operator is the
      first of these.

  `scope/1` is the ONE place that derivation lives. Every other reader asks
  the summary's `:scope` field and falls back here for rows written before the
  field existed.
  """

  @type scope :: :workspace | :system

  @doc "The scope of an agent summary/state map."
  @spec scope(map()) :: scope()
  def scope(%{scope: scope}) when scope in [:workspace, :system], do: scope
  def scope(%{workspace_id: ws}) when is_binary(ws), do: :workspace
  def scope(_), do: :system

  @doc """
  The key its supervision + persistence hang off: a workspace id, or
  `{:system, workstation_identity}`.
  """
  @spec scope_key(map()) :: String.t() | {:system, String.t()}
  def scope_key(%{workspace_id: ws} = summary) when is_binary(ws) do
    if scope(summary) == :workspace, do: ws, else: {:system, identity(summary)}
  end

  def scope_key(summary), do: {:system, identity(summary)}

  defp identity(%{workstation_identity: id}) when is_binary(id), do: id
  defp identity(_), do: Loopyard.Workstation.current()
end
