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
  lazily (re)spawned on demand (e.g. opening `/operator`).

  **Chat persists like any other agent.** The operator has no workspace, so we
  flatten the ETF-log concept: its messages persist to a per-workstation
  `operator-agent.log` (`Persistence.operator_log_path/1`) in the SAME format as
  a workspace agent's `agents.log`. On respawn we reuse the agent's STABLE id
  (saved in the marker) and replay that log to restore the transcript +
  `claude_session_id` — same mechanism, flattened key. The lazy respawn seeds
  the restored history via `initial_messages:` rather than the ETS-summary resume
  path (that path doesn't carry the operator's custom tools/prompt/container).
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
    cond do
      is_binary(saved_agent_id) and agent_alive?(saved_agent_id) ->
        saved_agent_id

      # Known but dead — respawn with the SAME id so its per-workstation log
      # restores this exact conversation (stable key = durable history).
      is_binary(saved_agent_id) ->
        spawn_operator(identity, saved_agent_id)

      true ->
        spawn_operator(identity, new_agent_id())
    end
  end

  defp new_agent_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp spawn_operator(identity, id) do
    dir = operator_dir(identity)
    File.mkdir_p!(dir)

    # Restore prior chat history (if any) from the operator's own ETF log — same
    # replay mechanism workspace agents use, keyed per workstation instead of per
    # workspace. Seeded into the fresh agent so the transcript survives restarts.
    {messages, claude_session_id} = load_history(identity, id)

    # Bring up the workstation container — the operator's OWN image (base
    # toolchain + this identity's gh/Claude creds via the mounted $HOME). Its
    # file/exec tools run INSIDE this container, so it can do whatever it wants
    # confined to the image, and never touches the host.
    {:ok, container} = Loopyard.Workstation.Container.ensure_up(identity)

    opts = [
      id: id,
      name: "Operator",
      working_dir: dir,
      # Container-only tool policy: no native host tools. All fs/exec goes through
      # the MCP container toolkit, which runs inside `container` (below).
      bind_mount: nil,
      # No workspace / project / code volume. Instead it's bound directly to its
      # workstation container — resolve_container/1 targets this.
      workspace_id: nil,
      container: container,
      started_by: "operator",
      workstation_identity: identity,
      backend: Loopyard.Harness.Claude,
      # A shell in its image (Tools.Container.Exec, via ControlPlane) + the
      # control-plane create/manage tools + gh. Same creds as any agent (mounted
      # $HOME), sandboxed to the container.
      tools: [Loopyard.Tools.ControlPlane],
      system_prompt: prompt(id),
      # Restored transcript (oldest-first) + Claude session, so the chat doesn't
      # blank out across restarts and the CLI resumes the same conversation.
      initial_messages: messages,
      claude_session_id: claude_session_id
    ]

    {:ok, _pid} = DynamicSupervisor.start_child(Loopyard.AgentSupervisor, {Loopyard.ChatAgent, opts})
    id
  end

  # Restore {messages, claude_session_id} for `id` from the per-workstation
  # operator log via the shared AgentLog.replay path. Returns {[], nil} when
  # there's no prior log (first ever spawn) or the id isn't present.
  defp load_history(identity, id) do
    path = Loopyard.ChatAgent.Persistence.operator_log_path(identity)

    case Loopyard.AgentLog.replay(log_path: path, version: 1) do
      {:ok, agents} ->
        case Map.get(agents, id) do
          %{} = data -> {Map.get(data, :messages, []), Map.get(data, :claude_session_id)}
          _ -> {[], nil}
        end

      _ ->
        {[], nil}
    end
  rescue
    _ -> {[], nil}
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
    You are the Operator — the user's personal agent for Loopyard. Your goal in
    life is to MANAGE the user's projects, workspaces, and their associated chats:
    create them, keep track of what's running, and help set them up.

    YOUR AGENT ID: #{agent_id} — pass this EXACT string as the `agent_id` argument
    to every tool call. Do not use "operator" or any other value.

    You run inside your OWN workstation container image, with the user's GitHub +
    Claude auth already mounted. Your tools:
    - exec — a real shell INSIDE your container (cwd /home). Run anything —
      `git`, `gh`, `docker`, `cat`/`sed` to read/edit files, install packages —
      in service of setting up and managing projects. It's your image; do what
      you need. It's sandboxed: nothing you exec touches the user's Mac.
    - Control-plane tools to create + manage Loopyard projects & workspaces:
      - create_project_from_scratch — a brand-new empty project.
      - create_project_from_github — clone a GitHub repo.
      - create_project_from_path — onboard a folder on the host (you pass a path
        STRING to the control plane; this doesn't read the host FS from here).
      - list_projects — see what exists and what's running.

    Each create tool shows the user an Approve/Deny card and WAITS. On approval it
    creates the project and spawns a WORKSPACE agent with a setup brief — that
    agent does the actual dev-env build (Dockerfile/compose, deps, running it).
    You orchestrate and manage; the workspace agents do the per-project work.

    When the user wants something set up, figure out the right move, confirm the
    essentials, and propose it. Keep replies short and concrete.
    """
  end
end
