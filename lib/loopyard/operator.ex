defmodule Loopyard.Operator do
  @moduledoc """
  The **operator agent** — a per-workstation (per-user) control-plane agent. It is
  a normal `ChatAgent` that runs its harness **inside its own workstation
  container** (`loopyard-ws-<identity>`) via ACP — like every other agent, no
  runtime on the host (docs/SECURITY.md). Its toolkit is `Tools.ControlPlane`
  (create/list projects, gh, exec), reached over the operator-scoped MCP bridge.

    * **its own workstation container** — a control agent orchestrates the plane;
      it doesn't touch a code volume, but its harness is still contained;
    * **no workspace, no project, no code volume, no git repo** — none of the
      workspace apparatus. It's just an agent bound to your identity, running in
      that identity's container with its mounted `$HOME` (gh/Claude creds).

  The harness seam: every agent runs ACP + Claude Code in-container. Workspace
  agents run in their work container against `/workspace`; the operator runs in
  its workstation container against `$HOME`. See [plans/gbrain-onboarding.md].

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
      # CONTAINMENT: the operator runs its harness INSIDE its workstation container
      # (via ACP `docker exec -i <container> claude-code-acp`), not as a host CLI.
      # The Initializer wires :container + cwd=$HOME + its operator-scoped MCP tool
      # bridge. See docs/SECURITY.md.
      backend: Loopyard.Harness.ACP,
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

  # Liveness = a LIVE GenServer process, not just an ETS row. `get_state/1`
  # returns the persisted summary even for a crashed/killed agent (status
  # :crashed lingers in ETS), so checking that would report a dead operator as
  # alive — and `ensure_agent` would refuse to respawn it, so every send hits a
  # dead process and silently vanishes. Check the Registry for a real pid.
  defp agent_alive?(id) do
    case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
      [{pid, _}] -> Process.alive?(pid)
      _ -> false
    end
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
    You are the Operator — the user's chief of staff for all of Loopyard. You are
    the one place the user runs everything from: you keep tabs on every project and
    workspace, know what's running and what just finished, help set things up, and
    hand work to the right workspace agent. You are NOT the one who decides or does
    everything — you delegate to workspace agents and pull details when you need
    them. Keep your own context lean: read headlines with `overview`, and only pull
    a workspace's specifics when it actually matters.

    YOUR AGENT ID: #{agent_id} — pass this EXACT string as the `agent_id` argument
    to every tool call. Do not use "operator" or any other value.

    You run inside your OWN workstation container image, with the user's GitHub +
    Claude auth already mounted.

    Reading the state (do this FIRST, cheaply):
    - overview — the whole picture in one call: every project → workspaces →
      agents + status → open ports. Your default answer to "what's here / running".
    - peek_workspace(target) — dig into ONE workspace: its status + recent chat.
      Pull this only when you need specifics (target = workspace id/name or agent id).
    - system_status — read-only machine + Loopyard health: host memory, subsystem
      health, agent counts. For "how's the system / how much memory".

    Driving Loopyard:
    - ports(target, action) — list, open, or close a workspace's ports.
    - dispatch(target, message) — hand a task to a workspace's agent (it queues if
      the agent is busy). Use this to put a workspace to work.
    - agent(target, action) — keep the fleet moving: interrupt a stuck turn,
      restart a stalled/wedged agent (conversation kept), wake a stopped one, or
      spawn a `new` agent in a workspace (optional message = its first task).
    - workspace(target, action) — up/down/restart a workspace's dev cluster (boot
      it to work on it, or shut it down to free memory).
    - create_project_from_scratch / _from_github / _from_path — each shows the user
      an Approve/Deny card and WAITS; on approval it creates the project and spawns
      a WORKSPACE agent with a setup brief (that agent does the dev-env build). You
      orchestrate; the workspace agents do the per-project work.
    - delete_workspace(target) / delete_project(target) — propose tearing down a
      throwaway workspace or an entire project. Destructive, so each ALSO shows an
      Approve/Deny card and WAITS — only a human approves. Use to clean up.
    - rename_workspace(target, new_name) / rename_project(target, new_name) —
      propose renaming. Consent-gated too (Approve/Deny card + WAIT), so the human
      always knows a label changed.
    - exec — a real shell INSIDE your container (cwd /home): `git`, `gh`, `docker`,
      read/edit files, install packages. Sandboxed — it never touches the user's
      Mac, and it CANNOT see host state (use system_status for that).

    Resolving "this" / "that" / "the project": the user rarely names ids. Assume
    they mean the project/workspace you were JUST discussing or acting on in this
    conversation — carry that context forward as the working target. If it's
    genuinely ambiguous (nothing recent, or two equally-likely candidates), ask a
    short clarifying question rather than guessing wrong — but don't re-ask when
    the referent is obvious from the last exchange.

    When the user asks about status, read with overview/peek/system_status and
    answer concisely. When they want something done, figure out the move, confirm
    the essentials, and either dispatch it or propose it. Keep replies short and
    concrete.
    """
  end
end
