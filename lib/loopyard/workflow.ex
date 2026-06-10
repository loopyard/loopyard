defmodule Loopyard.Workflow do
  @moduledoc """
  Confirmation-gated workflow verbs (#10/#15/#17) — the boundary-crossing
  operations that must be human-approved (the agent-spawns-workspaces guardrail).

  `fork/4` and `integrate/4` run a **confirmation policy** before executing. The
  policy is pluggable via `opts[:confirm]`:

    * `:auto` (default) — approve (in-sandbox/dev, or when no human gate is wired).
    * a `(action :: map -> :approve | :deny)` function — the UI passes one that
      renders the action as an **editable mini-app card** in the chat stream and
      blocks on a human decision (answerable from any device, #7 / Foundation C).

  The `action` map handed to the policy is exactly what the card renders
  (`%{verb, project_id, ...}`), so the human can review (and the UI can let them
  edit) the proposal before approving. Denied → `{:error, :denied}`, nothing runs.

  Routine in-sandbox operations (editing code, evolving the dev env) are NOT
  gated — only boundary crossings (new workspace, merge to main) come through here.
  """
  alias Loopyard.{Onboarding, CanonicalRepo}

  @type decision :: :approve | :deny
  @type policy :: :auto | (map() -> decision())

  @doc "Fork a new branch + workspace from `base`, gated by confirmation."
  @spec fork(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def fork(project_id, base, branch, opts \\ []) do
    action = %{verb: :fork, project_id: project_id, base: base, branch: branch}
    gate(action, opts, fn -> Onboarding.fork(project_id, base, branch) end)
  end

  @doc "Integrate a workspace's branch into canonical `main`, gated by confirmation."
  @spec integrate(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def integrate(project_id, workspace_id, branch, opts \\ []) do
    action = %{
      verb: :integrate,
      project_id: project_id,
      workspace_id: workspace_id,
      branch: branch
    }

    gate(action, opts, fn -> CanonicalRepo.integrate(project_id, workspace_id, branch) end)
  end

  # --- internals ---

  defp gate(action, opts, run) do
    case decide(Keyword.get(opts, :confirm, :auto), action) do
      :approve -> run.()
      :deny -> {:error, :denied}
    end
  end

  defp decide(:auto, _action), do: :approve
  defp decide(fun, action) when is_function(fun, 1), do: fun.(action)
end
