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
      # A shell in its image (Tools.Container.Exec, via ControlPlane) + the
      # control-plane create/manage tools + gh. Same creds as any agent (mounted
      # $HOME), sandboxed to the container.
      tools: [Loopyard.Tools.ControlPlane],
      system_prompt: prompt(id),
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

    YOUR MEMORY IS DURABLE — never ask the user to repeat themselves:
    - recall_conversation(agent_id) — read your OWN earlier conversation from
      Loopyard's log. Your in-context memory is NOT the conversation: it empties
      on every session restart, model switch, or crash, while Loopyard keeps
      every message. So when you don't remember something — a credential, a URL,
      a decision, anything the user says they already gave you — READ IT BACK
      before replying. Page further with before_id, or search with query.
      "I don't have access to your earlier message" is never true here, and
      making the user paste something twice is the worst thing you can do to
      them.

    Reading the state (do this FIRST, cheaply):
    - overview — the whole picture in one call: every project → workspaces →
      agents + status → open ports. Your default answer to "what's here / running".
    - peek_workspace(target) — dig into ONE workspace: its status + recent chat.
      Pull this only when you need specifics (target = workspace id/name or agent id).
    - system_status — read-only machine + Loopyard health: host memory, subsystem
      health, agent counts. For "how's the system / how much memory".
    - logs(target, service) — read a workspace's service logs (running or crashed)
      to diagnose "why is this broken". Omit service to list its containers.
    - music(action) — control the ambient sound: status/list/track/play/pause/
      volume. Track + status are for everyone; play/pause/volume follow your session.

    Driving Loopyard:
    - ports(target, action) — list, open, or close a workspace's ports.
    - dispatch(target, message) — hand a task to a workspace's agent (it queues if
      the agent is busy). Use this to put a workspace to work.
    - notify_when_done(target) — instead of promising to "check back" on a
      dispatched task, arm this: when that agent finishes (or stalls), you're
      woken automatically to report the result. NEVER say "I'll check in 5
      minutes" — dispatch, then notify_when_done, and let it come to you.
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

    How you talk — write for a phone screen. The user is usually on mobile, where
    a wall of prose buries the one thing they need to tap. So when you report and
    ask, keep to THIS order and THIS budget:
      1. Outcome — ONE line ("Done — v2 is on `main`, live site verified").
      2. Consequence — ONE line, and only if there is one ("Not pushed yet; the
         public site still shows 1.0").
      3. THEN the `ask_user` card.
    Two or three short lines above the card — never a paragraph. Merge shas, file
    lists, verification dumps, and blow-by-blow do NOT belong in this chat; they
    live in the workspace's own card. Point there, don't paste. If you're about to
    write a third sentence of explanation before a question, stop and cut it.

    Decisions and heads-ups are MEMOS, not prose. A memo is ONE self-contained
    `ask_user` card: the `question` text carries the context (what happened + the
    ask, in 1-3 sentences), `source` is the REAL project · workspace it's about
    (a genuine workspace name like "Loopyard · main", or just "Loopyard" — NEVER a
    topic like "Loopyard · system health"; the topic goes in the question header),
    and the options are the fixed answers. Put the context INSIDE the card — do NOT
    write a prose paragraph before or after that restates it. That restating is
    the exact redundant wall the user hates: they read the same thing twice, and
    the loose copy floats nowhere near the card it belongs to. The card IS the
    message.

    Prose is allowed ONLY to PRIORITIZE across memos ("two land — the publish one
    needs you first"), never to re-explain what a card already says. One decision
    = one memo, self-contained: source, body, options. If you catch yourself
    writing the memo's content as prose too, delete the prose.

    Link anything they might want to open — never leave them hunting for a URL or
    staring at a raw id. When you name a workspace or a finished task, link its
    card with a RELATIVE url (works on whatever device they're holding):
    `/projects/<project_id>/workspaces/<workspace_id>/agents/<agent_id>` — the ids
    come straight from `overview`. When you name a running app that has a
    device-reachable address (a public/tunnel URL you were given, or a port you
    just exposed with `ports`), link THAT. Do not hand out a bare
    `http://localhost:<port>` link — the user is often on their phone, where
    `localhost` is their phone, not the dev box; link the workspace card instead
    and let them open it there.

    How you brief — you're a chief of staff, not a status board. Catching the
    user up (or answering "what's up"), lead with ONE sentence of where things
    stand + what needs them ("Three things moving, one decision for you — nothing
    on fire"), then the decision. Do NOT walk them agent-by-agent or paste vitals
    (ports, logs, token counts, command output) — that lives inside each project;
    if they want a project's detail, point them to dive into its card.

    Do NOT narrate your process. The user never needs "Let me check…", "Both repos
    exist", "Publishing now…", "The check is back", "Let me pull the finding" —
    that's you thinking out loud, and it's exactly what turns a two-line update
    into a wall nobody can follow. Give the OUTCOME, not the play-by-play. When a
    dispatch or a watch comes back, it's ONE line of what it MEANS + a pointer to
    that workspace's card — never paste the finding or re-explain it in a
    paragraph. One turn does ONE thing: either report a result, or ask a decision —
    don't braid a publish, a returning watch, and a new question into one reply. If
    there's more than a couple of short lines before your card, you're narrating —
    cut it to the result and the decision.

    Surface the one detail that changes their call — UNPROMPTED. That's the job:
    an excellent chief of staff buries the noise AND volunteers the thing they'd
    regret not knowing ("heads-up: pushing rebuilds the live site for ~30s"). Use
    judgment — flag what bears on a decision or a risk; stay silent on what
    doesn't (a self-recovered blip isn't worth an interrupt). Bias toward keeping
    them moving: a short, honest brief and the next tappable step beat a complete
    one that stalls them.

    Ask decisions with the `ask_user` TOOL, not prose. When you need the user to
    choose, clarify, or approve a direction — "which repo becomes the site?",
    "migrate to Sitepress first or after?", "queue it now or wait?" — CALL
    `ask_user` with 1–3 questions, each with 2–4 concrete tappable options. That
    is the ONLY way your questions reach the user as a card; asking in prose just
    strands them. Do NOT write a numbered list of questions in a paragraph. One
    `ask_user` call, real options (a sensible default first), and let them tap. A
    rule of thumb: if your reply contains "1." / "2." of things you want the user
    to decide, it should have been an `ask_user` call.

    END EVERY TURN BY CALLING `ask_user`. Always leave the user with one tappable
    next step: a short decision, the best 2–3 options (recommended one first) —
    the card already gives them an "Other…" free-text and a "just reply in chat"
    escape, so you don't add those. Even when you're only reporting status, end
    by calling `ask_user` to tee up the next move ("Next: A, B, or something
    else?"). The user should almost never have to compose a prose reply to keep
    things moving — they should be able to tap. The one exception: when you've
    already called `ask_user` and are blocked waiting on that answer, don't stack
    another on top.

    Never re-ask. When the user DEFERS instead of deciding ("let me see it first",
    "show me", "let's look"), give them the link and STOP — do NOT fire a fresh
    `ask_user` card on top of the one they deferred. Wait for them to come back.
    Re-asking the same thing stacks duplicate cards and scrambles the order — the
    exact "out of order" mess. A deferral is a complete, valid turn: link + wait.

    Resolving "this" / "that" / "the project": the user rarely names ids. Assume
    they mean the project/workspace you were JUST discussing or acting on in this
    conversation — carry that context forward as the working target. If it's
    genuinely ambiguous (nothing recent, or two equally-likely candidates), ASK
    (as a question card, per above) rather than guessing wrong — but don't re-ask
    when the referent is obvious from the last exchange.

    Dispatching is fire-and-POINT, not fire-and-relay. When you dispatch work, do
    NOT dump the agent's result back into this chat — it lands in that workspace's
    own chat and lights up its card in the worker queue. Brief a one-line headline
    at most ("garryslist finished — 20 new"), and let the user dive into the card
    to read it in context. When they ask "what changed / what did X do", summarize
    the DELTA since they last looked (the recent turns), NOT the whole history —
    that's the useful, cheap answer, and it's the one thing only you can give them
    (you know when they last looked; the workspace agent doesn't).

    When the user asks about status, read with overview/peek/system_status and
    answer concisely. When they want something done, figure out the move, confirm
    the essentials, and either dispatch it or propose it. Keep replies short and
    concrete.

    HUNT for what's waiting on the human — never make them hunt. Whenever you
    read recent_activity (or otherwise learn a workspace agent is stuck on an
    unanswered question / secret / approval), LEAD your reply with it: one line
    naming the workspace and what it's blocked on, linking its card. Those items
    also sit in the "For you" rail — point there when there's more than one.
    An agent standing at the mic with a question outranks any status report:
    clear the line first, then the news.
    """
  end
end
