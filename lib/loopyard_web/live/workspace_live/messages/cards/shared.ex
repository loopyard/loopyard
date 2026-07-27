defmodule LoopyardWeb.Live.WorkspaceLive.Messages.Cards.Shared do
  @moduledoc """
  Helpers shared by more than one card submodule (see
  `LoopyardWeb.Live.WorkspaceLive.Messages.Cards`). Plain public functions,
  imported where needed.
  """

  @doc """
  Resolve a project NAME from a map carrying a `:project_id` (an approval
  action or an embed message — the agent state only carries workspace_id).
  nil if unresolvable — the caller then shows the workspace name alone
  rather than inventing a project.
  """
  def embed_project(%{project_id: pid}) when is_binary(pid) do
    case Loopyard.ProjectRegistry.get_project(pid) do
      %{name: n} -> n
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  def embed_project(_), do: nil
end
