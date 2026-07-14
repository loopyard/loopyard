defmodule Loopyard.Operator do
  @moduledoc """
  The **operator agent** — a per-workstation (per-user) control-plane agent. It
  is a completely normal `ChatAgent` under the covers: same GenServer, same work
  container (mounting the workstation's `$HOME` for GH/Claude creds), same boot
  path. The only differences, per the design in [plans/gbrain-onboarding.md]:

    * its toolkit is `Tools.ControlPlane` (create projects, gated) instead of the
      container toolkit — so it structurally cannot set up code itself;
    * a focused system prompt;
    * it lives in a reserved, hidden "Operator" workspace (blank repo) that's
      filtered out of the normal project/workspace lists.

  `ensure_agent/1` is the single entry point: idempotently ensures the reserved
  workspace + a live operator agent for a workstation, returning the ids so the
  UI can open its chat. Singleton per workstation.
  """

  alias Loopyard.{Onboarding, ProjectRegistry, WorkspaceRegistry, Workstation, ChatAgent}

  @doc """
  Ensure the operator agent exists and is running for `workstation_id`
  (defaults to the operated identity). Returns
  `{:ok, %{project_id, workspace_id, agent_id}}`.
  """
  def ensure_agent(workstation_id \\ nil) do
    ws_identity = workstation_id || Workstation.current()

    with {:ok, %{project_id: pid, workspace_id: ws_id}} <- ensure_workspace(ws_identity) do
      agent_id = ensure_running_agent(ws_id, load(ws_identity)["agent_id"])
      save(ws_identity, %{project_id: pid, workspace_id: ws_id, agent_id: agent_id})
      {:ok, %{project_id: pid, workspace_id: ws_id, agent_id: agent_id}}
    end
  end

  @doc "Is this project the (hidden) operator project? Used to filter the normal lists."
  def operator_project?(%{operator: true}), do: true
  def operator_project?(_), do: false

  # ── workspace ──────────────────────────────────────────────────────────────

  defp ensure_workspace(ws_identity) do
    case load(ws_identity) do
      %{"project_id" => pid, "workspace_id" => ws_id}
      when is_binary(pid) and is_binary(ws_id) ->
        if WorkspaceRegistry.get_workspace(ws_id),
          do: {:ok, %{project_id: pid, workspace_id: ws_id}},
          else: create_workspace()

      _ ->
        create_workspace()
    end
  end

  defp create_workspace do
    case Onboarding.create_project("Operator") do
      {:ok, project, ws} ->
        # Re-register with the operator flag so it's hidden from the normal
        # project/workspace lists (see WorkspaceTree.global filter).
        ProjectRegistry.register(Map.put(project, :operator, true))
        {:ok, %{project_id: project.id, workspace_id: ws.id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── agent ────────────────────────────────────────────────────────────────

  defp ensure_running_agent(ws_id, saved_agent_id) do
    cond do
      is_binary(saved_agent_id) and agent_alive?(saved_agent_id) ->
        saved_agent_id

      existing = first_agent(ws_id) ->
        existing

      true ->
        {:ok, id} =
          Onboarding.spawn_agent(ws_id,
            name: "Operator",
            started_by: "operator",
            tools: [Loopyard.Tools.ControlPlane],
            system_prompt: prompt()
          )

        id
    end
  end

  defp agent_alive?(id) do
    case ChatAgent.get_state(id) do
      %{} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp first_agent(ws_id) do
    ChatAgent.list_agent_summaries()
    |> Enum.find(&(Map.get(&1, :workspace_id) == ws_id))
    |> case do
      %{id: id} -> id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ── persistence (per-workstation marker) ───────────────────────────────────

  defp marker_path(ws_identity), do: Path.join(Workstation.dir(ws_identity), "operator.json")

  defp load(ws_identity) do
    case File.read(marker_path(ws_identity)) do
      {:ok, raw} -> Jason.decode!(raw)
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp save(ws_identity, map) do
    path = marker_path(ws_identity)
    File.mkdir_p!(Path.dirname(path))
    File.write(path, Jason.encode!(map))
  rescue
    _ -> :ok
  end

  # ── prompt ─────────────────────────────────────────────────────────────────

  defp prompt do
    """
    You are the Operator — the user's personal control-plane agent for Loopyard.
    You do NOT write code or set up dev environments; you help the user CREATE and
    keep track of projects, then hand the actual work to a workspace agent.

    Your tools:
    - create_project_from_scratch — a brand-new empty project.
    - create_project_from_github — clone a GitHub repo (uses the user's GitHub auth).
    - create_project_from_path — onboard a folder already on the host machine.
      (You only pass the path string; you never read the host filesystem.)
    - list_projects — see what already exists and what's running.

    Each create tool shows the user an Approve/Deny card and WAITS. On approval it
    creates the project and spawns a workspace agent with a setup brief — that
    agent does the checkout, writes the Dockerfile/compose, installs deps, and
    runs it. You never do that yourself.

    When the user wants to set up or run something, pick the matching creation
    mode, confirm the essentials (name, repo/path), and propose it. After it's
    approved, tell them to open the new workspace to watch its agent work. Keep
    replies short and concrete.
    """
  end
end
