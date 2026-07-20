defmodule Loopyard.ChatAgent.HarnessStartError do
  @moduledoc """
  Raised when the agent harness fails to boot (container down, auth expired,
  handshake timeout). Deliberately a DEDICATED exception so
  `Initializer.build_state/2` can rescue exactly this at its boundary and turn
  it into a clean `{:stop, {:harness_start_failed, reason}}` — an expected
  failure, never an abnormal init crash that cascades supervision trees.
  """
  defexception [:reason, :message]
end

defmodule Loopyard.ChatAgent.Initializer do
  @moduledoc """
  Extracts the init/resume/startup logic from ChatAgent.

  `build_state/2` decides whether to resume from ETS or create a fresh
  agent, builds the struct, starts the CLI session, and returns either
  `{:ok, state}` or `{:stop, reason}`.

  For resumed agents with prompt drift, returns `{:ok, state, :prompt_drift}`
  so the caller can inject the drift marker message (which needs ChatAgent's
  private `append_message`).
  """

  alias Loopyard.ChatAgent.{IdleReaper, Persistence, Prompt, SessionManager, ToolConfig}
  alias Loopyard.Events

  @ets_table :chat_agents

  @doc """
  Build the initial GenServer state for a ChatAgent.

  When `resume: true` is in opts, rebuilds from the ETS-persisted summary.
  Otherwise creates a fresh agent. In both cases, starts the backend CLI
  session.

  Returns:
    - `{:ok, state}` — ready to go
    - `{:ok, state, :prompt_drift}` — resumed with a changed system prompt
    - `{:stop, reason}` — cannot start
  """
  def build_state(id, opts) do
    if Keyword.get(opts, :resume, false) do
      init_resume(id, opts)
    else
      init_fresh(id, opts)
    end
  rescue
    # A harness that fails to boot is an EXPECTED condition (container down,
    # auth expired, handshake timeout) — return a clean {:stop, _} so
    # ChatAgent.init stops normally and DynamicSupervisor.start_child reports
    # {:error, _}. It used to escape as an abnormal init crash, which cascaded
    # through RestartController → ServiceManager → the whole workspace group.
    e in Loopyard.ChatAgent.HarnessStartError ->
      {:stop, {:harness_start_failed, e.reason}}
  end

  @doc """
  Start (or restart) a CLI session for the given agent.

  Shared by both fresh and resumed agents. Returns
  `{session, session_opts, backend, prompt_hash}`.
  """
  def start_session(id, opts, params) do
    working_dir = Keyword.fetch!(params, :working_dir)
    bind_mount = Keyword.get(params, :bind_mount)
    workspace_id = Keyword.get(params, :workspace_id)
    service_name = Keyword.get(params, :service_name)

    resume_session_id = Keyword.get(params, :claude_session_id)

    tools = Keyword.get(opts, :tools, ToolConfig.default_tools())

    default_backend =
      Application.get_env(
        :loopyard,
        :default_harness,
        Loopyard.Harness.Claude
      )

    backend = Keyword.get(opts, :backend, default_backend)
    workspace = if workspace_id, do: load_workspace_config(workspace_id), else: nil

    system_prompt =
      Prompt.build_system_prompt(id,
        # Custom agents (e.g. Workstation) pass a complete prompt that overrides
        # the workspace/container scaffolding. nil falls through to the default.
        system_prompt: Keyword.get(opts, :system_prompt),
        bind_mount: bind_mount,
        workspace_id: workspace_id,
        workspace: workspace,
        service_name: service_name
      )

    # Mirror CLAUDE.md + .claude/ from the workspace volume into working_dir
    if workspace_id do
      Loopyard.ChatAgent.ClaudeContext.mirror(workspace_id, working_dir)
    end

    # Containerized agents (volume-based, no bind_mount) MUST NOT use
    # host-side filesystem tools. Their workspace lives inside a Docker
    # volume; the host's view of `working_dir` is empty.
    container_only? = is_nil(bind_mount)

    base_opts = [
      cwd: working_dir,
      # Which model the agent's CLI runs. A model alias ("sonnet"/"opus"/
      # "haiku"/"fable") or a full model id ("claude-fable-5"). Defaults to the
      # SDK default so unset behavior is unchanged; switch the whole instance
      # with one config line + a restart:  config :loopyard, agent_model: "..."
      model: Application.get_env(:loopyard, :agent_model, "sonnet"),
      permission_mode: :accept_edits,
      dangerously_skip_permissions: true,
      mcp_servers: ToolConfig.build_mcp_servers(tools, id),
      allowed_tools: ToolConfig.build_allowed_tools(tools, container_only?),
      append_system_prompt: system_prompt,
      # Extended thinking: the model streams its reasoning before tool calls,
      # which we surface live in the chat's thinking bubble. :adaptive lets it
      # scale effort to the turn (down to ~nothing on trivial ones). Tunable via
      # config without a code change — set to :disabled or {:enabled, budget_tokens: N}.
      thinking: Application.get_env(:loopyard, :agent_thinking, :adaptive)
    ]

    session_opts =
      if container_only? do
        Keyword.put(
          base_opts,
          :disallowed_tools,
          ToolConfig.denied_native_tools_for_container_agents()
        )
      else
        base_opts
      end

    session_opts =
      if max = Keyword.get(params, :max_turns),
        do: Keyword.put(session_opts, :max_turns, max),
        else: session_opts

    session_opts =
      if is_binary(resume_session_id) and resume_session_id != "" do
        Keyword.put(session_opts, :resume, resume_session_id)
      else
        session_opts
      end

    # CONTAINMENT: an ACP harness MUST run inside a container. Setting `:container`
    # makes Harness.ACP launch via `docker exec -i <container> claude-code-acp` —
    # so the whole runtime (node, browser, /tmp, native Bash/Read/Write) lives in
    # the sealed container and commands run NATIVELY against the code (no
    # per-command `docker exec` wrapper, no host access). The ACP backend can't
    # use the in-process Elixir MCP servers (`mcp_servers:`), so we also hand it an
    # HTTP MCP `:acp_mcp_servers` spec — its tools over the token-authed bridge.
    # Two shapes:
    #   * workspace agent → work container, code volume, /workspace, workspace tools
    #   * operator (explicit :container, no workspace) → its workstation container,
    #     home volume, $HOME, operator tools
    # The model ACP sessions run on. The adapter boots on the CLI's "default"
    # alias (Sonnet 4.5) unless told otherwise — we want the STRONGEST model on
    # agent work. The in-container CLI's `session/set_model` passes FULL model
    # ids through (verified: `claude-opus-4-8` runs), so default to Opus 4.8
    # rather than the adapter's stale "opus" alias (4.6). Applied via
    # session/set_model once the session is ready. Overridable per-agent (opts)
    # or globally (config :loopyard, :acp_model).
    acp_model =
      Keyword.get(opts, :model) ||
        Application.get_env(:loopyard, :acp_model, "claude-opus-4-8")

    session_opts =
      cond do
        backend != Loopyard.Harness.ACP ->
          session_opts

        container_only? and is_binary(workspace_id) ->
          install_brief(Loopyard.Workspace.volume_name_for(workspace_id), system_prompt)

          session_opts
          |> Keyword.put(:acp_mcp_servers, ToolConfig.acp_mcp_servers(id, workspace_id, :workspace))
          |> Keyword.put(:container, Loopyard.Workspace.WorkContainer.container_name(workspace_id))
          |> Keyword.put(:cwd, "/workspace")
          |> Keyword.put(:model, acp_model)

        container_only? and is_binary(Keyword.get(opts, :container)) ->
          identity = Keyword.get(opts, :workstation_identity) || "operator"
          install_brief(Loopyard.Workstation.home_volume(identity), system_prompt)

          session_opts
          |> Keyword.put(:acp_mcp_servers, ToolConfig.acp_mcp_servers(id, nil, :operator))
          |> Keyword.put(:container, Keyword.get(opts, :container))
          |> Keyword.put(:cwd, "/home/#{identity}")
          |> Keyword.put(:model, acp_model)

        true ->
          session_opts
      end

    # Fail closed: never start a runtime on the host. Raises if the resolved
    # backend/opts would run the harness process outside a container.
    assert_runtime_contained!(backend, session_opts, id)

    case backend.start_session(session_opts) do
      {:ok, session} ->
        prompt_hash = :crypto.hash(:sha256, system_prompt || "") |> Base.encode16(case: :lower)
        {session, session_opts, backend, prompt_hash}

      {:error, reason} ->
        # Tagged exception, RESCUED at the build_state boundary into a clean
        # {:stop, {:harness_start_failed, reason}} — never an abnormal crash.
        raise Loopyard.ChatAgent.HarnessStartError,
          reason: reason,
          message:
            "Failed to start the agent harness for agent #{id}: #{inspect(reason)}. " <>
              "Usually this means: the harness isn't installed in the container, the workspace volume " <>
              "is unreachable, or auth isn't configured. Check the harness is installed in the " <>
              "container to diagnose."
    end
  end

  # --- Private helpers ---

  # Write Loopyard's managed brief into `volume`'s CLAUDE.local.md, where the
  # in-container ACP harness reads it (its cwd is /workspace for a workspace agent,
  # $HOME for the operator — both are the volume root). The host-cwd install path
  # (Harness.ACP.SystemPrompt) can't reach the container's fs, so in-container mode
  # installs here via VolumeIO. Idempotent — replaces only the managed block,
  # preserving any project CLAUDE.local.md content. Best-effort: a volume-write
  # hiccup must not block the agent from starting.
  defp install_brief(_volume, prompt) when prompt in [nil, ""], do: :ok

  defp install_brief(volume, prompt) do
    existing =
      case Loopyard.VolumeIO.read_file(volume, "CLAUDE.local.md") do
        {:ok, content} -> content
        _ -> ""
      end

    content = Loopyard.Harness.ACP.SystemPrompt.render_file(existing, prompt)
    Loopyard.VolumeIO.write_file(volume, "CLAUDE.local.md", content)
    :ok
  rescue
    e ->
      require Logger

      Logger.warning(
        "[Initializer] couldn't install the agent brief into volume #{volume}: " <>
          Exception.message(e)
      )

      :ok
  end

  # CONTAINMENT INVARIANT (docs/SECURITY.md): every agent's harness runtime runs
  # inside a Docker container — never on the host. Fail closed: raise rather than
  # silently start a host-side process.
  #
  #   * `Harness.Claude` runs the `claude` CLI as a HOST subprocess → refused.
  #   * `Harness.ACP` runs on the host UNLESS `:container` is set → require it.
  #   * anything else (Fake + test doubles like RecordingBackend) spawns no host
  #     runtime → allowed. IMPORTANT: if a NEW backend that can spawn a host
  #     process is added, it MUST be refused here (add a clause).
  defp assert_runtime_contained!(Loopyard.Harness.Claude, _session_opts, id) do
    raise "CONTAINMENT: Harness.Claude runs the CLI on the HOST (agent #{id}). Refused — " <>
            "agents must run in-container (Harness.ACP with :container). See docs/SECURITY.md."
  end

  defp assert_runtime_contained!(Loopyard.Harness.ACP, session_opts, id) do
    if is_nil(Keyword.get(session_opts, :container)) do
      raise "CONTAINMENT: ACP agent #{id} has no :container — it would run the harness " <>
              "on the HOST. Refused. A workspace agent needs a workspace_id (→ work " <>
              "container); an operator needs an explicit :container. See docs/SECURITY.md."
    end

    :ok
  end

  defp assert_runtime_contained!(_test_or_neutral_backend, _session_opts, _id), do: :ok

  # Resume an agent from persisted state (after server restart).
  defp init_resume(id, opts) do
    case :ets.lookup(@ets_table, id) do
      [{^id, saved}] ->
        case validate_resume_summary(id, saved) do
          :ok ->
            resume_from_summary(id, opts, saved)

          {:error, missing_fields} ->
            Loopyard.EventLog.error(
              "agent:#{id}",
              "Refusing to resume: saved summary missing required fields #{inspect(missing_fields)}. " <>
                "The ETS row is corrupt or the schema drifted. Remove this agent and recreate."
            )

            :telemetry.execute(
              [:loopyard, :agent, :resume_rejected],
              %{count: 1},
              %{agent_id: id, missing_fields: missing_fields}
            )

            {:stop, {:corrupted_resume_state, missing_fields}}
        end

      [] ->
        {:stop, :no_saved_state}
    end
  end

  # Minimum fields we need to safely resume.
  defp validate_resume_summary(_id, saved) do
    required = [:working_dir, :name, :started_at]

    missing =
      Enum.filter(required, fn field ->
        case Map.get(saved, field) do
          nil -> true
          "" -> true
          _ -> false
        end
      end)

    case missing do
      [] -> :ok
      fields -> {:error, fields}
    end
  end

  defp resume_from_summary(id, opts, saved) do
    {session, session_opts, backend, new_prompt_hash} =
      start_session(id, opts,
        working_dir: saved.working_dir,
        # CONTAINMENT: on resume, NEVER grant a host bind_mount — not even from a
        # saved `host_access: true`. Host access is disabled everywhere now, so a
        # restored agent always comes back container-only. See docs/SECURITY.md.
        bind_mount: nil,
        workspace_id: saved.workspace_id,
        service_name: saved[:service_name],
        claude_session_id: saved[:claude_session_id]
      )

    saved_prompt_hash = saved[:prompt_hash]

    prompt_changed? =
      is_binary(saved_prompt_hash) and is_binary(new_prompt_hash) and
        saved_prompt_hash != new_prompt_hash

    # Summary stores messages oldest-first (display order); internal
    # state stores them newest-first for O(1) prepend in append_message.
    internal_messages = Enum.reverse(saved[:messages] || [])

    state =
      Loopyard.ChatAgent
      |> struct(saved)
      |> struct(
        session: session,
        session_opts: session_opts,
        backend: backend,
        # CONTAINMENT: the initial `struct(saved)` above copies EVERY saved field,
        # including a possibly-stale `bind_mount`/`host_access` from before this
        # invariant existed. The actual session above is already forced
        # container-only (bind_mount: nil was passed to start_session); force the
        # STATE to agree, so a stale host path never lingers in state/summary/UI
        # even though it was never actually granted to the running session.
        bind_mount: nil,
        host_access: false,
        last_activity_at: DateTime.utc_now(),
        status: :idle,
        stream_ref: nil,
        active_tool: nil,
        messages: internal_messages,
        # summary/1 exposes the FIFO queue as :pending_messages; map it back so
        # messages queued while :thinking survive a crash-respawn instead of
        # silently vanishing (the durable inbox is Loopyard state).
        pending_sends: saved[:pending_messages] || [],
        tracked_cli_os_pid: nil,
        prompt_hash: new_prompt_hash,
        rate_limit_status: :ok,
        rate_limit_resets_at_ms: nil,
        rate_limit_type: nil,
        auth_error: nil
      )

    state = SessionManager.track_os_pid(state)
    state = IdleReaper.schedule(state)

    :ets.insert(@ets_table, {id, Loopyard.ChatAgent.summary(state)})

    Events.ChatAgent.publish(%Events.ChatAgent.Resumed{
      summary: Loopyard.ChatAgent.summary(state)
    })

    context_status =
      cond do
        is_binary(state.claude_session_id) -> "conversation continued"
        state.messages != [] -> "NO claude_session_id — CLI will start fresh"
        true -> "no prior messages"
      end

    Loopyard.EventLog.info(
      "agent:#{state.name}",
      "Resumed (#{id}) with #{length(state.messages)} messages, #{context_status}"
    )

    # Deliver any messages that were queued when the agent crashed. Processed
    # after init returns (this runs in the GenServer's own process).
    if state.pending_sends != [] do
      send(self(), :drain_resumed_pending)
    end

    if prompt_changed? do
      :telemetry.execute(
        [:loopyard, :agent, :prompt_drift],
        %{count: 1},
        %{agent_id: id, old_hash: saved_prompt_hash, new_hash: new_prompt_hash}
      )

      Loopyard.EventLog.info(
        "agent:#{id}",
        "Prompt drift detected (old=#{String.slice(saved_prompt_hash, 0..7)} " <>
          "new=#{String.slice(new_prompt_hash, 0..7)})"
      )

      {:ok, state, :prompt_drift}
    else
      {:ok, state}
    end
  end

  # Start a fresh agent (normal path)
  defp init_fresh(id, opts) do
    name = Keyword.get(opts, :name, "Chat #{id |> String.slice(0..7)}")
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    started_by = Keyword.get(opts, :started_by, "anonymous")
    # CONTAINMENT: host access is DISABLED. Every agent runs its harness inside a
    # container — no exceptions. A `host_access: true` opt (which used to grant a
    # host `bind_mount` + native host tools) is now IGNORED and logged, never
    # honored, so no runtime can escape to the host. See docs/SECURITY.md.
    if Keyword.get(opts, :host_access, false) == true do
      require Logger

      Logger.warning(
        "[Initializer] host_access requested for agent #{id} but is DISABLED — " <>
          "all agents run in-container. Ignoring."
      )
    end

    host_access = false
    bind_mount = nil
    workspace_id = Keyword.get(opts, :workspace_id)
    service_name = Keyword.get(opts, :service_name)
    # Restored chat history + Claude session for a re-spawned agent that has no
    # ETS summary to resume from (the operator, respawned lazily after a restart).
    initial_messages = Keyword.get(opts, :initial_messages, [])
    resumed_session_id = Keyword.get(opts, :claude_session_id)

    {session, session_opts, backend, prompt_hash} =
      start_session(id, opts,
        working_dir: working_dir,
        bind_mount: bind_mount,
        workspace_id: workspace_id,
        service_name: service_name,
        claude_session_id: resumed_session_id,
        max_turns: 50
      )

    now = DateTime.utc_now()

    state = %Loopyard.ChatAgent{
      id: id,
      name: name,
      session: session,
      session_opts: session_opts,
      backend: backend,
      working_dir: working_dir,
      bind_mount: bind_mount,
      host_access: host_access,
      workspace_id: workspace_id,
      container: Keyword.get(opts, :container),
      workstation_identity:
        Keyword.get(opts, :workstation_identity) || Loopyard.Workstation.current(),
      started_at: now,
      started_by: started_by,
      last_activity_at: now,
      status: :idle,
      # Restored history (internal list is reversed; summary reverses back).
      messages: Enum.reverse(initial_messages),
      claude_session_id: resumed_session_id,
      service_name: service_name,
      prompt_hash: prompt_hash
    }

    state = SessionManager.track_os_pid(state)
    state = IdleReaper.schedule(state)
    summary = Loopyard.ChatAgent.summary(state)
    :ets.insert(@ets_table, {id, summary})
    Persistence.persist_agent(state, &Loopyard.ChatAgent.summary/1)
    Events.ChatAgent.publish(%Events.ChatAgent.Started{summary: summary})
    Loopyard.EventLog.info("agent:#{name}", "Started (#{id})")

    {:ok, state}
  end

  defp load_workspace_config(workspace_id) when is_binary(workspace_id) do
    volume_name = Loopyard.Workspace.volume_name_for(workspace_id)

    case Loopyard.Workspace.load_from_volume(volume_name) do
      {:ok, workspace} -> workspace
      _ -> nil
    end
  end
end
