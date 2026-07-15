defmodule Loopyard.Operator do
  @moduledoc """
  The **operator agent** — a per-workstation (per-user) control-plane agent. It is
  a normal `ChatAgent`, but hosted the RIGHT way for what it is: a **host-side
  `Harness.Claude` loop** (the Claude CLI on the host, using your Mac's Claude +
  GitHub auth directly) with the `Tools.ControlPlane` MCP toolkit. That means:

    * **no container** — a control agent orchestrates the plane; it doesn't need
      Claude Code's in-container fs sandbox that workspace (ACP) agents use;
    * **no workspace, no project, no code volume, no git repo** — none of the
      workspace apparatus. It's just an agent bound to your identity.

  This is the harness seam working as intended: workspace agents run ACP +
  Claude Code in-container (they write code); the operator runs a lighter
  host-side loop (it creates + delegates). See [plans/gbrain-onboarding.md].

  `ensure_agent/1` idempotently ensures a live operator for a workstation. It's
  lazily (re)spawned on demand (e.g. opening `/operator`), so it needs no
  durable log/replay — `init_fresh` + persistence already no-op on a nil
  workspace_id.
  """

  alias Loopyard.Workstation

  @doc """
  Ensure the operator agent exists + is running for `workstation_id` (defaults to
  the operated identity). Returns `{:ok, %{agent_id: id}}`.
  """
  def ensure_agent(workstation_id \\ nil) do
    identity = workstation_id || Workstation.current()
    agent_id = ensure_running_agent(identity, load(identity)["agent_id"])
    save(identity, %{"agent_id" => agent_id})
    {:ok, %{agent_id: agent_id}}
  end

  @doc "The current operator agent id for an identity, or nil (no spawn)."
  def agent_id(workstation_id \\ nil) do
    identity = workstation_id || Workstation.current()

    case load(identity)["agent_id"] do
      id when is_binary(id) -> if agent_alive?(id), do: id, else: nil
      _ -> nil
    end
  end

  # ── agent lifecycle ─────────────────────────────────────────────────────────

  defp ensure_running_agent(identity, saved_agent_id) do
    if is_binary(saved_agent_id) and agent_alive?(saved_agent_id) do
      saved_agent_id
    else
      spawn_operator(identity)
    end
  end

  defp spawn_operator(identity) do
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    dir = operator_dir(identity)
    File.mkdir_p!(dir)

    opts = [
      id: id,
      name: "Operator",
      working_dir: dir,
      # SECURITY: bind_mount nil → the container-only TOOL policy (native
      # Bash/Read/Write/Edit/Glob/Grep are DENIED). The operator runs host-side
      # (Harness.Claude, below) but must NOT get Claude Code's native HOST
      # filesystem tools — that'd be a sandbox escape (read any file on the Mac)
      # and would break the create_project_from_path boundary (it passes a path
      # string, never reads the FS). Its ONLY tools are Tools.ControlPlane (+ web).
      bind_mount: nil,
      # No workspace / project / code volume — it's not that kind of agent.
      workspace_id: nil,
      started_by: "operator",
      workstation_identity: identity,
      # Host-side Claude CLI loop (uses the host's Claude auth), NOT ACP-in-a-
      # container. This is why the operator needs no container/workspace.
      backend: Loopyard.Harness.Claude,
      # Its own disjoint toolkit + a focused prompt (with its agent_id, so tool
      # calls don't mismatch — a custom system_prompt skips the auto-injected id).
      tools: [Loopyard.Tools.ControlPlane],
      system_prompt: prompt(id)
    ]

    {:ok, _pid} = DynamicSupervisor.start_child(Loopyard.AgentSupervisor, {Loopyard.ChatAgent, opts})
    id
  end

  defp agent_alive?(id) do
    match?(%{}, Loopyard.ChatAgent.get_state(id))
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # ── paths / persistence (per-workstation marker) ────────────────────────────

  # A scratch host cwd for the operator's CLI loop — empty; the real work is the
  # host-side ControlPlane tools, not files here.
  defp operator_dir(identity), do: Path.join([Workstation.dir(identity), "operator"])

  defp marker_path(identity), do: Path.join(Workstation.dir(identity), "operator.json")

  defp load(identity) do
    case File.read(marker_path(identity)) do
      {:ok, raw} -> Jason.decode!(raw)
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp save(identity, map) do
    path = marker_path(identity)
    File.mkdir_p!(Path.dirname(path))
    File.write(path, Jason.encode!(map))
  rescue
    _ -> :ok
  end

  # ── prompt ──────────────────────────────────────────────────────────────────

  defp prompt(agent_id) do
    """
    You are the Operator — the user's personal control-plane agent for Loopyard.
    You do NOT write code or set up dev environments; you help the user CREATE and
    keep track of projects, then hand the actual work to a workspace agent.

    YOUR AGENT ID: #{agent_id} — pass this EXACT string as the `agent_id` argument
    to every tool call. Do not use "operator" or any other value.

    Your tools:
    - create_project_from_scratch — a brand-new empty project.
    - create_project_from_github — clone a GitHub repo (uses the user's GitHub auth).
    - create_project_from_path — onboard a folder already on the host machine.
      (You only pass the path string; you never read the host filesystem.)
    - list_projects — see what already exists and what's running.
    - gh — run GitHub CLI commands with the user's GitHub auth (query orgs, repos,
      PRs, the API). Use it to look things up on GitHub before proposing a clone.

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
