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

    agent_type =
      Keyword.get(params, :agent_type) || Loopyard.Agents.Registry.default_agent_name()

    resume_session_id = Keyword.get(params, :claude_session_id)

    tools = Keyword.get(opts, :tools, ToolConfig.default_tools())

    default_backend =
      Application.get_env(
        :loopyard,
        :default_agent_backend,
        Loopyard.Agent.Backend.ClaudeCode
      )

    backend = Keyword.get(opts, :backend, default_backend)
    workspace = if workspace_id, do: load_workspace_config(workspace_id), else: nil

    system_prompt =
      Prompt.build_system_prompt(id,
        bind_mount: bind_mount,
        workspace_id: workspace_id,
        workspace: workspace,
        service_name: service_name,
        agent_type: agent_type
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
      permission_mode: :accept_edits,
      dangerously_skip_permissions: true,
      mcp_servers: ToolConfig.build_mcp_servers(tools, id),
      allowed_tools: ToolConfig.build_allowed_tools(tools, container_only?),
      append_system_prompt: system_prompt
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

    case backend.start_session(session_opts) do
      {:ok, session} ->
        prompt_hash = :crypto.hash(:sha256, system_prompt || "") |> Base.encode16(case: :lower)
        {session, session_opts, backend, prompt_hash}

      {:error, reason} ->
        raise RuntimeError,
          message:
            "Failed to start CLI session for agent #{id}: #{inspect(reason)}. " <>
              "Usually this means: the `claude` binary isn't on PATH, the workspace volume " <>
              "is unreachable, or auth isn't configured. Run " <>
              "`mix loopyard.rpc 'ClaudeCode.Test.smoke()'` to diagnose."
    end
  end

  # --- Private helpers ---

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
    agent_type = saved[:agent_type] || Loopyard.Agents.Registry.default_agent_name()

    {session, session_opts, backend, new_prompt_hash} =
      start_session(id, opts,
        working_dir: saved.working_dir,
        bind_mount: saved.bind_mount,
        workspace_id: saved.workspace_id,
        service_name: saved[:service_name],
        agent_type: agent_type,
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
        last_activity_at: DateTime.utc_now(),
        status: :idle,
        stream_ref: nil,
        active_tool: nil,
        agent_type: agent_type,
        messages: internal_messages,
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
    bind_mount = Keyword.get(opts, :bind_mount)
    workspace_id = Keyword.get(opts, :workspace_id)
    service_name = Keyword.get(opts, :service_name)
    agent_type = Keyword.get(opts, :agent_type) || Loopyard.Agents.Registry.default_agent_name()

    {session, session_opts, backend, prompt_hash} =
      start_session(id, opts,
        working_dir: working_dir,
        bind_mount: bind_mount,
        workspace_id: workspace_id,
        service_name: service_name,
        agent_type: agent_type,
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
      workspace_id: workspace_id,
      started_at: now,
      started_by: started_by,
      last_activity_at: now,
      status: :idle,
      messages: [],
      service_name: service_name,
      agent_type: agent_type,
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
