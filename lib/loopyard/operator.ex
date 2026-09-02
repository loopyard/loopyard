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

  @doc """
  Where the operator's chat attachments live: its workstation container, under
  the identity's `$HOME/.loopyard/uploads` (see `Loopyard.Attachments`).
  """
  @spec attachment_target(String.t() | nil) :: Loopyard.Attachments.target()
  def attachment_target(workstation_id \\ nil) do
    identity = workstation_id || Workstation.current()
    {:container, Workstation.container_name(identity), "/home/#{identity}"}
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
    {messages, claude_session_id, pending_sends} = load_history(identity, id)

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
      # Stamped from the SYSTEM template (Loopyard.Agents.Template.system/0):
      # the control-plane toolkit + the shared doctrine + the system brief.
      template_id: "system",
      scope: :system,
      # Restored transcript (oldest-first) + Claude session, so the chat doesn't
      # blank out across restarts and the CLI resumes the same conversation.
      initial_messages: messages,
      claude_session_id: claude_session_id,
      # Restore anything queued to the operator when the server went down
      # (issue #78) — init_fresh drains it on boot.
      pending_sends: pending_sends
    ]

    {:ok, _pid} =
      DynamicSupervisor.start_child(Loopyard.AgentSupervisor, {Loopyard.ChatAgent, opts})

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
          %{} = data ->
            {Map.get(data, :messages, []), Map.get(data, :claude_session_id),
             Map.get(data, :pending_messages, [])}

          _ ->
            {[], nil, []}
        end

      _ ->
        {[], nil, []}
    end
  rescue
    e ->
      # Booting amnesic is the "conversation survives restart" invariant
      # failing — it must never be invisible.
      Loopyard.EventLog.error("operator", "history restore failed: #{Exception.message(e)}")
      {[], nil, []}
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
    e ->
      Loopyard.EventLog.warning("operator", "marker unreadable (#{Exception.message(e)}) — fresh")
      %{}
  end

  defp save(identity, map) do
    path = marker_path(identity)
    File.mkdir_p!(Path.dirname(path))
    File.write(path, Jason.encode!(map))
  rescue
    e ->
      Loopyard.EventLog.warning("operator", "marker not saved: #{Exception.message(e)}")
      :ok
  end
end
